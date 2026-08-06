package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.db.HtzTables;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.log.DualLogger;
import com.yashan.sqlcollect.util.NoiseFilter;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * HTZ_GV_* 增量备份 (方案 C: ELIG 快照 + 单事务 + STATS MERGE).
 * 含 GV$SQL / SQLSTATS / BIND_CAPTURE / SQL_PLAN.
 * 表建在登录用户 schema 下; 失败直接抛错由 collect 回滚.
 */
public class BackupService {

    private final DualLogger log;
    private final String owner;
    /** true: 备份 WAS_CAPTURED=NO / last_captured 为空的占位行; 默认 false */
    private final boolean includeUncapturedBinds;
    /** 排除的 parsing_schema (已含内置 SYS/SYSDBA/SYSTEM) */
    private final List<String> excludeSchemas;
    /** 仅采集这些 parsing_schema; 空=不限制 (仍受 exclude) */
    private final List<String> includeSchemas;
    /** 本进程仅首次检查 HTZ_GV_* 建表建索引 */
    private boolean ddlReady;
    /** ELIG/R 是否为普通表 (非 GTT); 普通表每轮需 DELETE */
    private boolean stagingHeap;

    public BackupService(DualLogger log, String jdbcUser) {
        this(log, jdbcUser, false, null, null);
    }

    public BackupService(DualLogger log, String jdbcUser, boolean includeUncapturedBinds) {
        this(log, jdbcUser, includeUncapturedBinds, null, null);
    }

    public BackupService(DualLogger log, String jdbcUser, boolean includeUncapturedBinds,
                         List<String> excludeSchemas) {
        this(log, jdbcUser, includeUncapturedBinds, excludeSchemas, null);
    }

    public BackupService(DualLogger log, String jdbcUser, boolean includeUncapturedBinds,
                         List<String> excludeSchemas, List<String> includeSchemas) {
        this.log = log;
        this.owner = HtzTables.normalizeOwner(jdbcUser);
        this.includeUncapturedBinds = includeUncapturedBinds;
        this.excludeSchemas = excludeSchemas == null || excludeSchemas.isEmpty()
                ? NoiseFilter.builtinExcludeSchemas()
                : NoiseFilter.normalizeExcludeSchemas(excludeSchemas);
        this.includeSchemas = includeSchemas == null
                ? new ArrayList<String>()
                : NoiseFilter.normalizeExcludeSchemas(includeSchemas);
        this.ddlReady = false;
        this.stagingHeap = false;
    }

    public static class Result {
        public List<String> newSqlIds = new ArrayList<String>();
    }

    public Result run(JdbcSession session) throws SQLException {
        return run(session, null);
    }

