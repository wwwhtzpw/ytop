package com.yashan.sqlcollect.replay;

import com.yashan.sqlcollect.db.JdbcPool;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.model.ReplayPackageMeta;
import com.yashan.sqlcollect.util.JsonBinds;
import com.yashan.sqlcollect.util.PipeEscape;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** JDBC replay 引擎 (file/gv), 进程内调用; 连接经 {@link JdbcPool} 复用 */
public class ReplayEngine {

    private final String jdbcUrl;
    private final String lookupUser;
    private final String lookupPass;
    private final Map<String, String[]> maps;
    private final boolean schemaViaAlter;
    private final LineOut out;
    private final JdbcPool pool;
    private final boolean ownsPool;
    /** JDBC Statement.setQueryTimeout 秒数; &lt;=0 不限制 */
    private int queryTimeoutSec = 0;
    /** 指纹不一致时是否阻断回放; true=fail (默认), false=WARN 后继续 */
    private boolean shaMismatchFail = true;
    private ReplayResultCsv resultCsv;
    private final ThreadLocal<RowCtx> rowCtx = new ThreadLocal<RowCtx>();
    /** 最近一次失败原因, 供终端 WARN 一行摘要 */
    private final ThreadLocal<String> lastFailReason = new ThreadLocal<String>();
    /** 最近一次成功明细 (kind/rows/update-count/ms), 供终端 INFO 一行摘要 */
    private final ThreadLocal<String> lastOkDetail = new ThreadLocal<String>();

    private static final class RowCtx {
        final String sqlId;
        final int child;
        final int instId;

        RowCtx(String sqlId, int child, int instId) {
            this.sqlId = sqlId == null ? "" : sqlId;
            this.child = child;
            this.instId = instId;
        }
    }

    /** 记录失败原因, 供终端 WARN 一行摘要 */
    public void noteFail(String reason) {
        lastFailReason.set(reason == null ? "" : reason);
        lastOkDetail.remove();
    }

    /** 取出并清除最近失败原因 */
    public String takeLastFailReason() {
        String r = lastFailReason.get();
        lastFailReason.remove();
        return r == null ? "" : r;
    }

    /** 记录成功明细, 供终端 INFO 一行摘要 */
    public void noteOkDetail(String detail) {
        lastOkDetail.set(detail == null ? "" : detail);
        lastFailReason.remove();
    }

    /** 取出并清除最近成功明细 */
    public String takeLastOkDetail() {
        String r = lastOkDetail.get();
        lastOkDetail.remove();
        return r == null ? "" : r;
    }

    /** 行输出回调; step/dbg 写入 debug 日志便于逐步跟踪 */
    public interface LineOut {
        void println(String line);

        void step(String name, String detail);

        void dbg(String msg);
    }

    private static final LineOut STDOUT = new LineOut() {
        public void println(String line) {
            System.out.println(line);
        }

        public void step(String name, String detail) {
        }

        public void dbg(String msg) {
        }
    };

    public ReplayEngine(String jdbcUrl, String lookupUser, String lookupPass,
                        Map<String, String[]> maps, boolean schemaViaAlter, LineOut out) {
        this(jdbcUrl, lookupUser, lookupPass, maps, schemaViaAlter, out, null);
    }

    public ReplayEngine(String jdbcUrl, String lookupUser, String lookupPass,
                        Map<String, String[]> maps, boolean schemaViaAlter, LineOut out,
                        JdbcPool pool) {
        this.jdbcUrl = jdbcUrl;
        this.lookupUser = lookupUser;
        this.lookupPass = lookupPass;
        this.maps = maps == null ? new HashMap<String, String[]>() : maps;
        this.schemaViaAlter = schemaViaAlter;
        this.out = out == null ? STDOUT : out;
        if (pool != null) {
            this.pool = pool;
            this.ownsPool = false;
        } else {
            this.pool = new JdbcPool(null, JdbcPool.DEFAULT_MAX_IDLE_PER_USER);
            this.ownsPool = true;
        }
    }

    public void setQueryTimeoutSec(int sec) {
        this.queryTimeoutSec = sec < 0 ? 0 : sec;
    }

    public int getQueryTimeoutSec() {
        return queryTimeoutSec;
    }

    /** true=指纹失败阻断回放 (默认); false=WARN 后继续回放 */
    public void setShaMismatchFail(boolean fail) {
        this.shaMismatchFail = fail;
    }

