package com.yashan.sqlcollect.db;

import com.yashan.sqlcollect.log.DualLogger;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;

/**
 * HTZ_* 表归属登录用户 schema (非 SYS).
 * 不存在则创建; 任一步失败向上抛出, 由调用方直接退出.
 */
public final class HtzTables {

    public static final String GV_SQL = "HTZ_GV_SQL";
    public static final String GV_SQLSTATS = "HTZ_GV_SQLSTATS";
    public static final String GV_BIND = "HTZ_GV_SQL_BIND_CAPTURE";
    /** 对应 GV$SQL_PLAN; 去重键 (INST_ID, SQL_ID, CHILD_NUMBER, PLAN_HASH_VALUE, ID) */
    public static final String GV_SQL_PLAN = "HTZ_GV_SQL_PLAN";
    /** 本轮 eligible 游标键集 (GTT 或普通表) */
    public static final String ELIG_SQL = "HTZ_ELIG_SQL";
    /** 本轮 STATS MERGE 相关 sql_id 集合 */
    public static final String BACKUP_R = "HTZ_BACKUP_R";

    private HtzTables() {}

    /** 规范化 owner (登录用户名) */
    public static String normalizeOwner(String user) {
        if (user == null || user.trim().isEmpty()) {
            throw new IllegalArgumentException("jdbc user is empty; cannot resolve HTZ table owner");
        }
        return user.trim().toUpperCase(Locale.ROOT);
    }

    /** OWNER.TABLE (未加引号, 依赖库默认大写) */
    public static String qname(String owner, String table) {
        return normalizeOwner(owner) + "." + table.toUpperCase(Locale.ROOT);
    }

    public static boolean tableExists(Connection c, String owner, String table) throws SQLException {
        String o = normalizeOwner(owner);
        String t = table.toUpperCase(Locale.ROOT);
        // 优先 user_tables (当前登录用户); 若查他人再 fallback all_tables
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT COUNT(*) FROM user_tables WHERE table_name = ?")) {
            ps.setString(1, t);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                int n = rs.getInt(1);
                if (n > 0) {
                    String who = currentUser(c);
                    if (who.equalsIgnoreCase(o)) {
                        return true;
                    }
                }
            }
        }
        try (PreparedStatement ps2 = c.prepareStatement(
                "SELECT COUNT(*) FROM all_tables WHERE owner = ? AND table_name = ?")) {
            ps2.setString(1, o);
            ps2.setString(2, t);
            try (ResultSet rs = ps2.executeQuery()) {
                rs.next();
                return rs.getInt(1) > 0;
            }
        }
    }

    public static boolean indexExists(Connection c, String owner, String indexName) throws SQLException {
        String o = normalizeOwner(owner);
        String idx = indexName == null ? "" : indexName.trim().toUpperCase(Locale.ROOT);
        String who = currentUser(c);
        if (who.equalsIgnoreCase(o)) {
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT COUNT(*) FROM user_indexes WHERE index_name = ?")) {
                ps.setString(1, idx);
                try (ResultSet rs = ps.executeQuery()) {
                    rs.next();
                    if (rs.getInt(1) > 0) {
                        return true;
                    }
                }
            }
        }
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT COUNT(*) FROM all_indexes WHERE owner = ? AND index_name = ?")) {
            ps.setString(1, o);
            ps.setString(2, idx);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                return rs.getInt(1) > 0;
            }
        }
    }

    /**
     * 索引不存在则创建. ddl 须为完整 CREATE INDEX ... 语句.
     */
    public static void ensureIndex(Connection c, DualLogger log, String owner, String indexName, String ddl)
            throws SQLException {
        if (indexExists(c, owner, indexName)) {
            if (log != null) {
                log.logDbg("index exists " + qname(owner, indexName));
            }
            return;
        }
        if (log != null) {
            log.logInfo("index creating " + normalizeOwner(owner) + "." + indexName.toUpperCase(Locale.ROOT));
        }
        exec(c, log, "create_index_" + indexName, ddl);
        if (log != null) {
            log.logInfo("index created " + normalizeOwner(owner) + "." + indexName.toUpperCase(Locale.ROOT));
        }
    }

    public static String currentUser(Connection c) throws SQLException {
        try (Statement st = c.createStatement();
             ResultSet rs = st.executeQuery("SELECT USER FROM dual")) {
            rs.next();
            String u = rs.getString(1);
            return u == null ? "" : u.trim().toUpperCase(Locale.ROOT);
        }
    }

    public static void exec(Connection c, DualLogger log, String step, String sql) throws SQLException {
        if (log != null) {
            log.logStep(step, sql.length() > 180 ? sql.substring(0, 180) + "..." : sql);
            log.logDbg("jdbc sql [" + step + "]: " + sql);
        }
        long t0 = System.currentTimeMillis();
        try (Statement st = c.createStatement()) {
            st.execute(sql);
            if (log != null) {
                log.commandResult("jdbc", step, 0, "(ok)", (System.currentTimeMillis() - t0) / 1000.0);
            }
        } catch (SQLException e) {
            if (log != null) {
                log.commandResult("jdbc", step, e.getErrorCode(), e.getMessage(),
                        (System.currentTimeMillis() - t0) / 1000.0);
            }
            throw e;
        }
    }

    public static int execUpdate(Connection c, DualLogger log, String step, String sql) throws SQLException {
        if (log != null) {
            log.logStep(step, sql.length() > 180 ? sql.substring(0, 180) + "..." : sql);
            log.logDbg("jdbc sql [" + step + "]: " + sql);
        }
        long t0 = System.currentTimeMillis();
        try (Statement st = c.createStatement()) {
            int n = st.executeUpdate(sql);
            if (log != null) {
                log.commandResult("jdbc", step, 0, "rows=" + n, (System.currentTimeMillis() - t0) / 1000.0);
            }
            return n;
        } catch (SQLException e) {
            if (log != null) {
                log.commandResult("jdbc", step, e.getErrorCode(), e.getMessage(),
                        (System.currentTimeMillis() - t0) / 1000.0);
            }
            throw e;
        }
    }
}