    /**
     * @param forceSqlIds 本轮 -s 强制 sql_id, 并入 STATS MERGE 集合 R; 可为 null
     */
    public Result run(JdbcSession session, List<String> forceSqlIds) throws SQLException {
        Result r = new Result();
        Connection c = session.getConnection();
        log.logStep("backup_incremental", "owner=" + owner
                + " include_uncaptured_binds=" + includeUncapturedBinds
                + " exclude_schemas=" + excludeSchemas
                + " include_schemas=" + (includeSchemas.isEmpty() ? "(all)" : includeSchemas));
        log.logDbg("backup owner=" + owner + " (login-user schema)"
                + " include_uncaptured_binds=" + includeUncapturedBinds
                + " exclude_schemas=" + excludeSchemas
                + " include_schemas=" + includeSchemas);



        String tSql = HtzTables.qname(owner, HtzTables.GV_SQL);
        String tStat = HtzTables.qname(owner, HtzTables.GV_SQLSTATS);
        String tBind = HtzTables.qname(owner, HtzTables.GV_BIND);
        String tPlan = HtzTables.qname(owner, HtzTables.GV_SQL_PLAN);
        String tElig = HtzTables.qname(owner, HtzTables.ELIG_SQL);
        String tR = HtzTables.qname(owner, HtzTables.BACKUP_R);

        if (!ddlReady) {
            ensureTable(c, HtzTables.GV_SQL,
                    "CREATE TABLE " + tSql + " AS SELECT g.*, CAST(NULL AS DATE) AS COLLECT_TIME "
                            + "FROM GV$SQL g WHERE 1=0");
            ensureTable(c, HtzTables.GV_SQLSTATS,
                    "CREATE TABLE " + tStat + " AS SELECT g.*, CAST(NULL AS DATE) AS COLLECT_TIME "
                            + "FROM GV$SQLSTATS g WHERE 1=0");
            ensureTable(c, HtzTables.GV_BIND,
                    "CREATE TABLE " + tBind + " AS SELECT g.*, CAST(NULL AS DATE) AS COLLECT_TIME "
                            + "FROM GV$SQL_BIND_CAPTURE g WHERE 1=0");
            ensureTable(c, HtzTables.GV_SQL_PLAN,
                    "CREATE TABLE " + tPlan + " AS SELECT g.*, CAST(NULL AS DATE) AS COLLECT_TIME "
                            + "FROM GV$SQL_PLAN g WHERE 1=0");
            ensureIndexes(c, tSql, tStat, tBind, tPlan);
            ensureStaging(c, tElig, tR);
            ddlReady = true;
            log.logDbg("backup ddl ready (tables/indexes/staging checked once)");
        }

        // GTT/堆表均可: 每轮先清空, 避免残留键导致 join 放大
        HtzTables.execUpdate(c, log, "backup_clear_" + HtzTables.ELIG_SQL,
                "DELETE FROM " + tElig);
        HtzTables.execUpdate(c, log, "backup_clear_" + HtzTables.BACKUP_R,
                "DELETE FROM " + tR);

        int n = HtzTables.execUpdate(c, log, "backup_fill_elig",
                buildEligInsert(tElig, excludeSchemas, includeSchemas));
        log.logDbg("backup ELIG rows=" + n);

        // 与 INSERT 同一 anti-join 谓词取 sql_id, 避免 JVM/DB 时钟偏差导致 backup_new=0
        List<String> backupNew = fetchNewSqlIdsByAntiJoin(c, tSql, tElig);
        log.logDbg("backup_new candidates=" + backupNew.size());

        n = HtzTables.execUpdate(c, log, "backup_insert_" + HtzTables.GV_SQL,
                buildSqlInsert(tSql, tElig));
        log.logDbg("backup INSERT " + HtzTables.GV_SQL + " rows=" + n);
        if (n > 0 && backupNew.isEmpty()) {
            log.logWarn("backup INSERT " + HtzTables.GV_SQL + " rows=" + n
                    + " but backup_new candidates empty");
        }

        fillBackupR(c, tR, backupNew, forceSqlIds);

        n = HtzTables.execUpdate(c, log, "backup_merge_" + HtzTables.GV_SQLSTATS,
                buildStatsMerge(tStat, tElig, tR));
        log.logDbg("backup MERGE " + HtzTables.GV_SQLSTATS + " rows=" + n);


        n = HtzTables.execUpdate(c, log, "backup_insert_" + HtzTables.GV_BIND,
                buildBindInsert(tBind, tElig, includeUncapturedBinds));
        log.logDbg("backup INSERT " + HtzTables.GV_BIND + " rows=" + n);

        n = HtzTables.execUpdate(c, log, "backup_insert_" + HtzTables.GV_SQL_PLAN,
                buildPlanInsert(tPlan, tElig));
        log.logDbg("backup INSERT " + HtzTables.GV_SQL_PLAN + " rows=" + n);

        c.commit();
        r.newSqlIds = backupNew;
        log.logDbg("backup done BACKUP_NEW_N=" + r.newSqlIds.size());
        for (String sid : r.newSqlIds) {
            log.logDbg("backup-new sql_id=" + sid);
        }
        return r;
    }

    // ---- SQL 模板 (供单测断言形状) ----

    static String buildEligInsert(String eligQname) {
        return buildEligInsert(eligQname, null, null);
    }

    static String buildEligInsert(String eligQname, List<String> excludeSchemas) {
        return buildEligInsert(eligQname, excludeSchemas, null);
    }

    static String buildEligInsert(String eligQname, List<String> excludeSchemas,
                                  List<String> includeSchemas) {
        String filter = NoiseFilter.sqlSchemaFilter(
                "UPPER(NVL(g.parsing_schema_name, 'X'))", excludeSchemas, includeSchemas);
        return "INSERT INTO " + eligQname + " (INST_ID, SQL_ID, CHILD_NUMBER) "
                + "SELECT DISTINCT g.inst_id, g.sql_id, g.child_number FROM GV$SQL g "
                + "WHERE g.sql_id IS NOT NULL "
                + "AND " + filter + " "
                + "AND (g.sql_fulltext IS NULL OR INSTR(g.sql_fulltext, '"
                + NoiseFilter.PROBE_TAG + "') = 0)";
    }

