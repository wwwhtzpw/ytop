package com.yashan.yjdbc.exec;

import com.yashan.yjdbc.config.SessionConfig;
import com.yashan.yjdbc.db.JdbcSession;

import java.io.PrintStream;
import java.math.BigDecimal;
import java.sql.CallableStatement;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 执行 SQL, 按 Oracle sqlplus 风格打印结果.
 */
public final class SqlExecutor {
    private final JdbcSession session;
    private final PrintStream out;
    private final PrintStream err;

    public SqlExecutor(JdbcSession session, PrintStream out, PrintStream err) {
        this.session = session;
        this.out = out;
        this.err = err;
    }

    /**
     * PL/SQL 单元: 脚本/REPL 仅由单独一行 / 提交 (内部 ; 不断句).
     * 含匿名块与 CREATE [OR REPLACE] 过程类对象.
     */
    public static boolean looksLikePlsql(String sql) {
        if (sql == null) {
            return false;
        }
        String u = sql.trim().toUpperCase(Locale.ROOT);
        if (u.startsWith("DECLARE") || u.startsWith("BEGIN")) {
            return true;
        }
        if (!u.startsWith("CREATE")) {
            return false;
        }
        String rest = u.substring(6).trim();
        if (rest.startsWith("OR")) {
            rest = rest.substring(2).trim();
            if (!rest.startsWith("REPLACE")) {
                return false;
            }
            rest = rest.substring(7).trim();
        }
        return rest.startsWith("PROCEDURE")
                || rest.startsWith("FUNCTION")
                || rest.startsWith("PACKAGE")
                || rest.startsWith("TRIGGER")
                || rest.startsWith("TYPE BODY");
    }

    /**
     * 解析语句终止符: 去掉尾部 \\G/\\g 与 ;.
     * \\G 表示本条结果竖排 (类 MySQL).
     */
    public static final class StmtSpec {
        public final String sql;
        /** 语句以 \\G 结束时为 true (单次强制竖排). */
        public final boolean verticalOnce;

        public StmtSpec(String sql, boolean verticalOnce) {
            this.sql = sql;
            this.verticalOnce = verticalOnce;
        }
    }

    public static StmtSpec parseStmt(String raw) {
        if (raw == null) {
            return new StmtSpec("", false);
        }
        String t = raw.trim();
        boolean vertical = false;
        // 允许 SELECT ...;\G 或 SELECT ...\G
        for (int guard = 0; guard < 4; guard++) {
            if (t.endsWith("\\G") || t.endsWith("\\g")) {
                vertical = true;
                t = t.substring(0, t.length() - 2).trim();
                continue;
            }
            if (t.endsWith(";")) {
                t = t.substring(0, t.length() - 1).trim();
                continue;
            }
            break;
        }
        return new StmtSpec(t, vertical);
    }

    /** 缓冲是否以 \\G/\\g 结束 (可作语句终止符, 替代 ;). */
    public static boolean endsWithVerticalTerminator(String buf) {
        if (buf == null) {
            return false;
        }
        String t = buf.trim();
        return t.endsWith("\\G") || t.endsWith("\\g");
    }

    /**
     * Yashan JDBC: 普通 SQL 不能带尾部分号; PL/SQL 匿名块必须以 END; 结束.
     */
    public static String normalizeForJdbc(String sql) {
        if (sql == null) {
            return null;
        }
        String t = parseStmt(sql).sql;
        if (t.isEmpty()) {
            return t;
        }
        if (looksLikePlsql(t)) {
            if (!t.endsWith(";")) {
                return t + ";";
            }
            return t;
        }
        while (t.endsWith(";")) {
            t = t.substring(0, t.length() - 1).trim();
        }
        return t;
    }

    public boolean execute(String sql) {
        StmtSpec spec = parseStmt(sql);
        return execute(spec.sql, Collections.<String>emptyList(), spec.verticalOnce);
    }

    /**
     * @param verticalOnce true=本条强制竖排; false=跟随会话 displayVertical
     */
    public boolean execute(String sql, boolean verticalOnce) {
        return execute(sql, Collections.<String>emptyList(), verticalOnce);
    }

