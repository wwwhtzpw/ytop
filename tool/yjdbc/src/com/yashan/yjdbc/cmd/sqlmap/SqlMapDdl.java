package com.yashan.yjdbc.cmd.sqlmap;

import com.yashan.yjdbc.cmd.sqlmap.support.config.JdbcConfig;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcPool;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcSession;
import com.yashan.yjdbc.cmd.sqlmap.support.db.SqlLookup;
import com.yashan.yjdbc.cmd.sqlmap.support.log.DualLogger;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.sql.Clob;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.concurrent.ThreadLocalRandom;

/**
 * CREATE SQLMAP: JDBC 直接执行 CREATE SQLMAP DDL (不经 DBMS_SQL / 不 UPDATE 基表).
 */
public final class SqlMapDdl {

    public static final int MAX_BYTES = 16 * 1024 * 1024;

    private SqlMapDdl() {
    }

    public static int create(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                Connection c = sess.getConnection();
                Resolved src = resolveSide(c, a, true, log);
                if (src.error != null) {
                    log.logError(src.error);
                    return 1;
                }
                Resolved tgt = resolveSide(c, a, false, log);
                if (tgt.error != null) {
                    log.logError(tgt.error);
                    return 1;
                }
                byte[] srcBytes = src.text.getBytes(StandardCharsets.UTF_8);
                byte[] tgtBytes = tgt.text.getBytes(StandardCharsets.UTF_8);
                if (srcBytes.length > MAX_BYTES || tgtBytes.length > MAX_BYTES) {
                    log.logError("sql text exceeds tool limit (16MiB)");
                    return 1;
                }

                boolean nameFromUser = a.opt("map-name", null) != null
                        && !a.opt("map-name", "").trim().isEmpty();
                String mapName = nameFromUser
                        ? a.opt("map-name", "").trim()
                        : defaultMapName(src);
                if (!nameFromUser) {
                    mapName = ensureUniqueMapName(c, mapName, log);
                }
                String mapUser = a.opt("map-user", "ALL").trim().toUpperCase(Locale.ROOT);
                if (mapUser.isEmpty()) {
                    mapUser = "ALL";
                }

                log.logInfo("create map=" + mapName + " user=" + mapUser
                        + " src_bytes=" + srcBytes.length + " tgt_bytes=" + tgtBytes.length
                        + " dry=" + a.flag("dry-run"));

                if (a.flag("dry-run")) {
                    System.out.println("[dry-run] CREATE SQLMAP " + mapName
                            + " (" + mapUser + ", <src " + srcBytes.length + "B>, <tgt "
                            + tgtBytes.length + "B>) via=CREATE_SQLMAP");
                    System.out.println("[dry-run] would DROP same-name + conflicting source-text maps");
                    writeOut(a, mapName, src, tgt, "dry-run");
                    return 0;
                }

                // optional plan baseline before DDL
                Long srcPlanBefore = null;
                if ((a.wantVerifyPlan()) && a.resolveExec()) {
                    srcPlanBefore = SqlMapVerify.capturePlanHash(c, src.text, src.sqlId,
                            loadBinds(c, a, src.sqlId, log), log);
                } else if (a.wantVerifyPlan() || a.wantVerifyResult()) {
                    if (!a.resolveExec()) {
                        log.logInfo("[WARN] verify flags set but --exec missing; skip verify after create");
                    }
                }

                enableSqlMap(c, log);

                dropSameNameIfExists(c, mapName, log);
                dropConflicts(c, src.text, src.hashValue, log);

                String via = "CREATE_SQLMAP";
                try {
                    createViaJdbc(c, mapName, mapUser, src.text, tgt.text, log);
                } catch (Exception e1) {
                    String msg1 = e1.getMessage() == null ? "" : e1.getMessage();
                    log.logInfo("[WARN] CREATE SQLMAP failed: " + msg1);
                    if (msg1.contains("04398") || msg1.toLowerCase(Locale.ROOT).contains("duplicate")) {
                        log.logInfo("INFO: duplicate sql — re-scan conflicts and retry CREATE SQLMAP");
                        dropConflicts(c, src.text, src.hashValue, log);
                        try {
                            createViaJdbc(c, mapName, mapUser, src.text, tgt.text, log);
                        } catch (Exception retryEx) {
                            log.logError("CREATE SQLMAP failed after conflict retry: "
                                    + retryEx.getMessage());
                            return 1;
                        }
                    } else {
                        log.logError("CREATE SQLMAP failed: " + msg1);
                        return 1;
                    }
                }

                if (a.flag("flush")) {
                    try (Statement st = c.createStatement()) {
                        st.execute("ALTER SYSTEM FLUSH SHARED_POOL");
                        log.logInfo("FLUSH SHARED_POOL done");
                    } catch (Exception e) {
                        log.logInfo("[WARN] flush failed: " + e.getMessage());
                    }
                } else {
                    log.logInfo("Note: shared pool NOT flushed (use --flush to clear cursors)");
                }

                System.out.println("[OK] SQLMAP created: " + mapName + " (via " + via + ")");
                System.out.println("Rollback: DROP SQLMAP " + mapName + ";");
                writeOut(a, mapName, src, tgt, via);

                if ((a.wantVerifyPlan() || a.wantVerifyResult())
                        && a.resolveExec()) {
                    int vrc = SqlMapVerify.verifyAfterCreate(c, a, mapName, src, tgt, srcPlanBefore, log);
                    if (vrc != 0) {
                        return vrc;
                    }
                }
                return 0;
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("create failed: " + e.getMessage());
            return 1;
        }
    }

    static final class Resolved {
        String text = "";
        String sqlId = "";
        Long hashValue;
        String error;
    }

    static Resolved resolveSide(Connection c, SqlMapArgs a, boolean source, DualLogger log)
            throws Exception {
        Resolved r = new Resolved();
        if (source) {
            String id = a.opt("src-sql-id", null);
            String file = a.opt("src-file", null);
            if (id != null && !id.trim().isEmpty()) {
                r.sqlId = id.trim();
                SqlLookup.SqlTextInfo info = SqlLookup.loadSqlText(c, r.sqlId, SqlMapIo.warn(log));
                if (!info.found) {
                    r.error = "source sql_id not found: " + r.sqlId;
                    return r;
                }
                r.text = info.sqlText;
                r.hashValue = info.hashValue;
                return r;
            }
            r.text = SqlMapIo.readFile(file);
            return r;
        }
        String id = a.opt("tgt-sql-id", null);
        String file = a.opt("sql-file", null);
        if (id != null && !id.trim().isEmpty()) {
            r.sqlId = id.trim();
            SqlLookup.SqlTextInfo info = SqlLookup.loadSqlText(c, r.sqlId, SqlMapIo.warn(log));
            if (!info.found) {
                r.error = "target sql_id not found: " + r.sqlId;
                return r;
            }
            r.text = info.sqlText;
            r.hashValue = info.hashValue;
            return r;
        }
        r.text = SqlMapIo.readFile(file);
        return r;
    }

    private static void enableSqlMap(Connection c, DualLogger log) {
        try (Statement st = c.createStatement()) {
            st.execute("ALTER SYSTEM SET sql_map = TRUE");
            log.logInfo("sql_map=TRUE");
        } catch (Exception e) {
            log.logInfo("[WARN] ALTER SYSTEM SET sql_map=TRUE failed: " + e.getMessage());
        }
    }

    /** 自动命名: 毫秒时间戳 + 随机后缀, 降低同秒碰撞; 文件模式带源 SQL 短哈希. */
    static String defaultMapName(Resolved src) {
        String ts = new SimpleDateFormat("yyyyMMddHHmmssSSS", Locale.ROOT).format(new Date());
        String rnd = String.format(Locale.ROOT, "%04x", ThreadLocalRandom.current().nextInt(0x10000));
        if (src.sqlId != null && !src.sqlId.trim().isEmpty()) {
            return truncateIdent("map_" + sanitizeIdent(src.sqlId.trim()) + "_" + ts + "_" + rnd);
        }
        String h = shortSha256Hex(src.text, 8);
        return truncateIdent("map_f_" + h + "_" + ts + "_" + rnd);
    }

    /** 自动名若已在 SQL_MAP$ 中存在则追加随机段, 最多重试若干次. */
    private static String ensureUniqueMapName(Connection c, String base, DualLogger log) {
        String candidate = base;
        for (int i = 0; i < 16; i++) {
            try {
                if (!sqlMapExists(c, candidate)) {
                    return candidate;
                }
            } catch (Exception e) {
                log.logInfo("[WARN] map-name exists check failed: " + e.getMessage()
                        + "; use generated name as-is");
                return candidate;
            }
            String rnd = String.format(Locale.ROOT, "%04x", ThreadLocalRandom.current().nextInt(0x10000));
            candidate = truncateIdent(base + "_" + rnd);
        }
        return truncateIdent(base + "_" + Long.toHexString(System.nanoTime()));
    }

    private static boolean sqlMapExists(Connection c, String mapName) throws Exception {
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT COUNT(*) FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(?)")) {
            ps.setString(1, mapName);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() && rs.getInt(1) > 0;
            }
        }
    }

    /** 仅当同名已存在时 DROP, 避免 YAS-02012 刷屏. */
    private static void dropSameNameIfExists(Connection c, String mapName, DualLogger log) {
        try {
            if (!sqlMapExists(c, mapName)) {
                return;
            }
        } catch (Exception e) {
            log.logInfo("[WARN] same-name exists check failed: " + e.getMessage()
                    + "; try DROP anyway");
        }
        try (Statement st = c.createStatement()) {
            st.execute("DROP SQLMAP " + mapName);
            log.logInfo("dropped existing " + mapName);
        } catch (Exception e) {
            log.logInfo("[WARN] drop same-name: " + e.getMessage());
        }
    }

    private static String sanitizeIdent(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
                    || (ch >= '0' && ch <= '9') || ch == '_') {
                sb.append(ch);
            } else {
                sb.append('_');
            }
        }
        String out = sb.toString();
        return out.isEmpty() ? "x" : out;
    }

    private static String shortSha256Hex(String text, int hexLen) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] dig = md.digest((text == null ? "" : text).getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(hexLen);
            for (int i = 0; i < dig.length && sb.length() < hexLen; i++) {
                sb.append(String.format(Locale.ROOT, "%02x", dig[i] & 0xff));
            }
            if (sb.length() > hexLen) {
                return sb.substring(0, hexLen);
            }
            return sb.toString();
        } catch (Exception e) {
            return String.format(Locale.ROOT, "%08x",
                    ThreadLocalRandom.current().nextInt());
        }
    }

    /** 标识符上限截断时保留末尾随机段. */
    private static String truncateIdent(String name) {
        final int max = 64;
        if (name.length() <= max) {
            return name;
        }
        String tail = name.length() >= 5 ? name.substring(name.length() - 5) : name;
        int headLen = max - tail.length();
        if (headLen < 8) {
            return name.substring(0, max);
        }
        return name.substring(0, headLen) + tail;
    }

    private static void dropConflicts(Connection c, String srcText, Long srcHash, DualLogger log)
            throws Exception {
        if (srcText == null || srcText.isEmpty()) {
            return;
        }
        // 去掉仅尾部换行, 与库内可能规范化文本对齐
        String norm = trimTrailingNewlines(srcText);
        boolean scanned = dropConflictsByCompare(c, norm, log);
        if (!scanned && !norm.equals(srcText)) {
            scanned = dropConflictsByCompare(c, srcText, log);
        }
        // hash 回退
        if (!scanned && srcHash != null) {
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT name FROM SYS.SQL_MAP$ WHERE hash_value = ?")) {
                ps.setLong(1, srcHash.longValue());
                dropNamesFromRs(c, ps, log);
            } catch (Exception e) {
                log.logInfo("[WARN] conflict scan (hash): " + e.getMessage());
            }
        }
    }

    private static String trimTrailingNewlines(String s) {
        int end = s.length();
        while (end > 0) {
            char ch = s.charAt(end - 1);
            if (ch == '\n' || ch == '\r') {
                end--;
            } else {
                break;
            }
        }
        return end == s.length() ? s : s.substring(0, end);
    }

    private static boolean dropConflictsByCompare(Connection c, String srcText, DualLogger log) {
        int srcLen = srcText.length();
        // DBMS_LOB.COMPARE (CLOB 对 CLOB); 成功即结束, 不再走 SUBSTR=VARCHAR
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT name FROM SYS.SQL_MAP$ WHERE DBMS_LOB.GETLENGTH(sql_text) = ?"
                        + " AND DBMS_LOB.COMPARE(sql_text, ?) = 0")) {
            ps.setInt(1, srcLen);
            Clob clob = c.createClob();
            try {
                clob.setString(1, srcText);
                ps.setClob(2, clob);
                dropNamesFromRs(c, ps, log);
            } finally {
                try {
                    clob.free();
                } catch (Exception ignored) {
                }
            }
            return true;
        } catch (Exception e) {
            log.logInfo("[WARN] conflict scan (compare): " + e.getMessage());
            return false;
        }
    }

    private static boolean dropNamesFromRs(Connection c, PreparedStatement ps, DualLogger log)
            throws Exception {
        boolean any = false;
        try (ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                any = true;
                String n = rs.getString(1);
                try (Statement st = c.createStatement()) {
                    st.execute("DROP SQLMAP " + n);
                    log.logInfo("Dropped conflicting SQLMAP: " + n);
                    System.out.println("Dropped conflicting SQLMAP: " + n);
                } catch (Exception e) {
                    log.logInfo("[WARN] Drop conflict failed: " + n + " " + e.getMessage());
                }
            }
        }
        return any;
    }

    private static void createViaJdbc(Connection c, String mapName, String mapUser,
                                      String src, String tgt, DualLogger log) throws Exception {
        String ddl = buildCreateDdl(mapName, mapUser, src, tgt);
        try (Statement st = c.createStatement()) {
            st.execute(ddl);
        }
        log.logInfo("CREATE SQLMAP ok map=" + mapName + " ddl_chars=" + ddl.length());
    }

    static String buildCreateDdl(String mapName, String mapUser, String src, String tgt) {
        return "CREATE SQLMAP " + mapName + " (" + mapUser + ", '"
                + src.replace("'", "''") + "', '"
                + tgt.replace("'", "''") + "')";
    }

    private static java.util.List<String[]> loadBinds(Connection c, SqlMapArgs a, String sqlId,
                                                      DualLogger log) throws Exception {
        // 复用 resolveBinds: -b file|backup|view; 无 -b 时若有 sqlId 则 auto
        String saved = a.opt("src-sql-id", null);
        if ((saved == null || saved.isEmpty()) && sqlId != null && !sqlId.isEmpty()) {
            a.options.put("src-sql-id", sqlId);
        }
        try {
            return SqlMapExec.resolveBinds(c, a, log);
        } finally {
            if (saved == null) {
                a.options.remove("src-sql-id");
            } else {
                a.options.put("src-sql-id", saved);
            }
        }
    }

    private static void writeOut(SqlMapArgs a, String mapName, Resolved src, Resolved tgt, String via)
            throws Exception {
        String out = a.opt("out", null);
        if (out == null || out.isEmpty()) {
            return;
        }
        StringBuilder sb = new StringBuilder();
        sb.append("-- sqlmap create summary via=").append(via).append('\n');
        sb.append("-- map_name=").append(mapName).append('\n');
        sb.append("-- src_sql_id=").append(src.sqlId).append('\n');
        sb.append("-- tgt_sql_id=").append(tgt.sqlId).append('\n');
        sb.append("-- src_chars=").append(src.text.length()).append('\n');
        sb.append("-- tgt_chars=").append(tgt.text.length()).append('\n');
        Files.write(Paths.get(out), sb.toString().getBytes(StandardCharsets.UTF_8));
    }
}
