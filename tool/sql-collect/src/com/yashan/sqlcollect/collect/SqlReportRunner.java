package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.db.HtzTables;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.log.DualLogger;

import java.io.IOException;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * JDBC 执行报告 SELECT 段 ({@link ReportSelectScript}: PLAN / sqlarea / AWR / objects).
 * ORIGINAL/LITERAL 由 {@link JdbcReportBuilder} 纯 Java 写出.
 * sql_id 一律 JDBC ? 绑定, 避免字面量替换撑爆 share pool.
 * HTZ 模式: PLAN/sqlarea/v$sql 改写为 HTZ_GV_*; AWR/dba_* 不改写.
 */
public class SqlReportRunner {

    private final DualLogger log;

    public SqlReportRunner(DualLogger log) {
        this.log = log;
    }

    /**
     * 将报告 SELECT 中的 v$/gv$ 计划与统计视图改为登录用户 HTZ 表.
     * 先替换长名 (sql_plan/sqlarea/sqlstats), 再替换 v$sql/gv$sql.
     * 不改写 AWR/WRH$/dba_* (模板中通常不含上述需替换名).
     */
    static String rewriteViewsForHtz(String sql, String owner) {
        if (sql == null || sql.isEmpty()) {
            return sql == null ? "" : sql;
        }
        String o = HtzTables.normalizeOwner(owner);
        String plan = HtzTables.qname(o, HtzTables.GV_SQL_PLAN);
        String stats = HtzTables.qname(o, HtzTables.GV_SQLSTATS);
        String sqlTbl = HtzTables.qname(o, HtzTables.GV_SQL);
        String s = sql;
        s = replaceIgnoreCaseToken(s, "gv$sql_plan", plan);
        s = replaceIgnoreCaseToken(s, "v$sql_plan", plan);
        s = replaceIgnoreCaseToken(s, "gv$sqlarea", stats);
        s = replaceIgnoreCaseToken(s, "v$sqlarea", stats);
        s = replaceIgnoreCaseToken(s, "gv$sqlstats", stats);
        s = replaceIgnoreCaseToken(s, "v$sqlstats", stats);
        s = replaceIgnoreCaseToken(s, "gv$sql", sqlTbl);
        s = replaceIgnoreCaseToken(s, "v$sql", sqlTbl);
        return s;
    }

    /** PROMPT 展示: 标明 PLAN 来自 HTZ. */
    static String rewritePromptForHtzDisplay(String prompt) {
        if (prompt == null || prompt.isEmpty()) {
            return prompt == null ? "" : prompt;
        }
        String s = prompt;
        s = replaceIgnoreCaseToken(s, "v$sql_plan", "HTZ_GV_SQL_PLAN");
        s = replaceIgnoreCaseToken(s, "gv$sql_plan", "HTZ_GV_SQL_PLAN");
        s = replaceIgnoreCaseToken(s, "v$sqlarea", "HTZ_GV_SQLSTATS");
        s = replaceIgnoreCaseToken(s, "gv$sqlarea", "HTZ_GV_SQLSTATS");
        return s;
    }

    /**
     * 大小写不敏感整词替换; 词边界: 左右非 [A-Za-z0-9_$#].
     */
    static String replaceIgnoreCaseToken(String hay, String needle, String replacement) {
        if (hay == null || needle == null || needle.isEmpty() || replacement == null) {
            return hay;
        }
        StringBuilder out = new StringBuilder(hay.length() + 16);
        int i = 0;
        while (i < hay.length()) {
            int idx = indexOfIgnoreCase(hay.substring(i), needle);
            if (idx < 0) {
                out.append(hay.substring(i));
                break;
            }
            int abs = i + idx;
            boolean leftOk = abs == 0 || !isIdentChar(hay.charAt(abs - 1));
            int end = abs + needle.length();
            boolean rightOk = end >= hay.length() || !isIdentChar(hay.charAt(end));
            if (leftOk && rightOk) {
                out.append(hay, i, abs);
                out.append(replacement);
                i = end;
            } else {
                out.append(hay, i, abs + 1);
                i = abs + 1;
            }
        }
        return out.toString();
    }

    private static boolean isIdentChar(char c) {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                || (c >= '0' && c <= '9') || c == '_' || c == '$' || c == '#';
    }

    /**
     * 仅用于 PROMPT 展示文案; 不再用于可执行 SQL.
     */
    static String substituteSqlIdForDisplay(String template, String sqlId) {
        String safe = sqlId == null ? "" : sqlId;
        String s = template == null ? "" : template;
        s = s.replace("&&sqlid", safe);
        s = s.replace("&sqlid", safe);
        return s;
    }

    /** @deprecated 使用 {@link #rewriteSqlIdToBinds(String)} */
    static String substituteSqlId(String template, String sqlId) {
        return substituteSqlIdForDisplay(template, sqlId);
    }

