package com.yashan.yjdbc.cmd.sqlmap.support.replay;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Timestamp;
import java.sql.Types;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 共享 SQL 分类 / 绑定 / 执行 (供 ReplayEngine 与 sqlmap 复用).
 */
public final class SqlExecutor {

    public static final class ExecResult {
        public boolean ok;
        public String kind = "";
        public long elapsedMs;
        public int updateCount = -1;
        public int rowsShown;
        /** 完整结果行 (captureAll=true 时); 每行各列为 trim 后字符串, NULL=\N */
        public final List<String[]> allRows = new ArrayList<String[]>();
        public String error = "";
        public boolean blocked;
    }

    public interface LineOut {
        void println(String line);
    }

    private SqlExecutor() {
    }

    public static String classifySql(String sql) {
        String s = stripSqlLead(sql);
        if (s.isEmpty()) {
            return "empty";
        }
        String u = s.toUpperCase(Locale.ROOT);
        if (u.startsWith("WITH")) {
            Matcher m = Pattern.compile("\\b(INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE)\\b")
                    .matcher(u);
            if (m.find()) {
                String k = m.group(1);
                if ("CREATE".equals(k) || "ALTER".equals(k) || "DROP".equals(k) || "TRUNCATE".equals(k)) {
                    return "ddl";
                }
                return "dml";
            }
            return "query";
        }
        if (u.startsWith("SELECT") || u.startsWith("EXPLAIN")) {
            return "query";
        }
        if (u.startsWith("INSERT") || u.startsWith("UPDATE") || u.startsWith("DELETE") || u.startsWith("MERGE")) {
            return "dml";
        }
        if (u.startsWith("CREATE") || u.startsWith("ALTER") || u.startsWith("DROP") || u.startsWith("TRUNCATE")
                || u.startsWith("GRANT") || u.startsWith("REVOKE") || u.startsWith("COMMENT")
                || u.startsWith("ANALYZE") || u.startsWith("FLASHBACK") || u.startsWith("PURGE")
                || u.startsWith("RENAME")) {
            return "ddl";
        }
        if (u.startsWith("BEGIN") || u.startsWith("DECLARE") || u.startsWith("CALL") || u.startsWith("EXEC")) {
            return "plsql";
        }
        return "other";
    }

    /** 引号感知剥离行注释; 供 classifySql 使用 (不影响实际执行文本) */
    public static String stripSqlLead(String sql) {
        if (sql == null) {
            return "";
        }
        String s = sql.replaceAll("/\\*[\\s\\S]*?\\*/", " ");
        StringBuilder sb = new StringBuilder();
        for (String ln : s.split("\n", -1)) {
            sb.append(stripLineComment(ln)).append('\n');
        }
        s = sb.toString().trim();
        while (s.startsWith("(")) {
            s = s.substring(1).trim();
        }
        return s;
    }

    private static String stripLineComment(String ln) {
        boolean inStr = false;
        for (int i = 0; i < ln.length(); i++) {
            char c = ln.charAt(i);
            if (inStr) {
                if (c == '\'') {
                    if (i + 1 < ln.length() && ln.charAt(i + 1) == '\'') {
                        i++;
                    } else {
                        inStr = false;
                    }
                }
                continue;
            }
            if (c == '\'') {
                inStr = true;
                continue;
            }
            if (c == '-' && i + 1 < ln.length() && ln.charAt(i + 1) == '-') {
                return ln.substring(0, i);
            }
        }
        return ln;
    }