    static String buildSqlInsert(String sqlQname, String eligQname) {
        return "INSERT INTO " + sqlQname + " "
                + "SELECT g.*, SYSDATE FROM GV$SQL g "
                + "JOIN " + eligQname + " e "
                + "ON e.inst_id = g.inst_id AND e.sql_id = g.sql_id "
                + "AND e.child_number = g.child_number "
                + "WHERE NOT EXISTS (SELECT 1 FROM " + sqlQname + " h "
                + "WHERE h.inst_id = g.inst_id AND h.sql_id = g.sql_id "
                + "AND h.child_number = g.child_number) "
                + "AND g.ROWID = (SELECT MAX(g2.ROWID) FROM GV$SQL g2 "
                + "WHERE g2.inst_id = g.inst_id AND g2.sql_id = g.sql_id "
                + "AND g2.child_number = g.child_number)";
    }

    /** 与 {@link #buildSqlInsert} 相同 anti-join, 仅投影 DISTINCT sql_id. */
    static String buildNewSqlIdSelect(String sqlQname, String eligQname) {
        return "SELECT DISTINCT g.sql_id FROM GV$SQL g "
                + "JOIN " + eligQname + " e "
                + "ON e.inst_id = g.inst_id AND e.sql_id = g.sql_id "
                + "AND e.child_number = g.child_number "
                + "WHERE NOT EXISTS (SELECT 1 FROM " + sqlQname + " h "
                + "WHERE h.inst_id = g.inst_id AND h.sql_id = g.sql_id "
                + "AND h.child_number = g.child_number) "
                + "AND g.ROWID = (SELECT MAX(g2.ROWID) FROM GV$SQL g2 "
                + "WHERE g2.inst_id = g.inst_id AND g2.sql_id = g.sql_id "
                + "AND g2.child_number = g.child_number) "
                + "ORDER BY 1";
    }

    /**
     * STATS MERGE: ON 键无 NVL; 源受 ELIG + R 半连接限制;
     * GV$SQLSTATS 可能对同一 (inst_id,sql_id) 多行, 用 ROW_NUMBER 去重避免 YAS-04427.
     */
    static String buildStatsMerge(String statQname, String eligQname, String rQname) {
        String cols = statsDataColumns();
        return "MERGE INTO " + statQname + " t "
                + "USING ("
                + "SELECT * FROM ("
                + "SELECT s.*, ROW_NUMBER() OVER ("
                + "PARTITION BY s.inst_id, s.sql_id "
                + "ORDER BY s.last_active_time DESC NULLS LAST, s.elapsed_time DESC NULLS LAST"
                + ") AS rn "
                + "FROM GV$SQLSTATS s "
                + "JOIN " + rQname + " r ON r.sql_id = s.sql_id "
                + "WHERE s.sql_id IS NOT NULL "
                + "AND EXISTS (SELECT 1 FROM " + eligQname + " e "
                + "WHERE e.inst_id = s.inst_id AND e.sql_id = s.sql_id)"
                + ") WHERE rn = 1"
                + ") src "
                + "ON (t.INST_ID = src.INST_ID AND t.SQL_ID = src.SQL_ID) "
                + "WHEN MATCHED THEN UPDATE SET "
                + "t.PLAN_HASH_VALUE = src.PLAN_HASH_VALUE, "
                + "t.PARSE_CALLS = src.PARSE_CALLS, "
                + "t.DISK_READS = src.DISK_READS, "
                + "t.DIRECT_WRITES = src.DIRECT_WRITES, "
                + "t.BUFFER_GETS = src.BUFFER_GETS, "
                + "t.ROWS_PROCESSED = src.ROWS_PROCESSED, "
                + "t.FETCHES = src.FETCHES, "
                + "t.EXECUTIONS = src.EXECUTIONS, "
                + "t.END_OF_FETCH_COUNT = src.END_OF_FETCH_COUNT, "
                + "t.PX_SERVERS_EXECUTIONS = src.PX_SERVERS_EXECUTIONS, "
                + "t.CPU_TIME = src.CPU_TIME, "
                + "t.ELAPSED_TIME = src.ELAPSED_TIME, "
                + "t.APPLICATION_WAIT_TIME = src.APPLICATION_WAIT_TIME, "
                + "t.CONCURRENCY_WAIT_TIME = src.CONCURRENCY_WAIT_TIME, "
                + "t.CLUSTER_WAIT_TIME = src.CLUSTER_WAIT_TIME, "
                + "t.USER_IO_WAIT_TIME = src.USER_IO_WAIT_TIME, "
                + "t.PLSQL_EXEC_TIME = src.PLSQL_EXEC_TIME, "
                + "t.SORTS = src.SORTS, "
                + "t.SHARABLE_MEM = src.SHARABLE_MEM, "
                + "t.COLLECT_TIME = SYSDATE "
                + "WHEN NOT MATCHED THEN INSERT (" + cols + ", COLLECT_TIME) VALUES ("
                + statsSrcColumns("src") + ", SYSDATE)";
    }