    public boolean isShaMismatchFail() {
        return shaMismatchFail;
    }

    public void setResultCsv(ReplayResultCsv csv) {
        this.resultCsv = csv;
    }

    public void beginRow(String sqlId, int child, int instId) {
        rowCtx.set(new RowCtx(sqlId, child, instId));
    }

    public void endRow() {
        rowCtx.remove();
    }

    /** 关闭引擎自建池; 外部传入的共享池不在此关闭 */
    public void close() {
        if (ownsPool && pool != null) {
            pool.close();
        }
    }

    private void applyQueryTimeout(Statement st) throws SQLException {
        if (queryTimeoutSec > 0 && st != null) {
            st.setQueryTimeout(queryTimeoutSec);
        }
    }

    public static Map<String, String[]> mapsFromConfig(Map<String, String[]> cfgMaps) {
        Map<String, String[]> m = new HashMap<String, String[]>();
        if (cfgMaps != null) {
            m.putAll(cfgMaps);
        }
        return m;
    }

    public static Map<String, String[]> loadUserMapsFile(String path) throws IOException {
        Map<String, String[]> maps = new HashMap<String, String[]>();
        if (path == null || path.isEmpty() || "-".equals(path) || !Files.exists(Paths.get(path))) {
            return maps;
        }
        for (String ln : readFile(path).split("\n", -1)) {
            if (ln.isEmpty() || ln.startsWith("#")) {
                continue;
            }
            String[] p = PipeEscape.split(ln, 3);
            if (p.length < 3) {
                continue;
            }
            String schema = p[0].trim().toUpperCase(Locale.ROOT);
            if (schema.isEmpty()) {
                continue;
            }
            maps.put(schema, new String[] {p[1].trim(), p[2]});
        }
        return maps;
    }

    public ReplayResult replayFile(String schema, String sqlFile, String bindsFile,
                                   String mode, boolean force) throws Exception {
        return replayFile(schema, sqlFile, bindsFile, mode, force, "", 0, 1, null);
    }

    public ReplayResult replayFile(String schema, String sqlFile, String bindsFile,
                                   String mode, boolean force,
                                   String sqlId, int child, int instId) throws Exception {
        return replayFile(schema, sqlFile, bindsFile, mode, force, sqlId, child, instId, null);
    }

    public ReplayResult replayFile(String schema, String sqlFile, String bindsFile,
                                   String mode, boolean force,
                                   String sqlId, int child, int instId,
                                   String expectedSqlSha256) throws Exception {
        beginRow(sqlId, child, instId);
        out.step("replay_file", "sql_id=" + sqlId + " child=" + child + " inst_id=" + instId
                + " mode=" + mode + " force=" + force);
        out.dbg("schema_via_alter=" + schemaViaAlter + " lookup_user=" + lookupUser
                + " map_entries=" + maps.size());
        out.dbg("sql_file=" + sqlFile);
        out.dbg("binds_file=" + bindsFile);
        out.dbg("parsing_schema=" + (schema == null ? "" : schema));
        out.dbg("expected_sql_sha256=" + (expectedSqlSha256 == null ? "" : expectedSqlSha256));
        try {
            String sql = readFile(sqlFile);
            out.dbg("sql_chars=" + (sql == null ? 0 : sql.length()));
            out.dbg("sql_text_begin");
            out.dbg(previewText(sql, 8000));
            out.dbg("sql_text_end");
            if (!assertSqlSha256(sql, expectedSqlSha256, "file")) {
                noteFail("sql_sha256 mismatch");
                ReplayResult r = new ReplayResult(0, 1);
                out.println("replay summary ok=" + r.ok + " fail=" + r.fail);
                out.step("replay_file_done", "fail sha mismatch");
                return r;
            }
            List<String[]> binds = readBinds(bindsFile);
            // 若旁路有 binds.json (含 name), 用方案 A 对齐; 否则仅 :name→?
            java.nio.file.Path bindsJson = Paths.get(bindsFile).resolveSibling("binds.json");
            if (Files.exists(bindsJson)) {
                try {
                    String json = readFile(bindsJson.toString());
                    List<com.yashan.sqlcollect.model.BindValue> named =
                            JsonBinds.read(json);
                    if (named != null && !named.isEmpty()) {
                        com.yashan.sqlcollect.collect.LiteralBindRewrite.Aligned aligned =
                                com.yashan.sqlcollect.collect.LiteralBindRewrite.align(sql, named);
                        for (String w : aligned.warnings) {
                            out.println("replay warn bind align: " + w);
                        }
                        sql = aligned.sql;
                        binds = com.yashan.sqlcollect.db.SqlLookup.toReplayRows(aligned.binds);
                        out.dbg("bind_align=A from binds.json");
                    }
                } catch (Exception e) {
                    out.println("replay warn binds.json align skipped: " + e.getMessage());
                    sql = com.yashan.sqlcollect.collect.LiteralBindRewrite.toQuestionMarks(sql);
                }
            } else {
                sql = com.yashan.sqlcollect.collect.LiteralBindRewrite.toQuestionMarks(sql);
                out.dbg("bind_align=qmark (no binds.json)");
            }
            dumpBinds(binds);
            out.println("replay source=file");
            out.step("resolve_creds", "schema=" + (schema == null ? "" : schema));
            String[] cred = resolveExecCreds(schema);
            out.dbg("exec_user=" + cred[0] + (schemaViaAlter ? " (alter-session)" : " (map/fallback)"));
            out.println("replay login-user=" + cred[0] + ("dry".equalsIgnoreCase(mode) ? " (planned)" : ""));
            boolean ok;
            if ("dry".equalsIgnoreCase(mode)) {
                out.step("exec_sql", "dry-run");
                ok = execSql(null, schema, sql, binds, mode, force, cred[0]);
            } else {
                out.step("jdbc_connect", cred[0]);
                Connection c = connectAs(cred[0], cred[1]);
                try {
                    out.step("exec_sql", "live");
                    ok = execSql(c, schema, sql, binds, mode, force, cred[0]);
                } finally {
                    c.close();
                    out.dbg("jdbc_connection_closed user=" + cred[0]);
                }
            }
            ReplayResult r = new ReplayResult(ok ? 1 : 0, ok ? 0 : 1);
            out.println("replay summary ok=" + r.ok + " fail=" + r.fail);
            out.step("replay_file_done", ok ? "ok" : "fail");
            return r;
        } finally {
            endRow();
        }
    }