    /**
     * @param binds 每项 [position, datatype, value]
     * @param dry   dry-run 不执行
     * @param force 允许非 query
     * @param captureAll 收集全部结果行 (verify); false 时最多展示 20 行到 out
     * @param maxPreviewRows dry/非 capture 时预览行数
     */
    public static ExecResult execute(Connection c, String schema, String sql, List<String[]> binds,
                                     boolean dry, boolean force, String loginUser,
                                     int queryTimeoutSec, boolean captureAll, int maxPreviewRows,
                                     LineOut out) {
        ExecResult r = new ExecResult();
        long t0 = System.currentTimeMillis();
        r.kind = classifySql(sql);
        if (out != null) {
            out.println("exec sql-chars=" + (sql == null ? 0 : sql.length()));
            out.println("exec binds=" + (binds == null ? 0 : binds.size()));
            out.println("exec schema=" + (schema == null ? "" : schema));
            out.println("exec sql-kind=" + r.kind);
        }
        if (!force && !"query".equals(r.kind)) {
            r.blocked = true;
            if (out != null) {
                out.println("exec blocked kind=" + r.kind + " (query-only; pass --force to allow)");
            }
            if (dry) {
                r.ok = true;
                r.elapsedMs = System.currentTimeMillis() - t0;
                if (out != null) {
                    out.println("exec dry-run-ok");
                }
                return r;
            }
            r.ok = false;
            r.error = "blocked";
            r.elapsedMs = System.currentTimeMillis() - t0;
            if (out != null) {
                out.println("exec fail blocked non-query without --force");
            }
            return r;
        }
        if (dry) {
            r.ok = true;
            r.elapsedMs = System.currentTimeMillis() - t0;
            if (out != null) {
                out.println("exec dry-run-ok");
            }
            return r;
        }
        if (c == null) {
            r.ok = false;
            r.error = "no_connection";
            r.elapsedMs = System.currentTimeMillis() - t0;
            return r;
        }
        try {
            if (schema != null && !schema.isEmpty() && !"NULL".equalsIgnoreCase(schema)) {
                String login = loginUser;
                if ((login == null || login.isEmpty())) {
                    try {
                        login = c.getMetaData().getUserName();
                    } catch (Exception ignored) {
                    }
                }
                if (login != null && login.equalsIgnoreCase(schema)) {
                    if (out != null) {
                        out.println("exec schema-skip same_as_login=" + schema);
                    }
                } else {
                    try (Statement st = c.createStatement()) {
                        applyTimeout(st, queryTimeoutSec);
                        String q = schema.replace("\"", "\"\"");
                        st.execute("ALTER SESSION SET CURRENT_SCHEMA = \"" + q + "\"");
                        if (out != null) {
                            out.println("exec schema-set=" + schema);
                        }
                    } catch (Exception e) {
                        r.ok = false;
                        r.error = "set_schema";
                        r.elapsedMs = System.currentTimeMillis() - t0;
                        if (out != null) {
                            out.println("exec warn set_schema " + e.getMessage());
                            out.println("exec fail set_schema failed for " + schema);
                        }
                        return r;
                    }
                }
            }
            try (PreparedStatement ps = c.prepareStatement(sql)) {
                applyTimeout(ps, queryTimeoutSec);
                if (binds != null) {
                    for (String[] b : binds) {
                        if (b == null || b.length < 3) {
                            continue;
                        }
                        int pos;
                        try {
                            pos = Integer.parseInt(b[0].trim());
                        } catch (NumberFormatException e) {
                            if (out != null) {
                                out.println("exec warn skip bad bind position: " + b[0]);
                            }
                            continue;
                        }
                        bindOne(ps, pos, b[1], b[2]);
                    }
                }
                boolean hasRs = ps.execute();
                if (hasRs) {
                    try (ResultSet rs = ps.getResultSet()) {
                        int cols = rs.getMetaData().getColumnCount();
                        int rows = 0;
                        while (rs.next()) {
                            String[] row = new String[cols];
                            for (int i = 1; i <= cols; i++) {
                                try {
                                    String v = rs.getString(i);
                                    if (rs.wasNull() || v == null) {
                                        row[i - 1] = "\\N";
                                    } else {
                                        row[i - 1] = v.trim();
                                    }
                                } catch (SQLException lob) {
                                    r.ok = false;
                                    r.error = "unsupported_column_type";
                                    r.elapsedMs = System.currentTimeMillis() - t0;
                                    if (out != null) {
                                        out.println("exec fail unsupported column type: " + lob.getMessage());
                                    }
                                    return r;
                                }
                            }
                            if (captureAll) {
                                r.allRows.add(row);
                            }
                            if (!captureAll && rows < maxPreviewRows && out != null) {
                                StringBuilder sb = new StringBuilder();
                                for (int i = 0; i < cols; i++) {
                                    if (i > 0) {
                                        sb.append("|");
                                    }
                                    sb.append(row[i]);
                                }
                                out.println("exec row " + sb.toString());
                            }
                            rows++;
                        }
                        r.rowsShown = rows;
                        if (out != null) {
                            out.println("exec rows-shown=" + rows);
                        }
                    }
                } else {
                    r.updateCount = ps.getUpdateCount();
                    if (out != null) {
                        out.println("exec update-count=" + r.updateCount);
                    }
                }
                r.ok = true;
                if (out != null) {
                    out.println("exec exec-ok");
                }
            }
        } catch (Exception e) {
            r.ok = false;
            r.error = e.getClass().getSimpleName();
            if (out != null) {
                out.println("exec fail " + e.getMessage());
            }
        }
        r.elapsedMs = System.currentTimeMillis() - t0;
        return r;
    }