    /** 改写结果: SQL 文本 + 需要 setString 的 ? 个数 (均为 sql_id). */
    static final class Rewrite {
        final String sql;
        final int bindCount;

        Rewrite(String sql, int bindCount) {
            this.sql = sql == null ? "" : sql;
            this.bindCount = bindCount < 0 ? 0 : bindCount;
        }
    }

    /**
     * 将模板中的 sql_id 占位改为 JDBC ?.
     * 顺序: 先处理带引号的 '&&sqlid'/'&sqlid', 再处理残留 &&sqlid/&sqlid
     * (如字符串内 sql_id=&&sqlid → 拼成 ...|| ? || ...).
     */
    static Rewrite rewriteSqlIdToBinds(String sql) {
        if (sql == null || sql.isEmpty()) {
            return new Rewrite("", 0);
        }
        int binds = 0;
        String s = sql;
        String[] quoted = new String[] {"'&&sqlid'", "'&sqlid'"};
        for (int t = 0; t < quoted.length; t++) {
            String token = quoted[t];
            int idx;
            while ((idx = indexOfIgnoreCase(s, token)) >= 0) {
                s = s.substring(0, idx) + "?" + s.substring(idx + token.length());
                binds++;
            }
        }
        // 残留: 字符串内嵌入的 &&sqlid / &sqlid (须先 && 再 &)
        String[] bare = new String[] {"&&sqlid", "&sqlid"};
        for (int t = 0; t < bare.length; t++) {
            String token = bare[t];
            int idx;
            while ((idx = indexOfIgnoreCase(s, token)) >= 0) {
                s = s.substring(0, idx) + "' || ? || '" + s.substring(idx + token.length());
                binds++;
            }
        }
        return new Rewrite(s, binds);
    }

    /** 大小写不敏感查找 (占位符本身为小写 sqlid, 兼容 SQLID). */
    static int indexOfIgnoreCase(String hay, String needle) {
        if (hay == null || needle == null || needle.isEmpty()) {
            return -1;
        }
        final int nlen = needle.length();
        final int max = hay.length() - nlen;
        outer:
        for (int i = 0; i <= max; i++) {
            for (int j = 0; j < nlen; j++) {
                char a = hay.charAt(i + j);
                char b = needle.charAt(j);
                if (a != b && Character.toUpperCase(a) != Character.toUpperCase(b)) {
                    continue outer;
                }
            }
            return i;
        }
        return -1;
    }

    static String loadTemplate() {
        return ReportSelectScript.content();
    }

    private static int remainingQueryTimeoutSec(long deadlineMs, int overallTimeoutSec) {
        if (overallTimeoutSec <= 0) {
            return 0;
        }
        long leftMs = deadlineMs - System.currentTimeMillis();
        if (leftMs <= 0) {
            return 1;
        }
        int leftSec = (int) ((leftMs + 999L) / 1000L);
        return Math.max(1, leftSec);
    }

    private static boolean isTimeoutError(SQLException e) {
        String m = e.getMessage();
        if (m == null) {
            return false;
        }
        String lower = m.toLowerCase(java.util.Locale.ROOT);
        return lower.contains("timeout") || lower.contains("timed out") || lower.contains("cancel");
    }

    enum Kind { PROMPT, PLSQL, SQL, SKIP }

    static class Segment {
        final Kind kind;
        final String text;

        Segment(Kind kind, String text) {
            this.kind = kind;
            this.text = text;
        }
    }

    static List<Segment> parse(String script) {
        List<Segment> out = new ArrayList<Segment>();
        String[] lines = script.split("\n", -1);
        int i = 0;
        while (i < lines.length) {
            String raw = lines[i];
            String s = raw.trim();
            String su = s.toUpperCase(java.util.Locale.ROOT);
            if (s.isEmpty() || s.startsWith("--")) {
                i++;
                continue;
            }
            if (su.startsWith("SET ") || su.startsWith("COL ") || su.startsWith("COLUMN ")
                    || su.startsWith("DEFINE ") || su.startsWith("UNDEFINE ")
                    || su.startsWith("WHENEVER ")) {
                out.add(new Segment(Kind.SKIP, s));
                i++;
                continue;
            }
            if (su.startsWith("PROMPT") || su.equals("PRO") || su.startsWith("PRO ")) {
                String text;
                if (su.equals("PROMPT") || su.equals("PRO")) {
                    text = "";
                } else if (su.startsWith("PROMPT") && s.length() > 6 && Character.isWhitespace(s.charAt(6))) {
                    text = s.substring(7);
                } else if (su.startsWith("PRO ") ) {
                    text = s.substring(4);
                } else {
                    text = s.substring(6).trim();
                }
                out.add(new Segment(Kind.PROMPT, text));
                i++;
                continue;
            }
            if (su.startsWith("DECLARE") || su.startsWith("BEGIN")) {
                StringBuilder body = new StringBuilder();
                while (i < lines.length) {
                    String ln = lines[i];
                    if (ln.trim().equals("/")) {
                        i++;
                        break;
                    }
                    body.append(ln).append('\n');
                    i++;
                }
                out.add(new Segment(Kind.PLSQL, body.toString().trim()));
                continue;
            }
            if (su.startsWith("SELECT") || su.startsWith("WITH")) {
                StringBuilder body = new StringBuilder();
                while (i < lines.length) {
                    String ln = lines[i];
                    String t = ln.trim();
                    if (t.equals("/")) {
                        i++;
                        break;
                    }
                    body.append(ln).append('\n');
                    if (t.endsWith(";") && !t.startsWith("--")) {
                        i++;
                        break;
                    }
                    i++;
                }
                String sql = body.toString().trim();
                if (sql.endsWith(";")) {
                    sql = sql.substring(0, sql.length() - 1).trim();
                }
                out.add(new Segment(Kind.SQL, sql));
                continue;
            }
            // 未知行跳过
            if (loggableUnknown(s)) {
                out.add(new Segment(Kind.SKIP, s));
            }
            i++;
        }
        return out;
    }