    /**
     * @param binds 非空时用 PreparedStatement 按序绑定 (BINDVAR &var); 空则再尝试 :var
     */
    public boolean execute(String sql, List<String> binds, boolean verticalOnce) {
        if (sql == null) {
            return true;
        }
        String trimmed = normalizeForJdbc(sql);
        if (trimmed == null || trimmed.isEmpty()) {
            return true;
        }
        SessionConfig cfg = session.config();
        boolean vertical = verticalOnce || cfg.displayVertical;
        if (cfg.echo) {
            cfg.println(out, trimmed);
        }
        long t0 = System.nanoTime();
        List<String> bindList = binds == null ? Collections.<String>emptyList() : binds;
        if (bindList.isEmpty() && referencesRefCursor(trimmed, cfg)
                && isRefCursorCallCandidate(trimmed)) {
            try {
                boolean ok = executeWithRefCursors(trimmed, cfg, vertical);
                if (ok) {
                    if (cfg.serverOutput) {
                        drainDbmsOutput(cfg);
                    }
                    if (cfg.timing) {
                        double sec = (System.nanoTime() - t0) / 1e9;
                        cfg.println(out, String.format(Locale.ROOT,
                                "Elapsed: %d:%02d:%06.3f",
                                (int) (sec / 3600),
                                (int) ((sec % 3600) / 60),
                                sec % 60));
                    }
                    cfg.lastSqlCode = 0;
                    cfg.lastSqlFailed = false;
                }
                return ok;
            } catch (SQLException e) {
                cfg.lastSqlCode = sqlCodeOf(e);
                cfg.lastSqlFailed = true;
                err.println("SQL error: " + e.getMessage());
                return false;
            } catch (IllegalArgumentException e) {
                err.println("Error: " + e.getMessage());
                return false;
            }
        }
        ColonPlan colon = null;
        if (bindList.isEmpty() && !cfg.variables.isEmpty()) {
            colon = rewriteColonBinds(trimmed, cfg);
            if (colon != null && colon.names.isEmpty()) {
                colon = null;
            }
        }
        Statement st = null;
        try {
            if (!bindList.isEmpty()) {
                PreparedStatement ps = session.connection().prepareStatement(trimmed);
                st = ps;
                applyStatementOptions(ps, cfg);
                applyBinds(ps, bindList);
                boolean hasRs = ps.execute();
                drainResults(st, cfg, vertical, hasRs);
            } else if (colon != null) {
                executeWithColonBinds(colon, cfg, vertical);
            } else {
                st = session.connection().createStatement();
                applyStatementOptions(st, cfg);
                boolean hasRs = st.execute(trimmed);
                drainResults(st, cfg, vertical, hasRs);
            }
            if (cfg.serverOutput) {
                drainDbmsOutput(cfg);
            }
            if (cfg.timing) {
                double sec = (System.nanoTime() - t0) / 1e9;
                cfg.println(out, String.format(Locale.ROOT,
                        "Elapsed: %d:%02d:%06.3f",
                        (int) (sec / 3600),
                        (int) ((sec % 3600) / 60),
                        sec % 60));
            }
            cfg.lastSqlCode = 0;
            cfg.lastSqlFailed = false;
            return true;
        } catch (SQLException e) {
            cfg.lastSqlCode = sqlCodeOf(e);
            cfg.lastSqlFailed = true;
            err.println("SQL error: " + e.getMessage());
            if (!bindList.isEmpty()) {
                err.println("Hint: BINDVAR ON uses PreparedStatement; try SET BINDVAR OFF");
            }
            return false;
        } finally {
            if (st != null) {
                try {
                    st.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
        }
    }

    /** :name → ? 改写结果. */
    static final class ColonPlan {
        final String sql;
        final List<String> names;

        ColonPlan(String sql, List<String> names) {
            this.sql = sql;
            this.names = names;
        }
    }

    /**
     * 将已声明的 :var 改为 ? (跳过引号串); 未声明的 :xxx 原样保留.
     */
    static ColonPlan rewriteColonBinds(String sql, SessionConfig cfg) {
        if (sql == null || cfg == null || cfg.variables.isEmpty()) {
            return null;
        }
        StringBuilder sb = new StringBuilder(sql.length());
        List<String> names = new ArrayList<String>();
        int i = 0;
        int n = sql.length();
        while (i < n) {
            char c = sql.charAt(i);
            if (c == '\'' || c == '"') {
                char q = c;
                sb.append(c);
                i++;
                while (i < n) {
                    char d = sql.charAt(i);
                    sb.append(d);
                    i++;
                    if (d == q) {
                        if (q == '\'' && i < n && sql.charAt(i) == '\'') {
                            sb.append('\'');
                            i++;
                            continue;
                        }
                        break;
                    }
                }
                continue;
            }
            if (c == ':' && i + 1 < n && isBindNameStart(sql.charAt(i + 1))) {
                int k = i + 1;
                int start = k;
                k++;
                while (k < n && isBindNameChar(sql.charAt(k))) {
                    k++;
                }
                String name = sql.substring(start, k).toUpperCase(Locale.ROOT);
                if (cfg.variables.containsKey(name)) {
                    sb.append('?');
                    names.add(name);
                    i = k;
                    continue;
                }
            }
            sb.append(c);
            i++;
        }
        return new ColonPlan(sb.toString(), names);
    }

    private void executeWithColonBinds(ColonPlan plan, SessionConfig cfg, boolean vertical)
            throws SQLException {
        // Yashan 对匿名块 OUT 绑定不稳定; PL/SQL 与 DQL 一律按 IN PreparedStatement
        // (赋值请用 EXEC :name := 字面量 客户端路径)
        PreparedStatement ps = session.connection().prepareStatement(plan.sql);
        try {
            applyStatementOptions(ps, cfg);
            for (int i = 0; i < plan.names.size(); i++) {
                applyBindVariable(ps, i + 1, cfg.variables.get(plan.names.get(i)));
            }
            boolean hasRs = ps.execute();
            drainResults(ps, cfg, vertical, hasRs);
        } finally {
            ps.close();
        }
    }

    private static void applyStatementOptions(Statement st, SessionConfig cfg) throws SQLException {
        if (cfg.statementTimeoutSec > 0) {
            st.setQueryTimeout(cfg.statementTimeoutSec);
        }
        if (cfg.arraySize > 0) {
            try {
                st.setFetchSize(cfg.arraySize);
            } catch (SQLException ignored) {
                // 驱动不支持则忽略
            }
        }
    }

    private static int jdbcTypeOf(SessionConfig.BindVariable bv) {
        if (bv == null || bv.kind == SessionConfig.BindVariable.Kind.NUMBER) {
            return Types.NUMERIC;
        }
        return Types.VARCHAR;
    }

    private static void applyBindVariable(PreparedStatement ps, int idx,
                                          SessionConfig.BindVariable bv) throws SQLException {
        if (bv == null || bv.value == null) {
            ps.setNull(idx, jdbcTypeOf(bv));
            return;
        }
        if (bv.kind == SessionConfig.BindVariable.Kind.NUMBER) {
            try {
                ps.setBigDecimal(idx, new BigDecimal(bv.value.trim()));
            } catch (NumberFormatException e) {
                ps.setString(idx, bv.value);
            }
            return;
        }
        ps.setString(idx, bv.value);
    }

    private static boolean isBindNameStart(char c) {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
    }

    private static boolean isBindNameChar(char c) {
        return isBindNameStart(c) || (c >= '0' && c <= '9') || c == '_' || c == '$' || c == '#';
    }

    private void drainResults(Statement st, SessionConfig cfg, boolean vertical, boolean hasRs)
            throws SQLException {
        while (true) {
            if (hasRs) {
                ResultSet rs = st.getResultSet();
                printResultSet(rs, cfg, vertical);
                rs.close();
            } else {
                int uc = st.getUpdateCount();
                if (uc == -1) {
                    break;
                }
                if (cfg.feedback && uc >= cfg.feedbackMin) {
                    cfg.println(out, "");
                    cfg.println(out, uc + " row" + (uc == 1 ? "" : "s") + " updated.");
                    cfg.println(out, "");
                }
            }
            hasRs = st.getMoreResults();
        }
    }

    private static final Pattern INT_BIND = Pattern.compile("-?\\d+");
    private static final Pattern DEC_BIND = Pattern.compile("-?\\d+\\.\\d+");
    private static final Pattern YAS_CODE = Pattern.compile("(?i)YAS-(\\d+)");

    /** 从 SQLException 提取退出/WHENEVER 用错误码. */
    public static int sqlCodeOf(SQLException e) {
        if (e == null) {
            return 1;
        }
        int c = e.getErrorCode();
        if (c != 0) {
            return c;
        }
        String msg = e.getMessage();
        if (msg != null) {
            java.util.regex.Matcher m = YAS_CODE.matcher(msg);
            if (m.find()) {
                try {
                    return Integer.parseInt(m.group(1));
                } catch (NumberFormatException ignored) {
                    // fall through
                }
            }
        }
        return 1;
    }

    private static void applyBinds(PreparedStatement ps, List<String> binds) throws SQLException {
        for (int i = 0; i < binds.size(); i++) {
            String val = binds.get(i);
            int idx = i + 1;
            if (val == null) {
                ps.setNull(idx, Types.VARCHAR);
                continue;
            }
            if (INT_BIND.matcher(val).matches()) {
                try {
                    ps.setLong(idx, Long.parseLong(val));
                    continue;
                } catch (NumberFormatException ignored) {
                    // fall through to string
                }
            }
            if (DEC_BIND.matcher(val).matches()) {
                try {
                    ps.setBigDecimal(idx, new BigDecimal(val));
                    continue;
                } catch (NumberFormatException ignored) {
                    // fall through
                }
            }
            ps.setString(idx, val);
        }
    }

    /** 拉取 DBMS_OUTPUT 缓冲并打印 (GET_LINE status!=0 结束). */
    private void drainDbmsOutput(SessionConfig cfg) {
        CallableStatement cs = null;
        try {
            cs = session.connection().prepareCall("BEGIN DBMS_OUTPUT.GET_LINE(?, ?); END;");
            cs.registerOutParameter(1, Types.VARCHAR);
            cs.registerOutParameter(2, Types.INTEGER);
            while (true) {
                cs.execute();
                int status = cs.getInt(2);
                if (status != 0) {
                    break;
                }
                String line = cs.getString(1);
                cfg.println(out, line == null ? "" : line);
            }
        } catch (SQLException e) {
            err.println("WARN: DBMS_OUTPUT fetch failed: " + e.getMessage());
        } finally {
            if (cs != null) {
                try {
                    cs.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
        }
    }

    /** PRINT REFCURSOR: 复用结果集打印, 不关闭 RS. */
    public void printCursorResult(ResultSet rs, SessionConfig cfg) throws SQLException {
        if (rs == null || cfg == null) {
            return;
        }
        printResultSet(rs, cfg, cfg.displayVertical);
    }

    private void printResultSet(ResultSet rs, SessionConfig cfg, boolean vertical)
            throws SQLException {
        ResultSetMetaData md = rs.getMetaData();
        int cols = md.getColumnCount();
        String[] allRaw = new String[cols];
        String[] allHeaders = new String[cols];
        SessionConfig.ColumnFormat[] allFmt = new SessionConfig.ColumnFormat[cols];
        boolean[] visible = new boolean[cols];
        int visCount = 0;
        for (int i = 1; i <= cols; i++) {
            String h = md.getColumnLabel(i);
            if (h == null || h.isEmpty()) {
                h = md.getColumnName(i);
            }
            allRaw[i - 1] = h == null ? "?" : h;
            allFmt[i - 1] = cfg.getColumn(allRaw[i - 1]);
            String hea = cfg.getColHeading(allRaw[i - 1]);
            allHeaders[i - 1] = hea != null ? hea : allRaw[i - 1];
            boolean nop = allFmt[i - 1] != null && allFmt[i - 1].noprint;
            visible[i - 1] = !nop;
            if (visible[i - 1]) {
                visCount++;
            }
        }

        List<String[]> rows = new ArrayList<String[]>();
        String[] prevRaw = null;
        int maxRows = cfg.maxRows;
        boolean truncated = false;
        while (rs.next()) {
            if (maxRows > 0 && rows.size() >= maxRows) {
                truncated = true;
                break;
            }
            String[] rawRow = new String[cols];
            String[] row = new String[cols];
            for (int i = 1; i <= cols; i++) {
                String raw = cellToString(rs, i, md.getColumnType(i), cfg);
                rawRow[i - 1] = raw;
                row[i - 1] = formatCellValue(raw, allFmt[i - 1], md.getColumnType(i), cfg);
            }
            // NEW_VALUE/OLD_VALUE 使用未格式化原值
            applyNewOldValues(cfg, allRaw, allFmt, rawRow, prevRaw);
            prevRaw = rawRow;
            rows.add(row);
        }

        // 投影到可见列
        String[] headers = new String[visCount];
        String[] rawNames = new String[visCount];
        SessionConfig.ColumnFormat[] fmts = new SessionConfig.ColumnFormat[visCount];
        int[] srcIdx = new int[visCount];
        int vi = 0;
        for (int i = 0; i < cols; i++) {
            if (!visible[i]) {
                continue;
            }
            headers[vi] = allHeaders[i];
            rawNames[vi] = allRaw[i];
            fmts[vi] = allFmt[i];
            srcIdx[vi] = i;
            vi++;
        }
        List<String[]> visRows = new ArrayList<String[]>();
        for (String[] row : rows) {
            String[] vr = new String[visCount];
            for (int j = 0; j < visCount; j++) {
                vr[j] = row[srcIdx[j]];
            }
            visRows.add(vr);
        }

        if (vertical) {
            printVertical(headers, visRows, cfg);
        } else {
            printTable(headers, rawNames, fmts, visRows, cfg, md, srcIdx);
        }

        // FEEDBACK ON: 0 行也提示 (sqlplus: no rows selected)
        if (cfg.feedback && (rows.isEmpty() || rows.size() >= cfg.feedbackMin)) {
            cfg.println(out, "");
            if (rows.isEmpty()) {
                cfg.println(out, "no rows selected");
            } else {
                cfg.println(out, rows.size() + " row" + (rows.size() == 1 ? "" : "s") + " selected.");
            }
            if (truncated) {
                cfg.println(out, "truncated at " + maxRows + " rows");
            }
            cfg.println(out, "");
        } else if (truncated) {
            cfg.println(out, "truncated at " + maxRows + " rows");
        }
    }

    private static void applyNewOldValues(SessionConfig cfg, String[] rawNames,
                                          SessionConfig.ColumnFormat[] fmts,
                                          String[] row, String[] prevRow) {
        for (int i = 0; i < rawNames.length; i++) {
            SessionConfig.ColumnFormat cf = fmts[i];
            if (cf == null) {
                continue;
            }
            String cur = row[i] == null ? "" : row[i];
            if (cf.oldValue != null && prevRow != null) {
                cfg.define(cf.oldValue, prevRow[i] == null ? "" : prevRow[i]);
            }
            if (cf.newValue != null) {
                cfg.define(cf.newValue, cur);
            }
        }
    }

    private String formatCellValue(String raw, SessionConfig.ColumnFormat cf, int jdbcType,
                                   SessionConfig cfg) {
        if (raw == null || raw.isEmpty()) {
            return raw;
        }
        boolean jdbcNum = isJdbcNumeric(jdbcType);
        if (cf != null && cf.numFormat != null && (jdbcNum || looksNumeric(raw))) {
            return applyNumFormat(raw.trim(), cf.numFormat);
        }
        if (jdbcNum && cfg.numFormat != null && !cfg.numFormat.isEmpty()
                && (cf == null || cf.numFormat == null)) {
            return applyNumFormat(raw.trim(), cfg.numFormat);
        }
        if (jdbcNum && (cf == null || cf.width == null) && cfg.numWidth > 0) {
            String t = raw.trim();
            if (t.length() >= cfg.numWidth) {
                return t;
            }
            StringBuilder sb = new StringBuilder();
            for (int i = t.length(); i < cfg.numWidth; i++) {
                sb.append(' ');
            }
            sb.append(t);
            return sb.toString();
        }
        return raw;
    }

    private static boolean isJdbcNumeric(int jdbcType) {
        return jdbcType == Types.NUMERIC || jdbcType == Types.DECIMAL || jdbcType == Types.INTEGER
                || jdbcType == Types.BIGINT || jdbcType == Types.SMALLINT || jdbcType == Types.TINYINT
                || jdbcType == Types.FLOAT || jdbcType == Types.DOUBLE || jdbcType == Types.REAL;
    }

    private static boolean looksNumeric(String raw) {
        try {
            new BigDecimal(raw.trim());
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** 实用数值 FORMAT: 可选千分位, 按掩码宽度右对齐空格填充. */
    static String applyNumFormat(String num, String mask) {
        try {
            BigDecimal bd = new BigDecimal(num);
            boolean group = mask.indexOf(',') >= 0;
            String core;
            int dot = mask.lastIndexOf('.');
            if (dot >= 0) {
                int scale = 0;
                for (int i = dot + 1; i < mask.length(); i++) {
                    char c = mask.charAt(i);
                    if (c == '9' || c == '0' || c == '#') {
                        scale++;
                    }
                }
                bd = bd.setScale(scale, BigDecimal.ROUND_HALF_UP);
                core = bd.toPlainString();
            } else {
                core = bd.setScale(0, BigDecimal.ROUND_HALF_UP).toPlainString();
            }
            if (group) {
                core = insertGroupCommas(core);
            }
            int width = SessionConfig.numFormatWidth(mask);
            if (core.length() >= width) {
                return core;
            }
            StringBuilder sb = new StringBuilder();
            for (int i = core.length(); i < width; i++) {
                sb.append(' ');
            }
            sb.append(core);
            return sb.toString();
        } catch (Exception e) {
            return num;
        }
    }

    private static String insertGroupCommas(String plain) {
        boolean neg = plain.startsWith("-");
        String s = neg ? plain.substring(1) : plain;
        int dot = s.indexOf('.');
        String intp = dot >= 0 ? s.substring(0, dot) : s;
        String frac = dot >= 0 ? s.substring(dot) : "";
        StringBuilder sb = new StringBuilder();
        int cnt = 0;
        for (int i = intp.length() - 1; i >= 0; i--) {
            if (cnt > 0 && cnt % 3 == 0) {
                sb.append(',');
            }
            sb.append(intp.charAt(i));
            cnt++;
        }
        String rev = sb.reverse().toString();
        return (neg ? "-" : "") + rev + frac;
    }

    private void printTable(String[] headers, String[] rawNames, SessionConfig.ColumnFormat[] fmts,
                            List<String[]> rows, SessionConfig cfg, ResultSetMetaData md,
                            int[] srcIdx) throws SQLException {
        int[] widths = resolveWidths(rawNames, headers, fmts, rows, cfg, md, srcIdx);
        boolean showHeading = cfg.heading && cfg.pagesize > 0;
        int page = cfg.pagesize > 0 ? cfg.pagesize : Integer.MAX_VALUE;
        if (cfg.ttitleOn && cfg.ttitle != null && !cfg.ttitle.isEmpty()) {
            cfg.println(out, expandTitle(cfg.ttitle, cfg));
        }
        if (showHeading && rows.isEmpty()) {
            printAligned(headers, widths, fmts, true, cfg);
            printUnderline(widths, cfg);
        }
        // break 列索引
        int[] breakIdx = resolveBreakIndexes(rawNames, cfg);
        String[] lastBreakVals = new String[breakIdx.length];
        // 分组累计: computes keyed by ofColumn
        java.util.Map<String, Aggregate> groupAgg = new java.util.HashMap<String, Aggregate>();
        java.util.Map<String, Aggregate> reportAgg = new java.util.HashMap<String, Aggregate>();
        initAggregates(cfg, groupAgg, reportAgg);

        int printed = 0;
        for (int r = 0; r < rows.size(); r++) {
            String[] row = rows.get(r);
            boolean broke = false;
            if (r > 0 && breakIdx.length > 0) {
                for (int bi = 0; bi < breakIdx.length; bi++) {
                    int ci = breakIdx[bi];
                    String cur = row[ci] == null ? "" : row[ci];
                    String prev = lastBreakVals[bi] == null ? "" : lastBreakVals[bi];
                    if (!cur.equals(prev)) {
                        broke = true;
                        break;
                    }
                }
            }
            if (broke) {
                printComputeLines(cfg, headers, rawNames, widths, fmts, groupAgg, false);
                resetAggregates(groupAgg);
                SessionConfig.BreakSpec bs = cfg.breaks.isEmpty() ? null : cfg.breaks.get(0);
                if (bs != null && bs.skipPage) {
                    printed = 0;
                } else if (bs != null) {
                    for (int s = 0; s < bs.skipLines; s++) {
                        cfg.println(out, "");
                    }
                }
            }
            if (showHeading && (printed % page == 0)) {
                printAligned(headers, widths, fmts, true, cfg);
                printUnderline(widths, cfg);
            }
            printWrappedRow(row, widths, fmts, cfg);
            accumulate(cfg, rawNames, row, groupAgg, reportAgg);
            for (int bi = 0; bi < breakIdx.length; bi++) {
                lastBreakVals[bi] = row[breakIdx[bi]] == null ? "" : row[breakIdx[bi]];
            }
            printed++;
        }
        if (!rows.isEmpty()) {
            printComputeLines(cfg, headers, rawNames, widths, fmts, groupAgg, false);
            printComputeLines(cfg, headers, rawNames, widths, fmts, reportAgg, true);
        }
        if (cfg.btitleOn && cfg.btitle != null && !cfg.btitle.isEmpty()) {
            cfg.println(out, expandTitle(cfg.btitle, cfg));
        }
    }

    private static String expandTitle(String title, SessionConfig cfg) {
        // 简单替换 &var (已定义)
        if (title == null || !cfg.defineOn || title.indexOf(cfg.defineChar) < 0) {
            return title;
        }
        String r = cfg.substitute(title, null, null, System.err);
        return r == null ? title : r;
    }

    private static int[] resolveBreakIndexes(String[] rawNames, SessionConfig cfg) {
        if (cfg.breaks.isEmpty()) {
            return new int[0];
        }
        List<Integer> idx = new ArrayList<Integer>();
        for (SessionConfig.BreakSpec b : cfg.breaks) {
            for (int i = 0; i < rawNames.length; i++) {
                if (rawNames[i].equalsIgnoreCase(b.column)) {
                    idx.add(Integer.valueOf(i));
                    break;
                }
            }
        }
        int[] out = new int[idx.size()];
        for (int i = 0; i < idx.size(); i++) {
            out[i] = idx.get(i).intValue();
        }
        return out;
    }

    private static final class Aggregate {
        String func;
        BigDecimal sum = BigDecimal.ZERO;
        long count;
        BigDecimal min;
        BigDecimal max;

        Aggregate(String func) {
            this.func = func;
        }

        void add(String cell) {
            if (cell == null || cell.trim().isEmpty()) {
                return;
            }
            try {
                BigDecimal v = new BigDecimal(cell.trim().replace(",", ""));
                count++;
                sum = sum.add(v);
                if (min == null || v.compareTo(min) < 0) {
                    min = v;
                }
                if (max == null || v.compareTo(max) > 0) {
                    max = v;
                }
            } catch (Exception ignored) {
                if ("COUNT".equals(func)) {
                    count++;
                }
            }
        }

        String value() {
            if ("COUNT".equals(func)) {
                return String.valueOf(count);
            }
            if (count == 0) {
                return "";
            }
            if ("SUM".equals(func)) {
                return sum.toPlainString();
            }
            if ("AVG".equals(func)) {
                return sum.divide(BigDecimal.valueOf(count), 4, BigDecimal.ROUND_HALF_UP).toPlainString();
            }
            if ("MIN".equals(func)) {
                return min == null ? "" : min.toPlainString();
            }
            if ("MAX".equals(func)) {
                return max == null ? "" : max.toPlainString();
            }
            return "";
        }
    }

    private static void initAggregates(SessionConfig cfg,
                                       java.util.Map<String, Aggregate> groupAgg,
                                       java.util.Map<String, Aggregate> reportAgg) {
        for (SessionConfig.ComputeSpec c : cfg.computes) {
            String key = c.func + "|" + c.ofColumn;
            if ("REPORT".equals(c.onBreak)) {
                reportAgg.put(key, new Aggregate(c.func));
            } else {
                groupAgg.put(key, new Aggregate(c.func));
            }
        }
    }

    private static void resetAggregates(java.util.Map<String, Aggregate> agg) {
        for (String k : new ArrayList<String>(agg.keySet())) {
            Aggregate a = agg.get(k);
            agg.put(k, new Aggregate(a.func));
        }
    }

    private static void accumulate(SessionConfig cfg, String[] rawNames, String[] row,
                                   java.util.Map<String, Aggregate> groupAgg,
                                   java.util.Map<String, Aggregate> reportAgg) {
        for (SessionConfig.ComputeSpec c : cfg.computes) {
            int ci = -1;
            for (int i = 0; i < rawNames.length; i++) {
                if (rawNames[i].equalsIgnoreCase(c.ofColumn)) {
                    ci = i;
                    break;
                }
            }
            if (ci < 0) {
                continue;
            }
            String key = c.func + "|" + c.ofColumn;
            Aggregate a = "REPORT".equals(c.onBreak) ? reportAgg.get(key) : groupAgg.get(key);
            if (a != null) {
                a.add(row[ci]);
            }
        }
    }

    private void printComputeLines(SessionConfig cfg, String[] headers, String[] rawNames,
                                   int[] widths, SessionConfig.ColumnFormat[] fmts,
                                   java.util.Map<String, Aggregate> agg, boolean report) {
        if (agg.isEmpty()) {
            return;
        }
        for (SessionConfig.ComputeSpec c : cfg.computes) {
            boolean isReport = "REPORT".equals(c.onBreak);
            if (isReport != report) {
                continue;
            }
            String key = c.func + "|" + c.ofColumn;
            Aggregate a = agg.get(key);
            if (a == null) {
                continue;
            }
            // 单行标注, 避免窄 BREAK 列把 SUM 拆成逐字符换行
            String label = (report ? "report " : "") + c.func.toLowerCase(Locale.ROOT)
                    + " of " + c.ofColumn;
            cfg.println(out, "****\t\t" + label + "\t\t" + a.value());
        }
    }

    /** MySQL \\G 风格: 每行一条记录, 字段竖排. */
    private void printVertical(String[] headers, List<String[]> rows, SessionConfig cfg) {
        int nameW = 0;
        for (String h : headers) {
            if (h != null && h.length() > nameW) {
                nameW = h.length();
            }
        }
        if (nameW < 1) {
            nameW = 1;
        }
        if (rows.isEmpty()) {
            return;
        }
        for (int r = 0; r < rows.size(); r++) {
            cfg.println(out, "*************************** " + (r + 1) + ". row ***************************");
            String[] row = rows.get(r);
            for (int c = 0; c < headers.length; c++) {
                String name = headers[c] == null ? "?" : headers[c];
                String val = row[c] == null ? "" : row[c];
                StringBuilder sb = new StringBuilder();
                for (int p = name.length(); p < nameW; p++) {
                    sb.append(' ');
                }
                sb.append(name).append(": ").append(val);
                cfg.println(out, sb.toString());
            }
        }
    }

    private int[] resolveWidths(String[] rawNames, String[] headers, SessionConfig.ColumnFormat[] fmts,
                                List<String[]> rows, SessionConfig cfg, ResultSetMetaData md,
                                int[] srcIdx) throws SQLException {
        int cols = headers.length;
        int[] widths = new int[cols];
        int cap = Math.max(1, Math.min(cfg.linesize, SessionConfig.DEFAULT_COL_WIDTH));
        for (int i = 0; i < cols; i++) {
            Integer fixed = cfg.getColWidth(rawNames[i]);
            if (fixed != null && fixed.intValue() > 0) {
                widths[i] = fixed.intValue();
                continue;
            }
            int w = headers[i].length();
            int display = 0;
            try {
                display = md.getColumnDisplaySize(srcIdx[i] + 1);
            } catch (SQLException ignored) {
                display = 0;
            }
            if (display > 0) {
                w = Math.max(w, Math.min(display, cap));
            }
            for (String[] row : rows) {
                String cell = row[i] == null ? "" : row[i];
                w = Math.max(w, Math.min(cell.length(), cap));
            }
            if (w < 1) {
                w = 1;
            }
            widths[i] = w;
        }
        return widths;
    }

    private void printAligned(String[] cells, int[] widths, SessionConfig.ColumnFormat[] fmts,
                              boolean heading, SessionConfig cfg) {
        String sep = cfg.colSep == null ? " " : cfg.colSep;
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < cells.length; i++) {
            if (i > 0) {
                sb.append(sep);
            }
            String c = cells[i] == null ? "" : cells[i];
            sb.append(padCell(c, widths[i], justifyOf(fmts[i], heading)));
        }
        cfg.println(out, rtrim(sb.toString()));
    }

    private void printUnderline(int[] widths, SessionConfig cfg) {
        if (cfg.underline == null || cfg.underline.isEmpty()) {
            return;
        }
        char u = cfg.underline.charAt(0);
        String sep = cfg.colSep == null ? " " : cfg.colSep;
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < widths.length; i++) {
            if (i > 0) {
                sb.append(sep);
            }
            for (int j = 0; j < widths[i]; j++) {
                sb.append(u);
            }
        }
        cfg.println(out, sb.toString());
    }

    private void printWrappedRow(String[] cells, int[] widths, SessionConfig.ColumnFormat[] fmts,
                                 SessionConfig cfg) {
        int lines = 1;
        String[][] chunks = new String[cells.length][];
        String sep = cfg.colSep == null ? " " : cfg.colSep;
        for (int i = 0; i < cells.length; i++) {
            String text = cells[i] == null ? "" : cells[i];
            String mode = fmts[i] != null && fmts[i].wrap != null
                    ? fmts[i].wrap
                    : (cfg.wrapOn ? "WRAPPED" : "TRUNCATED");
            if ("TRUNCATED".equals(mode)) {
                if (text.length() > widths[i]) {
                    text = text.substring(0, widths[i]);
                }
                chunks[i] = new String[] {text};
            } else if ("WORD_WRAPPED".equals(mode)) {
                chunks[i] = wrapWords(text, widths[i]);
            } else {
                chunks[i] = wrap(text, widths[i]);
            }
            if (chunks[i].length > lines) {
                lines = chunks[i].length;
            }
        }
        for (int line = 0; line < lines; line++) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < cells.length; i++) {
                if (i > 0) {
                    sb.append(sep);
                }
                String part = line < chunks[i].length ? chunks[i][line] : "";
                sb.append(padCell(part, widths[i], justifyOf(fmts[i], false)));
            }
            cfg.println(out, rtrim(sb.toString()));
        }
    }

    private static String justifyOf(SessionConfig.ColumnFormat cf, boolean heading) {
        if (cf != null && cf.justify != null) {
            return cf.justify;
        }
        if (heading) {
            return "LEFT";
        }
        if (cf != null && cf.numFormat != null) {
            return "RIGHT";
        }
        return "LEFT";
    }

    private static String padCell(String c, int width, String justify) {
        if (c == null) {
            c = "";
        }
        if (c.length() > width) {
            c = c.substring(0, width);
        }
        int pad = width - c.length();
        if (pad <= 0) {
            return c;
        }
        String j = justify == null ? "LEFT" : justify;
        if ("RIGHT".equals(j)) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < pad; i++) {
                sb.append(' ');
            }
            sb.append(c);
            return sb.toString();
        }
        if ("CENTER".equals(j)) {
            int left = pad / 2;
            int right = pad - left;
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < left; i++) {
                sb.append(' ');
            }
            sb.append(c);
            for (int i = 0; i < right; i++) {
                sb.append(' ');
            }
            return sb.toString();
        }
        StringBuilder sb = new StringBuilder(c);
        for (int i = 0; i < pad; i++) {
            sb.append(' ');
        }
        return sb.toString();
    }

    static String[] wrapWords(String text, int width) {
        if (width < 1) {
            width = 1;
        }
        if (text == null || text.isEmpty()) {
            return new String[] {""};
        }
        List<String> out = new ArrayList<String>();
        String[] words = text.split("\\s+");
        StringBuilder line = new StringBuilder();
        for (String w : words) {
            if (w.isEmpty()) {
                continue;
            }
            if (line.length() == 0) {
                if (w.length() <= width) {
                    line.append(w);
                } else {
                    int i = 0;
                    while (i < w.length()) {
                        int end = Math.min(i + width, w.length());
                        out.add(w.substring(i, end));
                        i = end;
                    }
                }
            } else if (line.length() + 1 + w.length() <= width) {
                line.append(' ').append(w);
            } else {
                out.add(line.toString());
                line.setLength(0);
                if (w.length() <= width) {
                    line.append(w);
                } else {
                    int i = 0;
                    while (i < w.length()) {
                        int end = Math.min(i + width, w.length());
                        out.add(w.substring(i, end));
                        i = end;
                    }
                }
            }
        }
        if (line.length() > 0) {
            out.add(line.toString());
        }
        if (out.isEmpty()) {
            out.add("");
        }
        return out.toArray(new String[out.size()]);
    }

    private static String rtrim(String s) {
        int end = s.length();
        while (end > 0 && s.charAt(end - 1) == ' ') {
            end--;
        }
        return s.substring(0, end);
    }

    static String[] wrap(String text, int width) {
        if (width < 1) {
            width = 1;
        }
        if (text == null) {
            text = "";
        }
        if (text.isEmpty()) {
            return new String[]{""};
        }
        String[] paragraphs = text.split("\n", -1);
        List<String> out = new ArrayList<String>();
        for (String p : paragraphs) {
            if (p.isEmpty()) {
                out.add("");
                continue;
            }
            int i = 0;
            while (i < p.length()) {
                int end = Math.min(i + width, p.length());
                out.add(p.substring(i, end));
                i = end;
            }
        }
        return out.toArray(new String[out.size()]);
    }

    private static String cellToString(ResultSet rs, int i, int type, SessionConfig cfg)
            throws SQLException {
        Object v = rs.getObject(i);
        if (v == null || rs.wasNull()) {
            return cfg.nullText == null ? "" : cfg.nullText;
        }
        if (type == Types.BLOB || type == Types.BINARY || type == Types.VARBINARY
                || type == Types.LONGVARBINARY) {
            return "[BINARY]";
        }
        String s;
        if (type == Types.CLOB || type == Types.NCLOB || type == Types.LONGVARCHAR
                || type == Types.LONGNVARCHAR) {
            s = rs.getString(i);
            if (s == null) {
                return cfg.nullText == null ? "" : cfg.nullText;
            }
        } else {
            s = String.valueOf(v);
        }
        if (cfg.longSize > 0 && s.length() > cfg.longSize) {
            return s.substring(0, cfg.longSize);
        }
        return s;
    }

    private static final String PH_OUT = "\u0001OUT:";
    private static final String PH_IN = "\u0001IN:";
    private static final String PH_END = "\u0001";
    private static final Pattern OPEN_FOR = Pattern.compile(
            "(?i)OPEN\\s+:([A-Za-z][A-Za-z0-9_$#]*)\\s+FOR\\s+");
    private static final Pattern USING_WORD = Pattern.compile("(?i)\\bUSING\\b");

    private static final class BindSlot {
        final String name;
        final boolean out;

        BindSlot(String name, boolean out) {
            this.name = name;
            this.out = out;
        }
    }

    private static boolean referencesRefCursor(String sql, SessionConfig cfg) {
        if (sql == null || cfg == null || cfg.variables.isEmpty()) {
            return false;
        }
        ColonPlan plan = rewriteColonBinds(sql, cfg);
        if (plan == null) {
            return false;
        }
        for (String n : plan.names) {
            SessionConfig.BindVariable bv = cfg.getVariable(n);
            if (bv != null && bv.kind == SessionConfig.BindVariable.Kind.REFCURSOR) {
                return true;
            }
        }
        return false;
    }

    private static boolean isRefCursorCallCandidate(String sql) {
        if (sql == null) {
            return false;
        }
        String t = sql.trim();
        if (looksLikePlsql(t)) {
            return true;
        }
        String u = t.toUpperCase(Locale.ROOT);
        return u.startsWith("CALL") || u.startsWith("{CALL") || u.startsWith("{ CALL");
    }

    private boolean executeWithRefCursors(String sql, SessionConfig cfg, boolean vertical)
            throws SQLException {
        rejectUnsupportedMixed(sql, cfg);
        OpenRewriteResult open = rewriteOpenForRefCursors(sql, cfg);
        if (open.error != null) {
            throw new IllegalArgumentException(open.error);
        }
        String text = open.sql;
        CallBindPlan plan = rewriteColonToPlaceholders(text, cfg);
        if (plan.error != null) {
            throw new IllegalArgumentException(plan.error);
        }
        List<BindSlot> slots = new ArrayList<BindSlot>();
        StringBuilder finalSql = new StringBuilder();
        int i = 0;
        String s = plan.sql;
        while (i < s.length()) {
            if (s.startsWith(PH_OUT, i) || s.startsWith(PH_IN, i)) {
                boolean out = s.startsWith(PH_OUT, i);
                int start = i + (out ? PH_OUT.length() : PH_IN.length());
                int end = s.indexOf(PH_END, start);
                if (end < 0) {
                    throw new IllegalArgumentException("internal bind placeholder corrupt");
                }
                String name = s.substring(start, end);
                slots.add(new BindSlot(name, out));
                finalSql.append('?');
                i = end + PH_END.length();
                continue;
            }
            finalSql.append(s.charAt(i));
            i++;
        }
        CallableStatement cs = session.connection().prepareCall(finalSql.toString());
        boolean assignOk = false;
        try {
            applyStatementOptions(cs, cfg);
            for (int idx = 0; idx < slots.size(); idx++) {
                BindSlot slot = slots.get(idx);
                SessionConfig.BindVariable bv = cfg.getVariable(slot.name);
                if (bv == null) {
                    throw new IllegalArgumentException("undefined variable " + slot.name);
                }
                int jdbcIdx = idx + 1;
                if (slot.out) {
                    if (bv.kind != SessionConfig.BindVariable.Kind.REFCURSOR) {
                        throw new IllegalArgumentException(
                                "unsupported mixed binds with REFCURSOR in this statement");
                    }
                    cs.registerOutParameter(jdbcIdx, Types.REF_CURSOR);
                } else {
                    if (bv.kind == SessionConfig.BindVariable.Kind.REFCURSOR) {
                        throw new IllegalArgumentException(
                                "unsupported mixed binds with REFCURSOR in this statement");
                    }
                    applyBindVariable(cs, jdbcIdx, bv);
                }
            }
            cs.execute();
            for (int idx = 0; idx < slots.size(); idx++) {
                BindSlot slot = slots.get(idx);
                if (!slot.out) {
                    continue;
                }
                Object o = cs.getObject(idx + 1);
                if (!(o instanceof ResultSet)) {
                    throw new SQLException("REF_CURSOR OUT did not return ResultSet for :"
                            + slot.name);
                }
                SessionConfig.BindVariable bv = cfg.getVariable(slot.name);
                cfg.setVariableCursor(bv, (ResultSet) o, cs);
            }
            assignOk = true;
            // 无直接结果集要 drain; 游标已挂到变量
            return true;
        } finally {
            if (!assignOk) {
                try {
                    cs.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
        }
    }

    private static void rejectUnsupportedMixed(String sql, SessionConfig cfg) {
        // 标量 VARIABLE 出现在 :name := 左值
        Matcher m = Pattern.compile(":([A-Za-z][A-Za-z0-9_$#]*)\\s*:=").matcher(sql);
        while (m.find()) {
            String name = m.group(1).toUpperCase(Locale.ROOT);
            SessionConfig.BindVariable bv = cfg.getVariable(name);
            if (bv != null && bv.kind != SessionConfig.BindVariable.Kind.REFCURSOR) {
                throw new IllegalArgumentException(
                        "unsupported mixed binds with REFCURSOR in this statement");
            }
        }
    }

    private static final class OpenRewriteResult {
        final String sql;
        final String error;

        OpenRewriteResult(String sql, String error) {
            this.sql = sql;
            this.error = error;
        }
    }

    private static final class CallBindPlan {
        final String sql;
        final String error;

        CallBindPlan(String sql, String error) {
            this.sql = sql;
            this.error = error;
        }
    }

    static OpenRewriteResult rewriteOpenForRefCursors(String sql, SessionConfig cfg) {
        if (sql == null) {
            return new OpenRewriteResult("", null);
        }
        StringBuilder out = new StringBuilder();
        List<String> locals = new ArrayList<String>();
        Set<String> usedLocal = new HashSet<String>();
        collectDeclareNames(sql, usedLocal);
        int i = 0;
        int n = sql.length();
        while (i < n) {
            if (sql.charAt(i) == '\'' || sql.charAt(i) == '"') {
                char q = sql.charAt(i);
                out.append(q);
                i++;
                while (i < n) {
                    char d = sql.charAt(i);
                    out.append(d);
                    i++;
                    if (d == q) {
                        if (q == '\'' && i < n && sql.charAt(i) == '\'') {
                            out.append('\'');
                            i++;
                            continue;
                        }
                        break;
                    }
                }
                continue;
            }
            Matcher om = OPEN_FOR.matcher(sql);
            om.region(i, n);
            if (om.lookingAt()) {
                String varName = om.group(1).toUpperCase(Locale.ROOT);
                SessionConfig.BindVariable bv = cfg.getVariable(varName);
                if (bv != null && bv.kind == SessionConfig.BindVariable.Kind.REFCURSOR) {
                    int queryStart = om.end();
                    int queryEnd = scanUnquotedSemicolon(sql, queryStart);
                    if (queryEnd < 0) {
                        return new OpenRewriteResult(null,
                                "OPEN :" + varName + " FOR requires terminating semicolon");
                    }
                    String query = sql.substring(queryStart, queryEnd).trim();
                    if (USING_WORD.matcher(query).find()) {
                        return new OpenRewriteResult(null,
                                "OPEN :" + varName + " FOR ... USING is not supported");
                    }
                    String local = nextLocalName(usedLocal, locals.size() + 1);
                    usedLocal.add(local.toUpperCase(Locale.ROOT));
                    locals.add(local);
                    out.append("OPEN ").append(local).append(" FOR ").append(query)
                            .append("; ").append(PH_OUT).append(varName).append(PH_END)
                            .append(" := ").append(local).append(';');
                    i = queryEnd + 1; // skip ';'
                    continue;
                }
            }
            out.append(sql.charAt(i));
            i++;
        }
        String rewritten = out.toString();
        if (!locals.isEmpty()) {
            rewritten = injectDeclareCursors(rewritten, locals);
        }
        return new OpenRewriteResult(rewritten, null);
    }

    private static String nextLocalName(Set<String> used, int startN) {
        int n = startN;
        while (true) {
            String cand = "c_rc_" + n;
            if (!used.contains(cand.toUpperCase(Locale.ROOT))) {
                return cand;
            }
            n++;
        }
    }

    private static void collectDeclareNames(String sql, Set<String> used) {
        String u = sql.trim();
        if (!u.toUpperCase(Locale.ROOT).startsWith("DECLARE")) {
            return;
        }
        int begin = indexOfKeyword(sql, "BEGIN", 0);
        if (begin < 0) {
            return;
        }
        String decl = sql.substring(0, begin);
        Matcher m = Pattern.compile("(?i)\\b([A-Za-z][A-Za-z0-9_$#]*)\\s+").matcher(decl);
        while (m.find()) {
            String id = m.group(1).toUpperCase(Locale.ROOT);
            if ("DECLARE".equals(id) || "AS".equals(id) || "IS".equals(id)) {
                continue;
            }
            used.add(id);
        }
    }

    private static int indexOfKeyword(String sql, String kw, int from) {
        Pattern p = Pattern.compile("(?i)\\b" + kw + "\\b");
        Matcher m = p.matcher(sql);
        if (from > 0) {
            m.region(from, sql.length());
        }
        // skip quotes roughly by scanning
        int i = from;
        while (i < sql.length()) {
            char c = sql.charAt(i);
            if (c == '\'' || c == '"') {
                char q = c;
                i++;
                while (i < sql.length()) {
                    char d = sql.charAt(i++);
                    if (d == q) {
                        if (q == '\'' && i < sql.length() && sql.charAt(i) == '\'') {
                            i++;
                            continue;
                        }
                        break;
                    }
                }
                continue;
            }
            m.region(i, sql.length());
            if (m.lookingAt()) {
                return m.start();
            }
            i++;
        }
        return -1;
    }

    private static int scanUnquotedSemicolon(String sql, int from) {
        int i = from;
        int n = sql.length();
        while (i < n) {
            char c = sql.charAt(i);
            if (c == '\'' || c == '"') {
                char q = c;
                i++;
                while (i < n) {
                    char d = sql.charAt(i);
                    i++;
                    if (d == q) {
                        if (q == '\'' && i < n && sql.charAt(i) == '\'') {
                            i++;
                            continue;
                        }
                        break;
                    }
                }
                continue;
            }
            if (c == ';') {
                return i;
            }
            i++;
        }
        return -1;
    }

    static String injectDeclareCursors(String sql, List<String> locals) {
        if (locals == null || locals.isEmpty()) {
            return sql;
        }
        StringBuilder declLines = new StringBuilder();
        for (String loc : locals) {
            declLines.append("  ").append(loc).append(" SYS_REFCURSOR;\n");
        }
        String trimmed = sql;
        int lead = 0;
        while (lead < trimmed.length()
                && Character.isWhitespace(trimmed.charAt(lead))) {
            lead++;
        }
        String body = trimmed.substring(lead);
        String upper = body.toUpperCase(Locale.ROOT);
        if (upper.startsWith("DECLARE")) {
            int beginAt = indexOfKeyword(body, "BEGIN", 0);
            if (beginAt < 0) {
                return sql;
            }
            return body.substring(0, beginAt) + declLines + body.substring(beginAt);
        }
        if (upper.startsWith("BEGIN")) {
            return "DECLARE\n" + declLines + body;
        }
        return sql;
    }

    /** 将 :var 改为 OUT/IN 占位符 (已是占位符的跳过). */
    static CallBindPlan rewriteColonToPlaceholders(String sql, SessionConfig cfg) {
        if (sql == null || cfg == null) {
            return new CallBindPlan(sql, null);
        }
        StringBuilder sb = new StringBuilder(sql.length());
        int i = 0;
        int n = sql.length();
        while (i < n) {
            if (sql.startsWith(PH_OUT, i) || sql.startsWith(PH_IN, i)) {
                int end = sql.indexOf(PH_END, i + 4);
                if (end < 0) {
                    return new CallBindPlan(null, "internal bind placeholder corrupt");
                }
                sb.append(sql, i, end + PH_END.length());
                i = end + PH_END.length();
                continue;
            }
            char c = sql.charAt(i);
            if (c == '\'' || c == '"') {
                char q = c;
                sb.append(c);
                i++;
                while (i < n) {
                    char d = sql.charAt(i);
                    sb.append(d);
                    i++;
                    if (d == q) {
                        if (q == '\'' && i < n && sql.charAt(i) == '\'') {
                            sb.append('\'');
                            i++;
                            continue;
                        }
                        break;
                    }
                }
                continue;
            }
            if (c == ':' && i + 1 < n && isBindNameStart(sql.charAt(i + 1))) {
                int k = i + 1;
                int start = k;
                k++;
                while (k < n && isBindNameChar(sql.charAt(k))) {
                    k++;
                }
                String name = sql.substring(start, k).toUpperCase(Locale.ROOT);
                SessionConfig.BindVariable bv = cfg.getVariable(name);
                if (bv != null) {
                    if (bv.kind == SessionConfig.BindVariable.Kind.REFCURSOR) {
                        sb.append(PH_OUT).append(name).append(PH_END);
                    } else {
                        sb.append(PH_IN).append(name).append(PH_END);
                    }
                    i = k;
                    continue;
                }
            }
            sb.append(c);
            i++;
        }
        return new CallBindPlan(sb.toString(), null);
    }
}