    static void applyTimeout(Statement st, int queryTimeoutSec) throws SQLException {
        if (queryTimeoutSec > 0 && st != null) {
            st.setQueryTimeout(queryTimeoutSec);
        }
    }

    public static void bindOne(PreparedStatement ps, int idx, String dt, String val) throws SQLException {
        String u = dt == null ? "" : dt.toUpperCase(Locale.ROOT);
        if (val == null || val.isEmpty() || val.equals("\\N") || "NULL".equalsIgnoreCase(val)) {
            ps.setNull(idx, nullSqlType(dt));
            return;
        }
        if (u.contains("NUMBER") || u.contains("DECIMAL") || u.contains("INT")
                || u.contains("FLOAT") || u.contains("DOUBLE") || u.contains("BINARY_")) {
            try {
                ps.setBigDecimal(idx, new BigDecimal(val.trim()));
                return;
            } catch (Exception e) {
                ps.setString(idx, val);
                return;
            }
        }
        if (u.contains("DATE") || u.contains("TIMESTAMP") || u.contains("TIME")) {
            String t = val.trim();
            String[] patterns = new String[] {
                "yyyy-MM-dd'T'HH:mm:ss.SSS",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss.SSS",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd HH:mm",
                "yyyy-MM-dd",
                "yyyy/MM/dd HH:mm:ss",
                "yyyy/MM/dd",
                "dd-MMM-yy",
                "dd-MMM-yyyy"
            };
            for (String pattern : patterns) {
                try {
                    java.text.SimpleDateFormat sdf = new java.text.SimpleDateFormat(pattern, Locale.US);
                    sdf.setLenient(false);
                    java.util.Date d = sdf.parse(t);
                    if (u.contains("DATE") && !u.contains("TIMESTAMP") && "yyyy-MM-dd".equals(pattern)) {
                        ps.setDate(idx, new java.sql.Date(d.getTime()));
                    } else {
                        ps.setTimestamp(idx, new Timestamp(d.getTime()));
                    }
                    return;
                } catch (Exception ignored) {
                }
            }
            throw new SQLException("unparsed date/timestamp bind value: " + val);
        }
        ps.setString(idx, val);
    }

    private static int nullSqlType(String dt) {
        String u = dt == null ? "" : dt.toUpperCase(Locale.ROOT);
        if (u.contains("NUMBER") || u.contains("DECIMAL") || u.contains("INT")
                || u.contains("FLOAT") || u.contains("DOUBLE") || u.contains("BINARY_")) {
            return Types.NUMERIC;
        }
        if (u.contains("TIMESTAMP") || u.contains("TIME")) {
            return Types.TIMESTAMP;
        }
        if (u.contains("DATE")) {
            return Types.DATE;
        }
        return Types.VARCHAR;
    }

    /** 统计 SQL 中绑定占位符个数 (?, :1, :name, :\"SYS_B_0\") 近似 */
    public static int countPlaceholders(String sql) {
        if (sql == null || sql.isEmpty()) {
            return 0;
        }
        int n = 0;
        boolean inStr = false;
        for (int i = 0; i < sql.length(); i++) {
            char c = sql.charAt(i);
            if (inStr) {
                if (c == '\'') {
                    if (i + 1 < sql.length() && sql.charAt(i + 1) == '\'') {
                        i++;
                    } else {
                        inStr = false;
                    }
                }
                continue;
            }
            if (c == '\'') {
                inStr = true;
                continue;
            }
            if (c == '?') {
                n++;
                continue;
            }
            if (c == ':' && i + 1 < sql.length()) {
                char n1 = sql.charAt(i + 1);
                if (Character.isLetterOrDigit(n1) || n1 == '"' || n1 == '_') {
                    n++;
                    i++;
                    while (i + 1 < sql.length()) {
                        char x = sql.charAt(i + 1);
                        if (Character.isLetterOrDigit(x) || x == '_' || x == '"') {
                            i++;
                        } else {
                            break;
                        }
                    }
                }
            }
        }
        return n;
    }
}
