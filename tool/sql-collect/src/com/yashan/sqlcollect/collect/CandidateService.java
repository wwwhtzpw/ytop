package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.db.HtzTables;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.log.DualLogger;
import com.yashan.sqlcollect.model.SqlCandidate;
import com.yashan.sqlcollect.util.NoiseFilter;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 从 gv$/v$sql 或 HTZ_GV_SQL 列出候选 sql_id.
 * FILE: gv$/v$sql 池; activeSession 时活跃会话置顶.
 * BOTH|TABLE: HTZ_GV_SQL; 排序=活跃会话(可选) → backupNew → 其余.
 * BACKUP: 调用方不应走本 list 做报告.
 */
public class CandidateService {

    private final DualLogger log;
    private final List<String> excludeSchemas;
    private final List<String> includeSchemas;

    public CandidateService(DualLogger log) {
        this(log, null, null);
    }

    public CandidateService(DualLogger log, List<String> excludeSchemas) {
        this(log, excludeSchemas, null);
    }

    public CandidateService(DualLogger log, List<String> excludeSchemas,
                            List<String> includeSchemas) {
        this.log = log;
        this.excludeSchemas = excludeSchemas == null || excludeSchemas.isEmpty()
                ? NoiseFilter.builtinExcludeSchemas()
                : NoiseFilter.normalizeExcludeSchemas(excludeSchemas);
        this.includeSchemas = includeSchemas == null
                ? new ArrayList<String>()
                : NoiseFilter.normalizeExcludeSchemas(includeSchemas);
    }

    /** 单测: 当前排除名单的 SQL NOT IN 片段. */
    String excludeNotInSql() {
        return NoiseFilter.sqlNotInList(excludeSchemas);
    }

    /** 单测: schema 过滤完整谓词. */
    String schemaFilterSql() {
        return NoiseFilter.sqlSchemaFilter("UPPER(parsing_schema_name)",
                excludeSchemas, includeSchemas);
    }

    /**
     * 按 sink 模式列出候选: FILE 走 gv$/v$sql; BOTH|TABLE 仅 HTZ_GV_SQL.
     * activeSession=true 时扫描 gv$/v$session 置顶; backupNewIds 在 HTZ 模式下次优先.
     */
    public List<SqlCandidate> list(JdbcSession session, SinkMode sink, List<String> backupNewIds) {
        return list(session, sink, backupNewIds, true);
    }

    public List<SqlCandidate> list(JdbcSession session, SinkMode sink, List<String> backupNewIds,
                                   boolean activeSession) {
        if (sink == SinkMode.FILE) {
            return listLive(session, activeSession);
        }
        Connection c = session.getConnection();
        String owner;
        try {
            owner = HtzTables.currentUser(c);
        } catch (SQLException e) {
            log.logWarn("HTZ candidate owner lookup failed: " + e.getMessage());
            owner = "";
        }
        List<SqlCandidate> pool = listFromHtz(c, owner);
        List<String> activeIds = activeSession ? listActiveSqlIds(c) : new ArrayList<String>();
        List<SqlCandidate> ordered = mergePriority(c, owner, pool, activeIds, backupNewIds, true);
        int backupN = backupNewIds == null ? 0 : backupNewIds.size();
        log.logInfo("candidates=" + ordered.size()
                + " active_session=" + activeSession
                + " active_session_sql=" + activeIds.size()
                + " active_first=" + countActiveFirst(ordered, activeIds)
                + " backup_new=" + backupN
                + " backup_first=" + countBackupFirst(ordered, backupNewIds)
                + " source=htz");
        return ordered;
    }

    /** 兼容旧调用: 默认开启活跃会话置顶. */
    public List<SqlCandidate> list(JdbcSession session) {
        return listLive(session, true);
    }

    private List<SqlCandidate> listLive(JdbcSession session, boolean activeSession) {
        Connection c = session.getConnection();
        List<SqlCandidate> fromGv = queryAll(c, true);
        List<SqlCandidate> pool = fromGv;
        if (pool.isEmpty()) {
            log.logWarn("gv$sql list failed or empty; try v$sql");
            pool = queryAll(c, false);
        }
        List<String> activeIds = activeSession ? listActiveSqlIds(c) : new ArrayList<String>();
        List<SqlCandidate> ordered = prioritizeActive(c, pool, activeIds);
        log.logInfo("candidates=" + ordered.size()
                + " active_session=" + activeSession
                + " active_session_sql=" + activeIds.size()
                + " active_first=" + countActiveFirst(ordered, activeIds)
                + " source=live");
        return ordered;
    }