    private static boolean loggableUnknown(String s) {
        return false;
    }

    /**
     * 追加 PLAN 起的 PROMPT+SELECT ({@link ReportSelectScript}).
     * AWR 失败写 [ERROR] AWR 并继续; 跳过 PLSQL.
     * 可执行 SQL 使用 ? 绑定 sql_id, 不把字面量嵌进 SQL 文本.
     */
    public void appendFromPlan(JdbcSession session, String sqlId, StringBuilder out,
            long deadlineMs, int timeoutSec) throws SQLException, IOException {
        appendFromPlan(session, sqlId, out, deadlineMs, timeoutSec, false, null);
    }

    /**
     * @param htzSections true 时 PLAN/sqlarea/v$sql 改写为 HTZ_GV_*; AWR/对象字典仍走系统视图名
     * @param htzOwner    HTZ 表所属登录用户; htzSections 时必填
     */
    public void appendFromPlan(JdbcSession session, String sqlId, StringBuilder out,
            long deadlineMs, int timeoutSec, boolean htzSections, String htzOwner)
            throws SQLException, IOException {
        String template = loadTemplate();
        if (template == null || template.isEmpty()) {
            out.append("[ERROR] ReportSelectScript missing; SELECT sections skipped\n");
            if (log != null) {
                log.logWarn("SELECT sections skipped: ReportSelectScript empty");
            }
            return;
        }
        // 保留模板中的 &&sqlid, 解析后再按段绑定; 避免整脚本字面量替换
        List<Segment> segs = parse(template);
        int start = -1;
        for (int i = 0; i < segs.size(); i++) {
            Segment seg = segs.get(i);
            if (seg.kind == Kind.PROMPT && seg.text != null
                    && seg.text.toUpperCase(java.util.Locale.ROOT).contains("PLAN FROM V$SQL_PLAN")) {
                start = i;
                break;
            }
        }
        if (start < 0) {
            out.append("[ERROR] PLAN section marker not found in ReportSelectScript\n");
            return;
        }
        Connection c = session.getConnection();
        boolean nextSqlIsAwr = false;
        for (int i = start; i < segs.size(); i++) {
            if (System.currentTimeMillis() > deadlineMs) {
                out.append("[ERROR] report timeout after ").append(timeoutSec).append("s\n");
                if (log != null) {
                    log.logWarn("report timeout during SELECT sections sql_id=" + sqlId);
                }
                return;
            }
            Segment seg = segs.get(i);
            int stmtTimeout = remainingQueryTimeoutSec(deadlineMs, timeoutSec);
            switch (seg.kind) {
                case PROMPT:
                    if (isAwrPrompt(seg.text)) {
                        nextSqlIsAwr = true;
                    }
                    String promptText = seg.text;
                    if (htzSections) {
                        promptText = rewritePromptForHtzDisplay(promptText);
                    }
                    out.append(substituteSqlIdForDisplay(promptText, sqlId)).append('\n');
                    break;
                case SQL:
                    try {
                        String sqlText = seg.text;
                        if (htzSections && !nextSqlIsAwr) {
                            sqlText = rewriteViewsForHtz(sqlText, htzOwner);
                        }
                        executeQuery(c, sqlText, sqlId, out, stmtTimeout);
                    } catch (SQLException e) {
                        if (nextSqlIsAwr) {
                            // P2: AWR 失败不中断 OBJECT SIZE 等后续段
                            out.append("[ERROR] AWR: ").append(e.getMessage()).append('\n');
                            if (log != null) {
                                log.logDbg("report AWR failed sql_id=" + sqlId + ": " + e.getMessage());
                            }
                            nextSqlIsAwr = false;
                            break;
                        }
                        if (isTimeoutError(e)) {
                            out.append("[ERROR] report timeout after ").append(timeoutSec).append("s\n");
                            if (log != null) {
                                log.logWarn("report timeout sql_id=" + sqlId + ": " + e.getMessage());
                            }
                            return;
                        }
                        out.append("[ERROR] SQL: ").append(e.getMessage()).append('\n');
                        if (log != null) {
                            log.logDbg("report SQL failed: " + e.getMessage());
                        }
                    }
                    nextSqlIsAwr = false;
                    break;
                case PLSQL:
                case SKIP:
                default:
                    break;
            }
        }
    }

