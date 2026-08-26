package com.yashan.yjdbc.cmd.sqlmap;

import com.yashan.yjdbc.cmd.sqlmap.support.collect.LiteralBindRewrite;
import com.yashan.yjdbc.cmd.sqlmap.support.config.JdbcConfig;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcPool;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcSession;
import com.yashan.yjdbc.cmd.sqlmap.support.db.SqlLookup;
import com.yashan.yjdbc.cmd.sqlmap.support.log.DualLogger;
import com.yashan.yjdbc.cmd.sqlmap.support.replay.SqlExecutor;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** --verify plan|plan-eq|result[,unordered] */
public final class SqlMapVerify {

    private SqlMapVerify() {
    }

    public static int verify(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                Connection c = sess.getConnection();
                String srcText;
                String tgtText;
                String srcId = "";
                String tgtId = "";
                String mapName = a.opt("map-name", null);
                if (mapName != null && !mapName.trim().isEmpty()) {
                    MapTexts mt = loadMapTexts(c, mapName.trim(), log);
                    if (mt == null) {
                        return 1;
                    }
                    srcText = mt.src;
                    tgtText = mt.tgt;
                } else {
                    SqlMapDdl.Resolved src = SqlMapDdl.resolveSide(c, a, true, log);
                    if (src.error != null) {
                        log.logError(src.error);
                        return 1;
                    }
                    SqlMapDdl.Resolved tgt = SqlMapDdl.resolveSide(c, a, false, log);
                    if (tgt.error != null) {
                        log.logError(tgt.error);
                        return 1;
                    }
                    srcText = src.text;
                    tgtText = tgt.text;
                    srcId = src.sqlId;
                    tgtId = tgt.sqlId;
                }
                List<String[]> binds = SqlMapExec.resolveBinds(c, a, log);
                if (binds.isEmpty() && srcId != null && !srcId.isEmpty()) {
                    binds = SqlLookup.toReplayRows(
                            SqlLookup.loadBindsBySqlId(c, srcId, SqlMapIo.warn(log)));
                }
                SqlMapExec.AlignPair ap = SqlMapExec.alignForExec(c, a, srcText, binds, log);
                srcText = ap.sql;
                binds = ap.binds;
                tgtText = LiteralBindRewrite.toQuestionMarks(tgtText);
                int ph = SqlExecutor.countPlaceholders(srcText);
                if (ph > 0 && binds.isEmpty()) {
                    log.logError("no binds; run genbind -s <sql_id> or provide -b file|backup|view");
                    return 1;
                }
                return runChecks(c, a, srcText, tgtText, srcId, tgtId, binds,
                        null, cfg, log);
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("verify failed: " + e.getMessage());
            return 1;
        }
    }

    static int verifyAfterCreate(Connection c, SqlMapArgs a, String mapName,
                                 SqlMapDdl.Resolved src, SqlMapDdl.Resolved tgt,
                                 Long srcPlanBefore, DualLogger log) throws Exception {
        List<String[]> binds = SqlMapExec.resolveBinds(c, a, log);
        if (binds.isEmpty() && src.sqlId != null && !src.sqlId.isEmpty()) {
            binds = SqlLookup.toReplayRows(
                    SqlLookup.loadBindsBySqlId(c, src.sqlId, SqlMapIo.warn(log)));
        }
        String srcText = src.text;
        String tgtText = tgt.text;
        SqlMapExec.AlignPair ap = SqlMapExec.alignForExec(c, a, srcText, binds, log);
        srcText = ap.sql;
        binds = ap.binds;
        tgtText = LiteralBindRewrite.toQuestionMarks(tgtText);
        return runChecks(c, a, srcText, tgtText, src.sqlId, tgt.sqlId, binds,
                srcPlanBefore, null, log);
    }

    private static int runChecks(Connection c, SqlMapArgs a, String srcText, String tgtText,
                                 String srcId, String tgtId, List<String[]> binds,
                                 Long srcPlanBefore, JdbcConfig cfg, DualLogger log)
            throws Exception {
        boolean wantPlan = a.wantVerifyPlan();
        boolean wantResult = a.wantVerifyResult();
        boolean strict = a.wantPlanEq();
        boolean unordered = a.wantUnordered();
        String schema = a.opt("current-schema", cfg == null ? null : cfg.currentSchema);
        String loginUser = cfg == null ? null : cfg.user;
        SqlExecutor.LineOut out = new SqlExecutor.LineOut() {
            public void println(String line) {
                log.logInfo(line);
            }
        };

        Long tgtBaseline = null;
        if (wantPlan) {
            if (tgtId != null && !tgtId.isEmpty()) {
                tgtBaseline = lookupPlanHash(c, tgtId, null, log);
            }
            if (srcPlanBefore == null && srcId != null && !srcId.isEmpty()) {
                srcPlanBefore = capturePlanHash(c, srcText, srcId, binds, log);
            }
        }

        if (wantResult || wantPlan) {
            // execute source (mapped path uses same text; after create, source text triggers map)
            SqlExecutor.ExecResult srcR = SqlExecutor.execute(
                    c, schema, srcText, binds, false, true, loginUser, 0, wantResult, 0, out);
            if (!srcR.ok) {
                log.logError("verify source exec failed: " + srcR.error);
                return 1;
            }
            SqlExecutor.ExecResult tgtR = SqlExecutor.execute(
                    c, schema, tgtText, binds, false, true, loginUser, 0, wantResult, 0, out);
            if (!tgtR.ok) {
                log.logError("verify target exec failed: " + tgtR.error);
                return 1;
            }

            if (wantResult) {
                String hs = checksum(srcR.allRows, unordered);
                String ht = checksum(tgtR.allRows, unordered);
                log.logInfo("verify-result src_rows=" + srcR.allRows.size()
                        + " tgt_rows=" + tgtR.allRows.size()
                        + " src_sha=" + hs + " tgt_sha=" + ht);
                if (srcR.allRows.size() != tgtR.allRows.size() || !hs.equals(ht)) {
                    log.logError("verify-result MISMATCH");
                    return 1;
                }
                System.out.println("[OK] verify-result match sha=" + hs);
            }

            if (wantPlan) {
                String marker = a.opt("marker", null);
                Long srcPlanAfter = null;
                SqlMapVerify.SqlStats after = lookupSqlStats(c, srcId, srcText, marker, log);
                if (after != null) {
                    srcPlanAfter = after.planHash;
                }
                Long tgtPlan = tgtBaseline;
                if (tgtPlan == null) {
                    SqlMapVerify.SqlStats ts = lookupSqlStats(c, tgtId, tgtText, marker, log);
                    if (ts != null) {
                        tgtPlan = ts.planHash;
                    }
                }
                log.logInfo("verify-plan src_before=" + srcPlanBefore
                        + " src_after=" + srcPlanAfter + " tgt_baseline=" + tgtPlan
                        + (after != null && after.bufferGets != null
                        ? " src_buffer_gets=" + after.bufferGets : ""));
                if (strict) {
                    if (tgtPlan == null || srcPlanAfter == null || !tgtPlan.equals(srcPlanAfter)) {
                        log.logError("plan-eq failed (src plan_hash != tgt)");
                        return 1;
                    }
                } else {
                    if (tgtPlan != null && srcPlanAfter != null) {
                        if (!tgtPlan.equals(srcPlanAfter)) {
                            log.logError("verify-plan: src_after != tgt_baseline");
                            return 1;
                        }
                    } else if (srcPlanBefore != null && srcPlanAfter != null
                            && srcPlanBefore.equals(srcPlanAfter)) {
                        log.logError("verify-plan: plan_hash unchanged vs source baseline");
                        return 1;
                    } else if (srcPlanAfter == null) {
                        log.logError("verify-plan: could not read plan_hash");
                        return 1;
                    }
                }
                System.out.println("[OK] verify-plan src_after=" + srcPlanAfter
                        + " tgt=" + tgtPlan);
            }
        }
        return 0;
    }

    public static Long capturePlanHash(Connection c, String sql, String sqlId,
                                       List<String[]> binds, DualLogger log) {
        SqlExecutor.LineOut out = new SqlExecutor.LineOut() {
            public void println(String line) {
                log.logInfo(line);
            }
        };
        SqlExecutor.ExecResult r = SqlExecutor.execute(
                c, null, sql, binds, false, true, null, 0, false, 0, out);
        if (!r.ok) {
            log.logInfo("[WARN] capturePlanHash exec failed: " + r.error);
            return null;
        }
        return lookupPlanHash(c, sqlId, sql, log);
    }

    public static final class SqlStats {
        public Long planHash;
        public Long bufferGets;
        public Long executions;
        public String sqlId = "";
    }

    public static Long lookupPlanHash(Connection c, String sqlId, String sqlText, DualLogger log) {
        SqlStats s = lookupSqlStats(c, sqlId, sqlText, null, log);
        return s == null ? null : s.planHash;
    }

    /**
     * 取 plan_hash / buffer_gets / executions.
     * 顺序: sql_id → marker 注释 → sql_text 前缀 LIKE → 短文本精确长度+前缀.
     */
    public static SqlStats lookupSqlStats(Connection c, String sqlId, String sqlText,
                                          String marker, DualLogger log) {
        SqlStats s = null;
        if (sqlId != null && !sqlId.isEmpty()) {
            s = queryStatsById(c, true, sqlId, log);
            if (s != null) {
                return s;
            }
            s = queryStatsById(c, false, sqlId, log);
            if (s != null) {
                return s;
            }
        }
        String mk = marker;
        if ((mk == null || mk.isEmpty()) && sqlText != null) {
            mk = extractMarker(sqlText);
        }
        if (mk != null && !mk.isEmpty()) {
            s = queryStatsByLike(c, true, "%" + escapeLike(mk) + "%", log);
            if (s != null) {
                return s;
            }
            s = queryStatsByLike(c, false, "%" + escapeLike(mk) + "%", log);
            if (s != null) {
                return s;
            }
        }
        if (sqlText != null && !sqlText.isEmpty()) {
            String prefix = sqlText.length() > 80 ? sqlText.substring(0, 80) : sqlText;
            s = queryStatsByLike(c, true, escapeLike(prefix) + "%", log);
            if (s != null) {
                return s;
            }
            s = queryStatsByLike(c, false, escapeLike(prefix) + "%", log);
            if (s != null) {
                return s;
            }
        }
        return null;
    }

    /** 提取 /&#42;...&#42;/ 中首个标记 (用于事后查 v$sql) */
    public static String extractMarker(String sql) {
        if (sql == null) {
            return null;
        }
        int i = sql.indexOf("/*");
        while (i >= 0) {
            int j = sql.indexOf("*/", i + 2);
            if (j < 0) {
                break;
            }
            String inner = sql.substring(i + 2, j).trim();
            if (!inner.isEmpty() && inner.length() <= 200) {
                return inner;
            }
            i = sql.indexOf("/*", j + 2);
        }
        return null;
    }

    private static String escapeLike(String s) {
        if (s == null) {
            return "";
        }
        return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }

    private static SqlStats queryStatsById(Connection c, boolean gv, String sqlId, DualLogger log) {
        String view = gv ? "gv$sql" : "v$sql";
        String sql = "SELECT plan_hash_value, buffer_gets, executions, sql_id FROM ("
                + " SELECT plan_hash_value, buffer_gets, executions, sql_id FROM " + view
                + " WHERE sql_id = ? ORDER BY last_active_time DESC NULLS LAST"
                + ") WHERE ROWNUM = 1";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, sqlId);
            return readStats(ps);
        } catch (Exception e) {
            if (log != null) {
                log.logInfo("[WARN] stats by sql_id (" + view + "): " + e.getMessage());
            }
            return null;
        }
    }

    private static SqlStats queryStatsByLike(Connection c, boolean gv, String likePat, DualLogger log) {
        String view = gv ? "gv$sql" : "v$sql";
        String sql = "SELECT plan_hash_value, buffer_gets, executions, sql_id FROM ("
                + " SELECT plan_hash_value, buffer_gets, executions, sql_id FROM " + view
                + " WHERE sql_text LIKE ? ESCAPE '\\'"
                + " ORDER BY last_active_time DESC NULLS LAST"
                + ") WHERE ROWNUM = 1";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, likePat);
            return readStats(ps);
        } catch (Exception e) {
            // 部分版本无 ESCAPE: 降级无 ESCAPE
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT plan_hash_value, buffer_gets, executions, sql_id FROM ("
                            + " SELECT plan_hash_value, buffer_gets, executions, sql_id FROM " + view
                            + " WHERE sql_text LIKE ?"
                            + " ORDER BY last_active_time DESC NULLS LAST"
                            + ") WHERE ROWNUM = 1")) {
                ps.setString(1, likePat.replace("\\%", "%").replace("\\_", "_").replace("\\\\", "\\"));
                return readStats(ps);
            } catch (Exception e2) {
                if (log != null) {
                    log.logInfo("[WARN] stats by text (" + view + "): " + e2.getMessage());
                }
                return null;
            }
        }
    }

    private static SqlStats readStats(PreparedStatement ps) throws Exception {
        try (ResultSet rs = ps.executeQuery()) {
            if (!rs.next()) {
                return null;
            }
            SqlStats s = new SqlStats();
            long ph = rs.getLong(1);
            if (!rs.wasNull()) {
                s.planHash = Long.valueOf(ph);
            }
            long bg = rs.getLong(2);
            if (!rs.wasNull()) {
                s.bufferGets = Long.valueOf(bg);
            }
            long ex = rs.getLong(3);
            if (!rs.wasNull()) {
                s.executions = Long.valueOf(ex);
            }
            String id = rs.getString(4);
            s.sqlId = id == null ? "" : id;
            return s;
        }
    }

    static String checksum(List<String[]> rows, boolean unordered) {
        List<String> lines = new ArrayList<String>();
        for (String[] row : rows) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < row.length; i++) {
                if (i > 0) {
                    sb.append('\t');
                }
                sb.append(row[i] == null ? "\\N" : row[i]);
            }
            lines.add(sb.toString());
        }
        if (unordered) {
            Collections.sort(lines);
        }
        StringBuilder all = new StringBuilder();
        for (String ln : lines) {
            all.append(ln).append('\n');
        }
        return sha256Hex(all.toString());
    }

    public static String sha256Hex(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] dig = md.digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : dig) {
                sb.append(String.format("%02x", b & 0xff));
            }
            return sb.toString();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static final class MapTexts {
        String src;
        String tgt;
    }

    private static MapTexts loadMapTexts(Connection c, String name, DualLogger log) throws Exception {
        String sql = "SELECT sql_text, sqlmap_text FROM SYS.SQL_MAP$ WHERE UPPER(name) = UPPER(?)";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, name);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    log.logError("sqlmap not found: " + name);
                    return null;
                }
                MapTexts m = new MapTexts();
                m.src = JdbcSession.readClob(rs.getClob(1));
                m.tgt = JdbcSession.readClob(rs.getClob(2));
                return m;
            }
        }
    }
}