    /** 兼容旧单测签名: elig 兼作 R 时用同一表名占位. */
    static String buildStatsMerge(String statQname, String eligQname) {
        return buildStatsMerge(statQname, eligQname, eligQname);
    }

    /** 默认不采集未 capture 行 (last_captured IS NULL / WAS_CAPTURED=NO). */
    static String buildBindInsert(String bindQname, String eligQname) {
        return buildBindInsert(bindQname, eligQname, false);
    }

    /**
     * @param includeUncaptured true 时备份占位行; false 时仅 last_captured 非空
     */
    static String buildBindInsert(String bindQname, String eligQname, boolean includeUncaptured) {
        String capturedPred = includeUncaptured
                ? ""
                : "AND b.last_captured IS NOT NULL ";
        return "INSERT INTO " + bindQname + " "
                + "SELECT b.*, SYSDATE FROM GV$SQL_BIND_CAPTURE b "
                + "JOIN " + eligQname + " e "
                + "ON e.inst_id = b.inst_id AND e.sql_id = b.sql_id "
                + "AND e.child_number = b.child_number "
                + "WHERE b.sql_id IS NOT NULL "
                + capturedPred
                + "AND NOT EXISTS (SELECT 1 FROM " + bindQname + " h "
                + "WHERE h.inst_id = b.inst_id AND h.sql_id = b.sql_id "
                + "AND h.child_number = b.child_number AND h.position = b.position "
                + "AND (h.name = b.name OR (h.name IS NULL AND b.name IS NULL)))";
    }

    static String buildPlanInsert(String planQname, String eligQname) {
        return "INSERT INTO " + planQname + " "
                + "SELECT p.*, SYSDATE FROM GV$SQL_PLAN p "
                + "JOIN " + eligQname + " e "
                + "ON e.inst_id = p.inst_id AND e.sql_id = p.sql_id "
                + "AND e.child_number = p.child_number "
                + "WHERE p.sql_id IS NOT NULL AND p.id IS NOT NULL "
                + "AND NOT EXISTS (SELECT 1 FROM " + planQname + " h "
                + "WHERE h.inst_id = p.inst_id AND h.sql_id = p.sql_id "
                + "AND h.child_number = p.child_number "
                + "AND h.plan_hash_value = p.plan_hash_value "
                + "AND h.id = p.id)";
    }

    /** HTZ_GV_SQLSTATS 数据列 (不含 COLLECT_TIME), 与 23.5 CTAS 对齐. */
    private static String statsDataColumns() {
        return "GROUP_ID, GROUP_NODE_ID, INST_ID, SQL_TEXT, SQL_FULLTEXT, SQL_ID, "
                + "LAST_ACTIVE_TIME, LAST_ACTIVE_CHILD_ADDRESS, PLAN_HASH_VALUE, PARSE_CALLS, "
                + "DISK_READS, DIRECT_WRITES, BUFFER_GETS, ROWS_PROCESSED, SERIALIZABLE_ABORTS, "
                + "FETCHES, EXECUTIONS, END_OF_FETCH_COUNT, LOADS, VERSION_COUNT, INVALIDATIONS, "
                + "PX_SERVERS_EXECUTIONS, CPU_TIME, ELAPSED_TIME, APPLICATION_WAIT_TIME, "
                + "CONCURRENCY_WAIT_TIME, CLUSTER_WAIT_TIME, USER_IO_WAIT_TIME, PLSQL_EXEC_TIME, "
                + "JAVA_EXEC_TIME, SORTS, SHARABLE_MEM, TOTAL_SHARABLE_MEM, BLOCK_RECEIVED, "
                + "CR_BLOCK_RECEIVED, LOCAL_GRANTS, REMOTE_GRANTS, LOCAL_UPGRADES, REMOTE_UPGRADES";
    }