    /**
     * HTZ 候选排序: 活跃会话 → backupNew → 池内其余.
     * lookupHtz=true 时缺失 id 从 HTZ_GV_SQL 补查.
     */
    private List<SqlCandidate> mergePriority(Connection c, String owner, List<SqlCandidate> pool,
                                             List<String> activeIds, List<String> backupNewIds,
                                             boolean lookupHtz) {
        Map<String, SqlCandidate> byId = new LinkedHashMap<String, SqlCandidate>();
        for (SqlCandidate cand : pool) {
            if (cand != null && cand.sqlId != null) {
                byId.put(cand.sqlId, cand);
            }
        }
        List<SqlCandidate> out = new ArrayList<SqlCandidate>();
        Set<String> seen = new LinkedHashSet<String>();
        appendIds(out, seen, byId, activeIds, c, owner, lookupHtz);
        appendIds(out, seen, byId, backupNewIds, c, owner, lookupHtz);
        for (SqlCandidate cand : pool) {
            if (cand == null || cand.sqlId == null || seen.contains(cand.sqlId)) {
                continue;
            }
            out.add(cand);
            seen.add(cand.sqlId);
        }
        return out;
    }

    private void appendIds(List<SqlCandidate> out, Set<String> seen,
                           Map<String, SqlCandidate> byId, List<String> ids,
                           Connection c, String owner, boolean lookupHtz) {
        if (ids == null) {
            return;
        }
        for (String raw : ids) {
            if (raw == null) {
                continue;
            }
            String id = raw.trim();
            if (id.length() < 5 || seen.contains(id)) {
                continue;
            }
            SqlCandidate cand = byId.get(id);
            if (cand == null && lookupHtz) {
                cand = lookupOneHtz(c, owner, id);
            }
            if (cand == null) {
                continue;
            }
            out.add(cand);
            seen.add(id);
        }
    }