    private static boolean isAwrPrompt(String text) {
        if (text == null) {
            return false;
        }
        String u = text.toUpperCase(java.util.Locale.ROOT);
        return u.contains("AWR") || u.contains("WRH$_SQLSTAT");
    }

    /**
     * 执行报告 SELECT: sql_id 经 ? 绑定.
     */
    static void executeQuery(Connection c, String sql, String sqlId, StringBuilder out,
                             int queryTimeoutSec) throws SQLException {
        Rewrite rw = rewriteSqlIdToBinds(sql);
        if (rw.bindCount <= 0) {
            // 模板段应至少含一处 sql_id; 无占位则仍用 PreparedStatement 防误用 Statement
            try (PreparedStatement ps = c.prepareStatement(rw.sql)) {
                if (queryTimeoutSec > 0) {
                    ps.setQueryTimeout(queryTimeoutSec);
                }
                consumeResult(ps.executeQuery(), out);
            }
            return;
        }
        try (PreparedStatement ps = c.prepareStatement(rw.sql)) {
            if (queryTimeoutSec > 0) {
                ps.setQueryTimeout(queryTimeoutSec);
            }
            String id = sqlId == null ? "" : sqlId;
            for (int i = 1; i <= rw.bindCount; i++) {
                ps.setString(i, id);
            }
            consumeResult(ps.executeQuery(), out);
        }
    }

    /** 兼容旧签名: 无 sqlId 时不做绑定改写 (仅测试/遗留). */
    static void executeQuery(Connection c, String sql, StringBuilder out, int queryTimeoutSec)
            throws SQLException {
        executeQuery(c, sql, null, out, queryTimeoutSec);
    }

    private static void consumeResult(ResultSet rs, StringBuilder out) throws SQLException {
        try {
            ResultSetMetaData md = rs.getMetaData();
            int cols = md.getColumnCount();
            if (cols == 1) {
                while (rs.next()) {
                    String v = rs.getString(1);
                    out.append(v == null ? "" : v).append('\n');
                }
                return;
            }
            int[] widths = new int[cols];
            String[] headers = new String[cols];
            for (int i = 1; i <= cols; i++) {
                headers[i - 1] = md.getColumnLabel(i);
                widths[i - 1] = Math.max(headers[i - 1].length(), 1);
            }
            List<String[]> rows = new ArrayList<String[]>();
            while (rs.next()) {
                String[] row = new String[cols];
                for (int i = 1; i <= cols; i++) {
                    String v = rs.getString(i);
                    if (v == null) {
                        v = "";
                    }
                    v = v.replace('\n', ' ').replace('\r', ' ');
                    row[i - 1] = v;
                    if (v.length() > widths[i - 1]) {
                        widths[i - 1] = Math.min(v.length(), 80);
                    }
                }
                rows.add(row);
            }
            for (int i = 0; i < cols; i++) {
                out.append(pad(headers[i], widths[i]));
                if (i < cols - 1) {
                    out.append(' ');
                }
            }
            out.append('\n');
            for (int i = 0; i < cols; i++) {
                out.append(repeat('-', widths[i]));
                if (i < cols - 1) {
                    out.append(' ');
                }
            }
            out.append('\n');
            for (String[] row : rows) {
                for (int i = 0; i < cols; i++) {
                    String v = row[i];
                    if (v.length() > widths[i]) {
                        v = v.substring(0, widths[i]);
                    }
                    out.append(pad(v, widths[i]));
                    if (i < cols - 1) {
                        out.append(' ');
                    }
                }
                out.append('\n');
            }
        } finally {
            rs.close();
        }
    }

    private static String pad(String s, int w) {
        if (s.length() >= w) {
            return s;
        }
        StringBuilder sb = new StringBuilder(s);
        while (sb.length() < w) {
            sb.append(' ');
        }
        return sb.toString();
    }

    private static String repeat(char c, int n) {
        StringBuilder sb = new StringBuilder(n);
        for (int i = 0; i < n; i++) {
            sb.append(c);
        }
        return sb.toString();
    }
}