    private static String statsSrcColumns(String alias) {
        String[] parts = statsDataColumns().split(", ");
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < parts.length; i++) {
            if (i > 0) {
                sb.append(", ");
            }
            sb.append(alias).append('.').append(parts[i].trim());
        }
        return sb.toString();
    }

    private void ensureStaging(Connection c, String tElig, String tR) throws SQLException {
        if (!HtzTables.tableExists(c, owner, HtzTables.ELIG_SQL)) {
            try {
                HtzTables.exec(c, log, "backup_create_gtt_" + HtzTables.ELIG_SQL,
                        "CREATE GLOBAL TEMPORARY TABLE " + HtzTables.ELIG_SQL
                                + " (INST_ID NUMBER, SQL_ID VARCHAR(13), CHILD_NUMBER NUMBER) "
                                + "ON COMMIT DELETE ROWS");
                stagingHeap = false;
                log.logInfo("backup TABLE " + tElig + " created (GTT)");
            } catch (SQLException e) {
                log.logWarn("GTT " + HtzTables.ELIG_SQL + " failed; fallback heap: " + e.getMessage());
                HtzTables.exec(c, log, "backup_create_" + HtzTables.ELIG_SQL,
                        "CREATE TABLE " + tElig
                                + " (INST_ID NUMBER, SQL_ID VARCHAR(13), CHILD_NUMBER NUMBER)");
                HtzTables.ensureIndex(c, log, owner, "HTZ_ELIG_SQL_K1",
                        "CREATE INDEX HTZ_ELIG_SQL_K1 ON " + tElig
                                + " (INST_ID, SQL_ID, CHILD_NUMBER)");
                stagingHeap = true;
                log.logInfo("backup TABLE " + tElig + " created (heap)");
            }
        } else {
            stagingHeap = !isTemporaryTable(c, HtzTables.ELIG_SQL);
            log.logDbg("backup TABLE " + tElig + " exists heap=" + stagingHeap);
        }

        if (!HtzTables.tableExists(c, owner, HtzTables.BACKUP_R)) {
            if (!stagingHeap) {
                try {
                    HtzTables.exec(c, log, "backup_create_gtt_" + HtzTables.BACKUP_R,
                            "CREATE GLOBAL TEMPORARY TABLE " + HtzTables.BACKUP_R
                                    + " (SQL_ID VARCHAR(13)) ON COMMIT DELETE ROWS");
                    log.logInfo("backup TABLE " + tR + " created (GTT)");
                    return;
                } catch (SQLException e) {
                    log.logWarn("GTT " + HtzTables.BACKUP_R + " failed; fallback heap: "
                            + e.getMessage());
                    stagingHeap = true;
                }
            }
            HtzTables.exec(c, log, "backup_create_" + HtzTables.BACKUP_R,
                    "CREATE TABLE " + tR + " (SQL_ID VARCHAR(13))");
            HtzTables.ensureIndex(c, log, owner, "HTZ_BACKUP_R_K1",
                    "CREATE INDEX HTZ_BACKUP_R_K1 ON " + tR + " (SQL_ID)");
            log.logInfo("backup TABLE " + tR + " created (heap)");
        } else {
            if (!stagingHeap) {
                stagingHeap = !isTemporaryTable(c, HtzTables.BACKUP_R);
            }
            log.logDbg("backup TABLE " + tR + " exists heap=" + stagingHeap);
        }
    }

    private boolean isTemporaryTable(Connection c, String table) {
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT temporary FROM user_tables WHERE table_name = ?")) {
            ps.setString(1, table.toUpperCase(Locale.ROOT));
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    String t = rs.getString(1);
                    return t != null && (t.startsWith("Y") || t.startsWith("y")
                            || "TEMPORARY".equalsIgnoreCase(t));
                }
            }
        } catch (SQLException e) {
            log.logDbg("temporary flag lookup failed for " + table + ": " + e.getMessage());
        }
        return false;
    }

    private void fillBackupR(Connection c, String tR, List<String> backupNew,
                             List<String> forceSqlIds) throws SQLException {
        Set<String> r = new LinkedHashSet<String>();
        if (backupNew != null) {
            for (String id : backupNew) {
                addSqlId(r, id);
            }
        }
        if (forceSqlIds != null) {
            for (String id : forceSqlIds) {
                addSqlId(r, id);
            }
        }
        if (r.isEmpty()) {
            log.logDbg("backup R empty; STATS MERGE will affect 0 rows");
            return;
        }
        String sql = "INSERT INTO " + tR + " (SQL_ID) VALUES (?)";
        log.logDbg("jdbc sql [backup_fill_r]: " + sql + " n=" + r.size());
        PreparedStatement ps = c.prepareStatement(sql);
        try {
            for (String id : r) {
                ps.setString(1, id);
                ps.addBatch();
            }
            ps.executeBatch();
        } finally {
            ps.close();
        }
        log.logDbg("backup R size=" + r.size());
    }

    private void addSqlId(Set<String> dest, String id) {
        if (id == null) {
            return;
        }
        String t = id.trim();
        if (t.isEmpty()) {
            return;
        }
        if (t.length() > 13) {
            log.logWarn("backup skip sql_id longer than 13: len=" + t.length());
            return;
        }
        dest.add(t);
    }

    private void ensureTable(Connection c, String table, String ctas) throws SQLException {
        if (HtzTables.tableExists(c, owner, table)) {
            log.logDbg("backup TABLE " + HtzTables.qname(owner, table) + " exists");
            return;
        }
        log.logInfo("backup TABLE " + HtzTables.qname(owner, table) + " creating");
        HtzTables.exec(c, log, "backup_create_" + table, ctas);
        log.logInfo("backup TABLE " + HtzTables.qname(owner, table) + " created");
    }

    private void ensureIndexes(Connection c, String tSql, String tStat, String tBind, String tPlan)
            throws SQLException {
        HtzTables.ensureIndex(c, log, owner, "HTZ_GV_SQL_CT",
                "CREATE INDEX HTZ_GV_SQL_CT ON " + tSql + " (COLLECT_TIME)");
        HtzTables.ensureIndex(c, log, owner, "HTZ_GV_SQL_K1",
                "CREATE INDEX HTZ_GV_SQL_K1 ON " + tSql + " (INST_ID, SQL_ID, CHILD_NUMBER)");

        HtzTables.ensureIndex(c, log, owner, "HTZ_GV_SQLSTATS_CT",
                "CREATE INDEX HTZ_GV_SQLSTATS_CT ON " + tStat + " (COLLECT_TIME)");
        HtzTables.ensureIndex(c, log, owner, "HTZ_GV_SQLSTATS_K1",
                "CREATE INDEX HTZ_GV_SQLSTATS_K1 ON " + tStat + " (INST_ID, SQL_ID)");

        HtzTables.ensureIndex(c, log, owner, "HTZ_GV_BIND_CT",
                "CREATE INDEX HTZ_GV_BIND_CT ON " + tBind + " (COLLECT_TIME)");
        HtzTables.ensureIndex(c, log, owner, "HTZ_GV_BIND_K1",
                "CREATE INDEX HTZ_GV_BIND_K1 ON " + tBind
                        + " (INST_ID, SQL_ID, CHILD_NUMBER, POSITION, NAME)");

        HtzTables.ensureIndex(c, log, owner, "HTZ_GV_SQL_PLAN_CT",
                "CREATE INDEX HTZ_GV_SQL_PLAN_CT ON " + tPlan + " (COLLECT_TIME)");
        HtzTables.ensureIndex(c, log, owner, "HTZ_GV_SQL_PLAN_K1",
                "CREATE INDEX HTZ_GV_SQL_PLAN_K1 ON " + tPlan
                        + " (INST_ID, SQL_ID, CHILD_NUMBER, PLAN_HASH_VALUE, ID)");
    }

    /** 读将插入 HTZ_GV_SQL 的 sql_id (与 INSERT anti-join 一致). */
    private List<String> fetchNewSqlIdsByAntiJoin(Connection c, String tSql, String tElig)
            throws SQLException {
        Set<String> ids = new LinkedHashSet<String>();
        String q = buildNewSqlIdSelect(tSql, tElig);
        log.logDbg("jdbc sql [backup_new_ids]: " + q);
        PreparedStatement ps = c.prepareStatement(q);
        ResultSet rs = ps.executeQuery();
        while (rs.next()) {
            String sid = rs.getString(1);
            if (sid != null && !sid.isEmpty()) {
                ids.add(sid);
            }
        }
        rs.close();
        ps.close();
        return new ArrayList<String>(ids);
    }
}