    public ReplayResult replayGv(String sqlId, String mode, boolean force) throws Exception {
        out.step("replay_gv", "sql_id=" + sqlId + " mode=" + mode + " force=" + force);
        String schema = null;
        int child = 0;
        int instId = 1;
        String sql = null;
        List<String[]> binds = new ArrayList<String[]>();
        out.step("jdbc_lookup_connect", lookupUser);
        Connection cLookup = connectAs(lookupUser, lookupPass);
        out.println("replay lookup-user=" + lookupUser);
        try {
            // 与 collect/sqlmap 一致: 先按 last_captured 非空选 child, 再取该 child 文本与绑定
            com.yashan.sqlcollect.db.SqlLookup.CapturedChild prefer =
                    com.yashan.sqlcollect.db.SqlLookup.pickBestCapturedChild(cLookup, sqlId);
            if (prefer != null) {
                child = prefer.childNumber;
                instId = prefer.instId;
                out.dbg("prefer capture child=" + child + " inst_id=" + instId
                        + " filled=" + prefer.filled + " src=" + prefer.source);
            }
            out.step("lookup_gv$sql", sqlId);
            try (PreparedStatement ps = cLookup.prepareStatement(
                    prefer != null
                            ? ("SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext FROM gv$sql "
                            + "WHERE sql_id = ? AND child_number = ? AND NVL(inst_id,1) = ? AND ROWNUM = 1")
                            : ("SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext FROM ("
                            + " SELECT s.parsing_schema_name, s.child_number, s.inst_id, s.sql_fulltext"
                            + "   FROM gv$sql s WHERE s.sql_id = ?"
                            + "  ORDER BY " + com.yashan.sqlcollect.db.SqlLookup.ORDER_GV_PREFER_CAPTURED
                            + ") WHERE ROWNUM = 1"))) {
                ps.setString(1, sqlId);
                if (prefer != null) {
                    ps.setInt(2, child);
                    ps.setInt(3, instId);
                }
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) {
                        schema = rs.getString(1);
                        child = rs.getInt(2);
                        instId = rs.getInt(3);
                        sql = JdbcSession.readClob(rs.getClob(4));
                        out.dbg("gv$sql hit schema=" + schema + " child=" + child
                                + " inst_id=" + instId);
                    }
                }
            } catch (SQLException e) {
                out.println("replay warn gv$sql " + e.getMessage());
                out.dbg("gv$sql miss/error: " + e.getMessage());
            }
            if (sql == null && prefer != null) {
                // inst 对不上时放宽: 只按 child
                try (PreparedStatement ps = cLookup.prepareStatement(
                        "SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext FROM gv$sql "
                                + "WHERE sql_id = ? AND child_number = ? AND ROWNUM = 1")) {
                    ps.setString(1, sqlId);
                    ps.setInt(2, prefer.childNumber);
                    try (ResultSet rs = ps.executeQuery()) {
                        if (rs.next()) {
                            schema = rs.getString(1);
                            child = rs.getInt(2);
                            instId = rs.getInt(3);
                            sql = JdbcSession.readClob(rs.getClob(4));
                            out.dbg("gv$sql hit by child (loose inst) schema=" + schema
                                    + " child=" + child + " inst_id=" + instId);
                        }
                    }
                } catch (SQLException e) {
                    out.dbg("gv$sql by child fail: " + e.getMessage());
                }
            }
            if (sql == null) {
                out.step("lookup_v$sql", sqlId);
                try (PreparedStatement ps = cLookup.prepareStatement(
                        prefer != null
                                ? ("SELECT parsing_schema_name, child_number, sql_fulltext FROM v$sql "
                                + "WHERE sql_id = ? AND child_number = ? AND ROWNUM = 1")
                                : ("SELECT parsing_schema_name, child_number, sql_fulltext FROM ("
                                + " SELECT s.parsing_schema_name, s.child_number, s.sql_fulltext"
                                + "   FROM v$sql s WHERE s.sql_id = ?"
                                + "  ORDER BY " + com.yashan.sqlcollect.db.SqlLookup.ORDER_V_PREFER_CAPTURED
                                + ") WHERE ROWNUM = 1"))) {
                    ps.setString(1, sqlId);
                    if (prefer != null) {
                        ps.setInt(2, prefer.childNumber);
                    }
                    try (ResultSet rs = ps.executeQuery()) {
                        if (!rs.next()) {
                            out.println("replay fail sql_id not found in gv$/v$sql: " + sqlId);
                            out.step("replay_gv_done", "fail not found");
                            return new ReplayResult(0, 1);
                        }
                        schema = rs.getString(1);
                        child = rs.getInt(2);
                        instId = prefer != null ? prefer.instId : 1;
                        sql = JdbcSession.readClob(rs.getClob(3));
                        out.dbg("v$sql hit schema=" + schema + " child=" + child);
                    }
                }
            }
            out.println("replay source=gv sql_id=" + sqlId + " child=" + child + " inst_id=" + instId);
            out.dbg("sql_chars=" + (sql == null ? 0 : sql.length()));
            out.dbg("sql_text_begin");
            out.dbg(previewText(sql, 8000));
            out.dbg("sql_text_end");
            // gv 无采集快照指纹: 仅审计打印, 不做 mismatch 硬失败
            out.println("replay sql_sha256=" + ReplayPackageMeta.sha256Utf8(sql) + " (gv live; no package fingerprint)");
            out.step("load_binds_gv", "sql_id=" + sqlId + " child=" + child);
            List<com.yashan.sqlcollect.model.BindValue> namedBinds =
                    com.yashan.sqlcollect.db.SqlLookup.loadBinds(cLookup, sqlId, child, instId,
                            new com.yashan.sqlcollect.db.SqlLookup.WarnOut() {
                                public void warn(String msg) {
                                    out.println("replay warn " + msg);
                                }
                            });
            if (namedBinds == null || namedBinds.isEmpty()) {
                namedBinds = com.yashan.sqlcollect.db.SqlLookup.loadBindsBySqlId(cLookup, sqlId,
                        new com.yashan.sqlcollect.db.SqlLookup.WarnOut() {
                            public void warn(String msg) {
                                out.println("replay warn " + msg);
                            }
                        });
                if (namedBinds != null && !namedBinds.isEmpty()) {
                    out.println("replay binds fallback loadBindsBySqlId n=" + namedBinds.size());
                }
            }
            com.yashan.sqlcollect.collect.LiteralBindRewrite.Aligned aligned =
                    com.yashan.sqlcollect.collect.LiteralBindRewrite.align(sql, namedBinds);
            for (String w : aligned.warnings) {
                out.println("replay warn bind align: " + w);
            }
            sql = aligned.sql;
            binds = com.yashan.sqlcollect.db.SqlLookup.toReplayRows(aligned.binds);
            out.dbg("bind_align=A placeholders="
                    + com.yashan.sqlcollect.replay.SqlExecutor.countPlaceholders(sql));
            dumpBinds(binds);
            String kind = classifySql(sql);
            out.step("resolve_creds", "schema=" + (schema == null ? "" : schema));
            String[] cred = resolveExecCreds(schema);
            out.dbg("exec_user=" + cred[0] + (schemaViaAlter ? " (alter-session)" : " (map/fallback)"));
            if ("dry".equalsIgnoreCase(mode) || (!force && !"query".equals(kind))) {
                out.println("replay login-user=" + cred[0] + " (planned)");
                beginRow(sqlId, child, instId);
                try {
                    out.step("exec_sql", "dry-or-blocked");
                    boolean okDry = execSql(null, schema, sql, binds, mode, force, null);
                    ReplayResult r = new ReplayResult(okDry ? 1 : 0, okDry ? 0 : 1);
                    out.println("replay summary ok=" + r.ok + " fail=" + r.fail);
                    out.step("replay_gv_done", okDry ? "ok" : "fail");
                    return r;
                } finally {
                    endRow();
                }
            }
        } finally {
            cLookup.close();
            out.dbg("lookup_connection_closed");
        }
        String[] cred = resolveExecCreds(schema);
        out.step("jdbc_connect", cred[0]);
        Connection cExec = connectAs(cred[0], cred[1]);
        boolean okExec;
        beginRow(sqlId, child, instId);
        try {
            out.step("exec_sql", "live");
            okExec = execSql(cExec, schema, sql, binds, mode, force, cred[0]);
        } finally {
            endRow();
            cExec.close();
            out.dbg("jdbc_connection_closed user=" + cred[0]);
        }
        ReplayResult r = new ReplayResult(okExec ? 1 : 0, okExec ? 0 : 1);
        out.println("replay summary ok=" + r.ok + " fail=" + r.fail);
        out.step("replay_gv_done", okExec ? "ok" : "fail");
        return r;
    }

    /** SQL 文本指纹校验; expected 空则仅审计 (legacy).
     *  mismatch 时: shaMismatchFail=true 阻断; false 则 WARN 后仍允许回放. */
    private boolean assertSqlSha256(String sql, String expectedSha, String where) {
        out.step("sha256_check", where);
        String actual = ReplayPackageMeta.sha256Utf8(sql);
        out.println("replay sql_sha256=" + actual + " source=" + where);
        out.dbg("expected_sha256=" + (expectedSha == null ? "" : expectedSha.trim()));
        out.dbg("actual_sha256=" + actual);
        String reason = ReplayPackageMeta.mismatchReason(sql, expectedSha);
        if (reason == null) {
            if (expectedSha != null && !expectedSha.trim().isEmpty()) {
                out.println("replay sql_sha256 ok");
                out.dbg("sha256 match");
            } else {
                out.println("replay warn sql_sha256 missing (" + where
                        + "); skip hard check (legacy package)");
                out.dbg("sha256 skipped (no expected)");
            }
            return true;
        }
        if (shaMismatchFail) {
            out.println("replay fail " + reason + " (" + where + "; on-sha-mismatch=fail)");
            out.dbg("sha256 mismatch fail: " + reason);
            noteFail("sql_sha256 mismatch");
            return false;
        }
        out.println("replay warn " + reason + " (" + where
                + "; on-sha-mismatch=warn; continue replay)");
        out.dbg("sha256 mismatch warn continue: " + reason);
        return true;
    }

    /** debug: 截断过长 SQL 文本 */
    private static String previewText(String text, int maxChars) {
        if (text == null) {
            return "";
        }
        if (text.length() <= maxChars) {
            return text;
        }
        return text.substring(0, maxChars) + "\n... [truncated chars=" + text.length()
                + " shown=" + maxChars + "]";
    }

    /** debug: 逐条输出 bind 位置/类型/值预览 */
    private void dumpBinds(List<String[]> binds) {
        out.dbg("binds_count=" + (binds == null ? 0 : binds.size()));
        if (binds == null || binds.isEmpty()) {
            return;
        }
        out.dbg("binds_begin");
        for (int i = 0; i < binds.size(); i++) {
            String[] b = binds.get(i);
            String pos = b.length > 0 ? b[0] : "";
            String typ = b.length > 1 ? b[1] : "";
            String val = b.length > 2 ? b[2] : "";
            int vc = val == null ? 0 : val.length();
            String vp = previewText(val == null ? "" : val, 500);
            out.dbg("bind[" + i + "] pos=" + pos + " type=" + typ
                    + " value_chars=" + vc + " value=" + vp);
        }
        out.dbg("binds_end");
    }

    private ReplayResult execOne(String schema, String sql, List<String[]> binds, String mode, boolean force)
            throws Exception {
        out.dbg("sql_chars=" + (sql == null ? 0 : sql.length())
                + " schema=" + (schema == null ? "" : schema));
        out.dbg("sql_text_begin");
        out.dbg(previewText(sql, 8000));
        out.dbg("sql_text_end");
        dumpBinds(binds);
        String kind = classifySql(sql);
        out.step("resolve_creds", "schema=" + (schema == null ? "" : schema) + " kind=" + kind);
        String[] cred = resolveExecCreds(schema);
        out.dbg("exec_user=" + cred[0] + (schemaViaAlter ? " (alter-session)" : " (map/fallback)"));
        boolean ok;
        if ("dry".equalsIgnoreCase(mode) || (!force && !"query".equals(kind))) {
            out.println("replay login-user=" + cred[0] + " (planned)");
            out.step("exec_sql", "dry-or-blocked");
            ok = execSql(null, schema, sql, binds, mode, force, null);
        } else {
            out.step("jdbc_connect", cred[0]);
            Connection cExec = connectAs(cred[0], cred[1]);
            try {
                out.step("exec_sql", "live");
                ok = execSql(cExec, schema, sql, binds, mode, force, cred[0]);
            } finally {
                cExec.close();
                out.dbg("jdbc_connection_closed user=" + cred[0]);
            }
        }
        return new ReplayResult(ok ? 1 : 0, ok ? 0 : 1);
    }

    private List<String[]> loadGvBinds(Connection c, String sqlId, int child, int instId) {
        return com.yashan.sqlcollect.db.SqlLookup.toReplayRows(
                com.yashan.sqlcollect.db.SqlLookup.loadBinds(c, sqlId, child, instId,
                        new com.yashan.sqlcollect.db.SqlLookup.WarnOut() {
                            public void warn(String msg) {
                                out.println("replay warn " + msg);
                            }
                        }));
    }

    private Connection connectAs(String user, String pass) throws SQLException {
        out.println("replay login-user=" + user);
        out.dbg("jdbc_borrow url=" + jdbcUrl + " user=" + user);
        long t0 = System.currentTimeMillis();
        try {
            Connection c = pool.borrow(jdbcUrl, user, pass);
            out.dbg("jdbc_borrow ok ms=" + (System.currentTimeMillis() - t0));
            return c;
        } catch (SQLException e) {
            out.dbg("jdbc_borrow fail ms=" + (System.currentTimeMillis() - t0)
                    + " err=" + e.getMessage());
            throw e;
        }
    }

    String[] resolveExecCreds(String schema) {
        if (schemaViaAlter) {
            out.println("replay login-mode=alter-session user=" + lookupUser);
            out.dbg("creds via alter-session login=" + lookupUser
                    + " target_schema=" + (schema == null ? "" : schema));
            return new String[] {lookupUser, lookupPass};
        }
        if (schema != null && !schema.isEmpty() && !"NULL".equalsIgnoreCase(schema)) {
            String key = schema.toUpperCase(Locale.ROOT);
            if (maps.containsKey(key)) {
                String[] c = maps.get(key);
                out.println("replay map-hit schema=" + key + " user=" + c[0]);
                out.dbg("creds map-hit schema=" + key + " user=" + c[0]);
                return c;
            }
            out.println("replay warn no [map." + key + "] in ini; try schema user + default password");
            out.dbg("creds fallback schema-as-user=" + schema);
            return new String[] {schema, lookupPass};
        }
        out.println("replay warn empty parsing_schema; fallback lookup user");
        out.dbg("creds fallback lookup_user=" + lookupUser);
        return new String[] {lookupUser, lookupPass};
    }

    private boolean execSql(Connection c, String schema, String sql, List<String[]> binds,
                            String mode, boolean force, String loginUser) throws Exception {
        long t0 = System.currentTimeMillis();
        out.println("replay sql-chars=" + (sql == null ? 0 : sql.length()));
        out.println("replay binds=" + binds.size());
        out.println("replay schema=" + (schema == null ? "" : schema));
        String kind = classifySql(sql);
        out.println("replay sql-kind=" + kind);
        out.dbg("exec mode=" + mode + " force=" + force + " loginUser="
                + (loginUser == null ? "" : loginUser) + " has_connection=" + (c != null));
        int empty = 0;
        for (String[] b : binds) {
            if (b[2] == null || b[2].isEmpty()) {
                empty++;
            }
        }
        if (empty > 0) {
            out.println("replay warn empty_bind_values=" + empty);
        }
        if (!force && !"query".equals(kind)) {
            out.println("replay blocked kind=" + kind + " (query-only; pass --force to allow)");
            if ("dry".equalsIgnoreCase(mode)) {
                if (schema != null && !schema.isEmpty() && !"NULL".equalsIgnoreCase(schema)) {
                    out.println("replay schema-set=" + schema + " (planned alter-session)");
                    out.dbg("planned: ALTER SESSION SET CURRENT_SCHEMA = \"" + schema + "\"");
                }
                out.println("replay dry-run-ok");
                noteOkDetail("kind=" + kind + " dry blocked");
                recordResult(schema, kind, 0, System.currentTimeMillis() - t0, "dry", "blocked_dry");
                return true;
            }
            out.println("replay fail blocked non-query without --force");
            noteFail("blocked kind=" + kind + " (need --force)");
            recordResult(schema, kind, 1, System.currentTimeMillis() - t0, "", "blocked");
            return false;
        }
        if ("dry".equalsIgnoreCase(mode)) {
            if (schema != null && !schema.isEmpty() && !"NULL".equalsIgnoreCase(schema)
                    && (loginUser == null || !loginUser.equalsIgnoreCase(schema))) {
                out.println("replay schema-set=" + schema + " (planned alter-session)");
                out.dbg("planned: ALTER SESSION SET CURRENT_SCHEMA = \"" + schema + "\"");
            } else if (schema != null && loginUser != null && loginUser.equalsIgnoreCase(schema)) {
                out.dbg("schema-skip planned same_as_login=" + schema);
            }
            out.println("replay dry-run-ok");
            noteOkDetail("kind=" + kind + " dry");
            recordResult(schema, kind, 0, System.currentTimeMillis() - t0, "dry", "");
            return true;
        }
        if (schema != null && !schema.isEmpty() && !"NULL".equalsIgnoreCase(schema)) {
            String login = loginUser;
            if ((login == null || login.isEmpty()) && c != null) {
                try {
                    login = c.getMetaData().getUserName();
                } catch (Exception ignored) {
                }
            }
            if (login != null && login.equalsIgnoreCase(schema)) {
                out.println("replay schema-skip same_as_login=" + schema);
                out.dbg("skip ALTER SESSION; login already " + login);
            } else {
                String alterSql = "ALTER SESSION SET CURRENT_SCHEMA = \""
                        + schema.replace("\"", "\"\"") + "\"";
                out.step("alter_session", schema);
                out.dbg("jdbc sql [alter_session]: " + alterSql);
                long a0 = System.currentTimeMillis();
                try (Statement st = c.createStatement()) {
                    applyQueryTimeout(st);
                    st.execute(alterSql);
                    out.println("replay schema-set=" + schema);
                    out.dbg("alter_session ok ms=" + (System.currentTimeMillis() - a0));
                } catch (Exception e) {
                    out.println("replay warn set_schema " + e.getMessage());
                    out.println("replay fail set_schema failed for " + schema);
                    out.dbg("alter_session fail ms=" + (System.currentTimeMillis() - a0)
                            + " err=" + e.getMessage());
                    noteFail("set_schema failed: " + e.getMessage());
                    recordResult(schema, kind, 1, System.currentTimeMillis() - t0, "", "set_schema");
                    return false;
                }
            }
        }
        out.step("jdbc_prepare_execute", kind);
        out.dbg("jdbc prepare sql_chars=" + (sql == null ? 0 : sql.length())
                + " binds=" + binds.size() + " query_timeout_sec=" + queryTimeoutSec);
        long e0 = System.currentTimeMillis();
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            applyQueryTimeout(ps);
            for (String[] b : binds) {
                int pos;
                try {
                    pos = Integer.parseInt(b[0].trim());
                } catch (NumberFormatException e) {
                    out.println("replay warn skip bad bind position: " + b[0]);
                    continue;
                }
                out.dbg("jdbc bind set pos=" + pos + " type=" + b[1]
                        + " value_chars=" + (b[2] == null ? 0 : b[2].length()));
                bindOne(ps, pos, b[1], b[2]);
            }
            boolean hasRs = ps.execute();
            out.dbg("jdbc execute hasResultSet=" + hasRs
                    + " ms=" + (System.currentTimeMillis() - e0));
            String rowsOrUc;
            String metric;
            long elapsed = System.currentTimeMillis() - t0;
            if (hasRs) {
                try (ResultSet rs = ps.getResultSet()) {
                    int cols = rs.getMetaData().getColumnCount();
                    int rows = 0;
                    while (rs.next() && rows < 20) {
                        StringBuilder sb = new StringBuilder();
                        for (int i = 1; i <= cols; i++) {
                            if (i > 1) {
                                sb.append("|");
                            }
                            sb.append(rs.getString(i));
                        }
                        out.println("replay row " + sb.toString());
                        rows++;
                    }
                    out.println("replay rows-shown=" + rows);
                    rowsOrUc = String.valueOf(rows);
                    metric = "rows=" + rows;
                }
            } else {
                int uc = ps.getUpdateCount();
                out.println("replay update-count=" + uc);
                rowsOrUc = String.valueOf(uc);
                metric = "update-count=" + uc;
            }
            out.println("replay exec-ok");
            out.dbg("exec_ok kind=" + kind + " result=" + rowsOrUc
                    + " total_ms=" + elapsed);
            noteOkDetail("kind=" + kind + " " + metric + " ms=" + elapsed);
            recordResult(schema, kind, 0, elapsed, rowsOrUc, "");
            return true;
        } catch (Exception e) {
            String em = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
            out.println("replay fail " + em);
            out.dbg("jdbc_execute fail ms=" + (System.currentTimeMillis() - e0)
                    + " err=" + em);
            noteFail(em);
            recordResult(schema, kind, 1, System.currentTimeMillis() - t0, "",
                    e.getClass().getSimpleName());
            throw e;
        }
    }

    private void recordResult(String schema, String kind, int rc, long elapsedMs,
                              String rowsOrUc, String errorClass) {
        if (resultCsv == null) {
            return;
        }
        RowCtx ctx = rowCtx.get();
        String sid = ctx == null ? "" : ctx.sqlId;
        int child = ctx == null ? 0 : ctx.child;
        int instId = ctx == null ? 0 : ctx.instId;
        resultCsv.append(sid, child, instId, schema, kind, rc, elapsedMs, rowsOrUc, errorClass);
    }

    public static class ReplayResult {
        public final int ok;
        public final int fail;

        public ReplayResult(int ok, int fail) {
            this.ok = ok;
            this.fail = fail;
        }

        public boolean success() {
            return fail == 0;
        }
    }

    private static void bindOne(PreparedStatement ps, int idx, String dt, String val) throws SQLException {
        SqlExecutor.bindOne(ps, idx, dt, val);
    }

    static String classifySql(String sql) {
        return SqlExecutor.classifySql(sql);
    }

    /** 引号感知剥离行注释; 供 classifySql 使用 (不影响实际执行文本) */
    static String stripSqlLead(String sql) {
        return SqlExecutor.stripSqlLead(sql);
    }

    private static List<String[]> readBinds(String path) throws IOException {
        List<String[]> out = new ArrayList<String[]>();
        if (path == null || path.isEmpty() || !Files.exists(Paths.get(path))) {
            return out;
        }
        for (String ln : readFile(path).split("\n", -1)) {
            if (ln.isEmpty() || ln.startsWith("#")) {
                continue;
            }
            String[] p = PipeEscape.split(ln, 3);
            if (p.length < 1) {
                continue;
            }
            String pos = p[0].trim();
            if (!pos.matches("\\d+")) {
                System.err.println("WARN: skip binds.txt line (bad position): " + ln);
                continue;
            }
            out.add(new String[] {
                pos,
                p.length > 1 ? p[1].trim() : "VARCHAR2",
                p.length > 2 ? p[2] : ""
            });
        }
        return out;
    }

    private static String readFile(String path) throws IOException {
        byte[] b = Files.readAllBytes(Paths.get(path));
        return new String(b, StandardCharsets.UTF_8);
    }
}