    /** 活跃会话中的 sql_id, 按 exec_start_time 升序 (跑得最久的优先). */
    private List<String> listActiveSqlIds(Connection c) {
        LinkedHashSet<String> ids = new LinkedHashSet<String>();
        // 与 ytop CollectSessionDetails 过滤对齐; 无 SQL_CHILD_NUMBER (Yashan 无此列)
        String[] sqls = new String[] {
            "SELECT s.sql_id FROM gv$session s "
                    + "WHERE s.TYPE NOT IN ('BACKGROUND') "
                    + "AND NVL(NULLIF(TRIM(s.status), ''), 'ACTIVE') NOT IN ('INACTIVE') "
                    + "AND s.sql_id IS NOT NULL "
                    + "AND LENGTH(TRIM(s.sql_id)) >= 5 "
                    + "AND NOT (s.INST_ID = TO_NUMBER(SYS_CONTEXT('USERENV', 'INSTANCE')) "
                    + "AND s.SID = TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))) "
                    + "ORDER BY s.exec_start_time ASC NULLS LAST, s.sql_id",
            "SELECT s.sql_id FROM v$session s "
                    + "WHERE s.TYPE NOT IN ('BACKGROUND') "
                    + "AND NVL(NULLIF(TRIM(s.status), ''), 'ACTIVE') NOT IN ('INACTIVE') "
                    + "AND s.sql_id IS NOT NULL "
                    + "AND LENGTH(TRIM(s.sql_id)) >= 5 "
                    + "AND s.SID <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')) "
                    + "ORDER BY s.exec_start_time ASC NULLS LAST, s.sql_id"
        };
        for (int i = 0; i < sqls.length; i++) {
            try (PreparedStatement ps = c.prepareStatement(sqls[i]);
                 ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    String id = rs.getString(1);
                    if (id != null) {
                        id = id.trim();
                        if (id.length() >= 5) {
                            ids.add(id);
                        }
                    }
                }
                if (!ids.isEmpty()) {
                    if (log != null) {
                        log.logDbg("active session sql_ids=" + ids.size()
                                + " source=" + (i == 0 ? "gv$session" : "v$session"));
                    }
                    return new ArrayList<String>(ids);
                }
            } catch (SQLException e) {
                if (log != null) {
                    log.logDbg("active session query failed: " + e.getMessage());
                }
            }
        }
        return new ArrayList<String>();
    }

    /** 从 HTZ_GV_SQL 聚合全部非空 sql_id 候选 (schema/len/snip). */
    List<SqlCandidate> listFromHtz(Connection c, String owner) {
        return queryHtzAll(c, owner);
    }

    /** 单测: HTZ 候选聚合 SQL. */
    String htzAggregateSql(String owner) {
        return buildHtzAggregateSql(HtzTables.qname(owner, HtzTables.GV_SQL), null);
    }

    private List<SqlCandidate> queryHtzAll(Connection c, String owner) {
        String tSql = HtzTables.qname(owner, HtzTables.GV_SQL);
        String sql = buildHtzAggregateSql(tSql, null);
        List<SqlCandidate> out = new ArrayList<SqlCandidate>();
        try (PreparedStatement ps = c.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                SqlCandidate cand = toCandidate(rs.getString(1), rs.getString(2),
                        rs.getInt(3), rs.getString(4));
                if (cand != null) {
                    out.add(cand);
                }
            }
        } catch (SQLException e) {
            log.logDbg("candidate query HTZ_GV_SQL failed: " + e.getMessage());
            return new ArrayList<SqlCandidate>();
        }
        return out;
    }

    private String buildHtzAggregateSql(String tSql, String sqlIdFilter) {
        StringBuilder sb = new StringBuilder();
        sb.append("SELECT sql_id, MAX(parsing_schema_name) AS parsing_schema_name, ");
        sb.append("MAX(DBMS_LOB.GETLENGTH(sql_fulltext)) AS sql_len, ");
        sb.append("MAX(DBMS_LOB.SUBSTR(sql_fulltext, 180, 1)) AS snip ");
        sb.append("FROM ").append(tSql).append(' ');
        sb.append("WHERE parsing_schema_name IS NOT NULL ");
        sb.append("AND ").append(NoiseFilter.sqlSchemaFilter(
                "UPPER(parsing_schema_name)", excludeSchemas, includeSchemas)).append(' ');
        sb.append("AND sql_id IS NOT NULL ");
        sb.append("AND LENGTH(TRIM(sql_id)) >= 5 ");
        sb.append("AND (sql_fulltext IS NULL OR sql_fulltext NOT LIKE '%")
                .append(NoiseFilter.PROBE_TAG).append("%') ");
        if (sqlIdFilter != null) {
            sb.append("AND sql_id = ? ");
        }
        sb.append("GROUP BY sql_id ");
        sb.append("ORDER BY sql_id");
        return sb.toString();
    }

    private SqlCandidate lookupOneHtz(Connection c, String owner, String sqlId) {
        String tSql = HtzTables.qname(owner, HtzTables.GV_SQL);
        String sql = buildHtzAggregateSql(tSql, sqlId);
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, sqlId);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    SqlCandidate cand = toCandidate(rs.getString(1), rs.getString(2),
                            rs.getInt(3), rs.getString(4));
                    if (cand != null) {
                        log.logDbg("backup-new sql_id not in pool; added from HTZ " + sqlId
                                + " schema=" + cand.schema);
                        return cand;
                    }
                }
            }
        } catch (SQLException e) {
            log.logDbg("lookup HTZ sql_id=" + sqlId + ": " + e.getMessage());
        }
        return null;
    }

    private List<SqlCandidate> queryAll(Connection c, boolean useGv) {
        String view = useGv ? "gv$sql" : "v$sql";
        String sql = "SELECT sql_id, MAX(parsing_schema_name) AS parsing_schema_name, "
                + "MAX(DBMS_LOB.GETLENGTH(sql_fulltext)) AS sql_len, "
                + "MAX(DBMS_LOB.SUBSTR(sql_fulltext, 180, 1)) AS snip "
                + "FROM " + view + " "
                + "WHERE parsing_schema_name IS NOT NULL "
                + "AND " + NoiseFilter.sqlSchemaFilter(
                        "UPPER(parsing_schema_name)", excludeSchemas, includeSchemas) + " "
                + "AND sql_id IS NOT NULL "
                + "AND sql_fulltext NOT LIKE '%" + NoiseFilter.PROBE_TAG + "%' "
                + "GROUP BY sql_id "
                + "ORDER BY sql_id";
        List<SqlCandidate> out = new ArrayList<SqlCandidate>();
        try (PreparedStatement ps = c.prepareStatement(sql);
             ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                SqlCandidate cand = toCandidate(rs.getString(1), rs.getString(2),
                        rs.getInt(3), rs.getString(4));
                if (cand != null) {
                    out.add(cand);
                }
            }
        } catch (SQLException e) {
            log.logDbg("candidate query " + view + " failed: " + e.getMessage());
            return new ArrayList<SqlCandidate>();
        }
        return out;
    }

    /**
     * 活跃 sql_id 置顶; 若活跃但不在全量池中, 再按 sql_id 从 gv$/v$sql 补一条
     * (避免热点 SQL 因全量列表截断/瞬时漏扫而排不到前面).
     */
    private List<SqlCandidate> prioritizeActive(Connection c, List<SqlCandidate> pool,
                                                List<String> activeIds) {
        if (activeIds == null || activeIds.isEmpty()) {
            return pool;
        }
        Map<String, SqlCandidate> byId = new LinkedHashMap<String, SqlCandidate>();
        for (SqlCandidate cand : pool) {
            if (cand != null && cand.sqlId != null) {
                byId.put(cand.sqlId, cand);
            }
        }
        List<SqlCandidate> out = new ArrayList<SqlCandidate>();
        Set<String> seen = new LinkedHashSet<String>();
        for (String id : activeIds) {
            if (id == null || seen.contains(id)) {
                continue;
            }
            SqlCandidate cand = byId.get(id);
            if (cand == null) {
                cand = lookupOne(c, id);
            }
            if (cand == null) {
                continue;
            }
            out.add(cand);
            seen.add(id);
        }
        for (SqlCandidate cand : pool) {
            if (cand == null || cand.sqlId == null || seen.contains(cand.sqlId)) {
                continue;
            }
            out.add(cand);
            seen.add(cand.sqlId);
        }
        return out;
    }

    private SqlCandidate lookupOne(Connection c, String sqlId) {
        String[] sqls = new String[] {
            "SELECT sql_id, MAX(parsing_schema_name), "
                    + "MAX(DBMS_LOB.GETLENGTH(sql_fulltext)), "
                    + "MAX(DBMS_LOB.SUBSTR(sql_fulltext, 180, 1)) "
                    + "FROM gv$sql WHERE sql_id = ? "
                    + "AND parsing_schema_name IS NOT NULL "
                    + "AND " + NoiseFilter.sqlSchemaFilter(
                            "UPPER(parsing_schema_name)", excludeSchemas, includeSchemas) + " "
                    + "AND (sql_fulltext IS NULL OR sql_fulltext NOT LIKE '%"
                    + NoiseFilter.PROBE_TAG + "%') "
                    + "GROUP BY sql_id",
            "SELECT sql_id, MAX(parsing_schema_name), "
                    + "MAX(DBMS_LOB.GETLENGTH(sql_fulltext)), "
                    + "MAX(DBMS_LOB.SUBSTR(sql_fulltext, 180, 1)) "
                    + "FROM v$sql WHERE sql_id = ? "
                    + "AND parsing_schema_name IS NOT NULL "
                    + "AND " + NoiseFilter.sqlSchemaFilter(
                            "UPPER(parsing_schema_name)", excludeSchemas, includeSchemas) + " "
                    + "AND (sql_fulltext IS NULL OR sql_fulltext NOT LIKE '%"
                    + NoiseFilter.PROBE_TAG + "%') "
                    + "GROUP BY sql_id"
        };
        for (String sql : sqls) {
            try (PreparedStatement ps = c.prepareStatement(sql)) {
                ps.setString(1, sqlId);
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) {
                        SqlCandidate cand = toCandidate(rs.getString(1), rs.getString(2),
                                rs.getInt(3), rs.getString(4));
                        if (cand != null) {
                            log.logDbg("active sql_id not in pool; added " + sqlId
                                    + " schema=" + cand.schema);
                            return cand;
                        }
                    }
                }
            } catch (SQLException e) {
                log.logDbg("lookup active sql_id=" + sqlId + ": " + e.getMessage());
            }
        }
        return null;
    }

    private SqlCandidate toCandidate(String sqlId, String schema, int sqlLen, String snip) {
        if (sqlId == null || sqlId.length() < 5) {
            return null;
        }
        if (!NoiseFilter.passesSchemaFilter(schema, excludeSchemas, includeSchemas)) {
            return null;
        }
        if (sqlLen < NoiseFilter.MIN_SQL_CHARS) {
            return null;
        }
        if (NoiseFilter.isNoiseText(snip)) {
            return null;
        }
        return new SqlCandidate(sqlId, schema, sqlLen, snip);
    }

    private static int countActiveFirst(List<SqlCandidate> ordered, List<String> activeIds) {
        if (ordered == null || activeIds == null || activeIds.isEmpty()) {
            return 0;
        }
        Set<String> active = new LinkedHashSet<String>();
        for (String id : activeIds) {
            if (id != null) {
                active.add(id);
            }
        }
        int n = 0;
        for (SqlCandidate cand : ordered) {
            if (cand == null || cand.sqlId == null || !active.contains(cand.sqlId)) {
                break;
            }
            n++;
        }
        return n;
    }

    private static int countBackupFirst(List<SqlCandidate> ordered, List<String> backupNewIds) {
        if (ordered == null || backupNewIds == null || backupNewIds.isEmpty()) {
            return 0;
        }
        Set<String> backup = new LinkedHashSet<String>();
        for (String id : backupNewIds) {
            if (id != null) {
                backup.add(id.trim());
            }
        }
        int n = 0;
        for (SqlCandidate cand : ordered) {
            if (cand == null || cand.sqlId == null || !backup.contains(cand.sqlId)) {
                break;
            }
            n++;
        }
        return n;
    }
}
