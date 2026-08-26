package com.yashan.yjdbc.cmd.sqlmap;

import com.yashan.yjdbc.cmd.sqlmap.support.config.JdbcConfig;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcPool;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcSession;
import com.yashan.yjdbc.cmd.sqlmap.support.db.SqlLookup;
import com.yashan.yjdbc.cmd.sqlmap.support.log.DualLogger;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.Locale;

/** list / show / drop SYS.SQL_MAP$ */
public final class SqlMapCatalog {

    private SqlMapCatalog() {
    }

    public static int list(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        int limit = 500;
        try {
            Integer lim = Integer.valueOf(a.opt("limit", "500"));
            if (lim.intValue() > 0) {
                limit = lim.intValue();
            }
        } catch (NumberFormatException ignored) {
        }
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                Connection c = sess.getConnection();
                int total = 0;
                try (Statement st = c.createStatement();
                     ResultSet rs = st.executeQuery("SELECT COUNT(*) FROM SYS.SQL_MAP$")) {
                    if (rs.next()) {
                        total = rs.getInt(1);
                    }
                }
                System.out.println("SQL_MAP$ count=" + total + " (showing up to " + limit + ")");
                String sql = "SELECT name, user_name, hash_value,"
                        + " DBMS_LOB.GETLENGTH(sql_text), DBMS_LOB.GETLENGTH(sqlmap_text),"
                        + " DBMS_LOB.SUBSTR(sql_text, 80, 1), DBMS_LOB.SUBSTR(sqlmap_text, 80, 1)"
                        + " FROM SYS.SQL_MAP$ ORDER BY name";
                int n = 0;
                try (Statement st = c.createStatement();
                     ResultSet rs = st.executeQuery(sql)) {
                    while (rs.next() && n < limit) {
                        n++;
                        String name = rs.getString(1);
                        String user = rs.getString(2);
                        long hash = rs.getLong(3);
                        long srcLen = rs.getLong(4);
                        long tgtLen = rs.getLong(5);
                        String srcPrev = asciiSafe(rs.getString(6));
                        String tgtPrev = asciiSafe(rs.getString(7));
                        System.out.println(String.format(Locale.ROOT,
                                "%s | user=%s hash=%d src_len=%d tgt_len=%d",
                                name, user, hash, srcLen, tgtLen));
                        System.out.println("  SRC: " + srcPrev);
                        System.out.println("  TGT: " + tgtPrev);
                    }
                }
                log.logInfo("list shown=" + n + " total=" + total);
                return 0;
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("list failed: " + e.getMessage());
            return 1;
        }
    }

    public static int show(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        String mapName = a.opt("map-name", null);
        String sqlId = a.opt("sql-id", null);
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                Connection c = sess.getConnection();
                if (mapName != null && !mapName.trim().isEmpty()) {
                    return showByName(c, mapName.trim(), log);
                }
                return showBySqlId(c, sqlId.trim(), log);
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("show failed: " + e.getMessage());
            return 1;
        }
    }

    private static int showByName(Connection c, String name, DualLogger log) throws Exception {
        String sql = "SELECT name, user_name, hash_value,"
                + " DBMS_LOB.GETLENGTH(sql_text), DBMS_LOB.GETLENGTH(sqlmap_text),"
                + " sql_text, sqlmap_text"
                + " FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(?)";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, name);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    log.logError("sqlmap not found: " + name);
                    return 1;
                }
                printFull(rs);
                while (rs.next()) {
                    printFull(rs);
                }
            }
        }
        return 0;
    }

    private static int showBySqlId(Connection c, String sqlId, DualLogger log) throws Exception {
        SqlLookup.SqlTextInfo info = SqlLookup.loadSqlText(c, sqlId, SqlMapIo.warn(log));
        int matched = 0;
        if (info.hashValue != null) {
            String sql = "SELECT name, user_name, hash_value,"
                    + " DBMS_LOB.GETLENGTH(sql_text), DBMS_LOB.GETLENGTH(sqlmap_text),"
                    + " sql_text, sqlmap_text"
                    + " FROM SYS.SQL_MAP$ WHERE hash_value = ? ORDER BY name";
            try (PreparedStatement ps = c.prepareStatement(sql)) {
                ps.setLong(1, info.hashValue.longValue());
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        matched++;
                        printFull(rs);
                    }
                }
            }
        }
        if (matched == 0) {
            log.logInfo("[WARN] no SQL_MAP$ by hash; try name prefix map_" + sqlId);
            String sql = "SELECT name, user_name, hash_value,"
                    + " DBMS_LOB.GETLENGTH(sql_text), DBMS_LOB.GETLENGTH(sqlmap_text),"
                    + " sql_text, sqlmap_text"
                    + " FROM SYS.SQL_MAP$ WHERE UPPER(name) LIKE UPPER(?) ORDER BY name";
            try (PreparedStatement ps = c.prepareStatement(sql)) {
                ps.setString(1, "MAP_" + sqlId + "%");
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        matched++;
                        printFull(rs);
                    }
                }
            }
            if (matched == 0) {
                try (PreparedStatement ps = c.prepareStatement(sql)) {
                    ps.setString(1, "map_" + sqlId + "%");
                    try (ResultSet rs = ps.executeQuery()) {
                        while (rs.next()) {
                            matched++;
                            printFull(rs);
                        }
                    }
                }
            }
        }
        if (matched == 0) {
            log.logError("no sqlmap for sql_id: " + sqlId);
            return 1;
        }
        return 0;
    }

    private static void printFull(ResultSet rs) throws Exception {
        String name = rs.getString(1);
        String user = rs.getString(2);
        long hash = rs.getLong(3);
        long srcLen = rs.getLong(4);
        long tgtLen = rs.getLong(5);
        String src = JdbcSession.readClob(rs.getClob(6));
        String tgt = JdbcSession.readClob(rs.getClob(7));
        System.out.println("==== " + name + " ====");
        System.out.println("user=" + user + " hash=" + hash
                + " src_len=" + srcLen + " tgt_len=" + tgtLen);
        System.out.println("-- SRC --");
        System.out.println(asciiSafe(src));
        System.out.println("-- TGT --");
        System.out.println(asciiSafe(tgt));
    }

    public static int drop(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        String name = a.opt("map-name", "").trim();
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                Connection c = sess.getConnection();
                int cnt = 0;
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT COUNT(*) FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(?)")) {
                    ps.setString(1, name);
                    try (ResultSet rs = ps.executeQuery()) {
                        if (rs.next()) {
                            cnt = rs.getInt(1);
                        }
                    }
                }
                if (cnt == 0) {
                    log.logError("sqlmap not found: " + name);
                    return 1;
                }
                try {
                    showByName(c, name, log);
                } catch (Exception e) {
                    log.logInfo("[WARN] preview failed: " + e.getMessage());
                }
                try (Statement st = c.createStatement()) {
                    st.execute("DROP SQLMAP " + name);
                }
                log.logInfo("dropped sqlmap " + name);
                System.out.println("[OK] DROP SQLMAP " + name);
                return 0;
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("drop failed: " + e.getMessage());
            return 1;
        }
    }

    static String asciiSafe(String s) {
        if (s == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch >= 32 && ch < 127) {
                sb.append(ch);
            } else if (ch == '\n' || ch == '\r' || ch == '\t') {
                sb.append(ch);
            } else {
                sb.append('?');
            }
        }
        return sb.toString();
    }
}
