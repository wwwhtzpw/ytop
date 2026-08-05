package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.db.CursorSnapshot;
import com.yashan.sqlcollect.db.HtzTables;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.db.SqlDataSource;
import com.yashan.sqlcollect.log.DualLogger;
import com.yashan.sqlcollect.model.BindValue;
import com.yashan.sqlcollect.model.ReplayPackageMeta;
import com.yashan.sqlcollect.util.JsonBinds;
import com.yashan.sqlcollect.util.PipeEscape;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * 导出 replay 包并/或 upsert 登录用户下的 HTZ_SQL_REPLAY_PKG.
 * 游标与 bind 一律经 {@link SqlDataSource} (live 或 HTZ), 不在本类直查 gv$/v$sql*.
 * HTZ 表操作失败直接抛错, 由 collect 退出.
 *
 * <p>Task 6 sink 矩阵 (本类只暴露开关; 由 CollectCommand 传入):
 * <pre>
 * sink | -X (skip-replay-export) | writeHtzPkg | writeFiles
 * -----|-------------------------|------------|-----------
 * file | no                      | false      | true
 * file | yes                     | false      | false
 * table| —                       | true       | false
 * both | no                      | true       | true
 * both | yes                     | false      | false
 * </pre>
 * 即: file 永远 writeHtzPkg=false, writeFiles=!skipX;
 * table 永远 writeHtzPkg=true, writeFiles=false;
 * both: writeHtzPkg=!skipX, writeFiles=!skipX.
 */
public class PackageExporter {

    public static final String REPLAY_DIR = "replay";

    private final DualLogger log;
    private final String owner;

    public PackageExporter(DualLogger log, String jdbcUser) {
        this.log = log;
        this.owner = HtzTables.normalizeOwner(jdbcUser);
    }

    /**
     * 按开关导出 replay 目录文件与/或 upsert HTZ_SQL_REPLAY_PKG.
     *
     * @param src          游标/bind 数据源 (live 或 HTZ)
     * @param writeFiles   false 时不写 replay/ 目录
     * @param writeHtzPkg  false 时不碰 HTZ_SQL_REPLAY_PKG
     * @return 包目录路径 (即使未落盘也会返回约定路径); sql 不在 src 时返回 null;
     *         writeFiles 与 writeHtzPkg 均为 false 时返回 null
     */
    public Path export(JdbcSession session, String sqlId, Path outdir, String kind,
                       SqlDataSource src, boolean writeFiles, boolean writeHtzPkg)
            throws SQLException {
        if (!writeFiles && !writeHtzPkg) {
            log.logDbg("replay export skipped (writeFiles=false writeHtzPkg=false) sql_id=" + sqlId);
            return null;
        }
        if (src == null) {
            throw new SQLException("SqlDataSource is null for export sql_id=" + sqlId);
        }
        log.logStep("replay_export", sqlId + " kind=" + kind + " owner=" + owner
                + " writeFiles=" + writeFiles + " writeHtzPkg=" + writeHtzPkg);
        Row row = loadFromSource(session.getConnection(), sqlId, src);
        if (row == null) {
            log.logWarn("replay export: sql_id not found in data source: " + sqlId);
            return null;
        }
        Path pkg = packagePath(outdir, row);
        if (writeFiles) {
            try {
                pkg = writeFiles(outdir, row);
            } catch (IOException e) {
                log.logError("write replay package failed for " + sqlId + ": " + e.getMessage());
                throw new SQLException("write replay package failed for " + sqlId, e);
            }
        }
        if (writeHtzPkg) {
            ensureReplayTable(session.getConnection());
            ensureSqlSha256Column(session.getConnection());
            upsertHtz(session.getConnection(), row);
        }

        String tag = "REFRESH".equalsIgnoreCase(kind) ? "refresh" : "new";
        log.logDbg(String.format("%s export sql_id=%s child=%d inst_id=%d len=%d binds=%d -> %s"
                        + " (files=%s htz=%s)",
                tag, sqlId, row.meta.childNumber, row.meta.instId, row.meta.sqlLen, row.binds.size(),
                pkg, Boolean.toString(writeFiles), Boolean.toString(writeHtzPkg)));
        int empty = 0;
        for (BindValue b : row.binds) {
            if (b.value == null || b.value.isEmpty() || "\\N".equals(b.value)) {
                empty++;
            }
        }
        if (empty > 0) {
            log.logWarn(empty + " bind(s) have empty value_string; sql_id=" + sqlId
                    + " child=" + row.meta.childNumber
                    + " edit binds.txt before execute");
        }
        return pkg;
    }

    private static class Row {
        ReplayPackageMeta meta = new ReplayPackageMeta();
        String sqlText = "";
        List<BindValue> binds = new ArrayList<BindValue>();
    }

    /** 经 SqlDataSource 取游标与 bind, 不再直查 gv$/v$. */
    private Row loadFromSource(Connection c, String sqlId, SqlDataSource src) throws SQLException {
        CursorSnapshot snap = src.pickCursor(c, sqlId);
        if (snap == null || snap.sqlText == null || snap.sqlText.isEmpty()) {
            return null;
        }
        Row row = new Row();
        row.meta.sqlId = sqlId;
        row.meta.childNumber = snap.childNumber;
        row.meta.parsingSchema = snap.schema == null ? "" : snap.schema;
        row.meta.instId = snap.instId <= 0 ? 1 : snap.instId;
        row.meta.hashValue = snap.hashValue;
        row.meta.sqlLen = snap.sqlLen > 0 ? snap.sqlLen : snap.sqlText.length();
        row.sqlText = snap.sqlText;
        row.binds = src.loadBinds(c, sqlId, row.meta.childNumber, row.meta.instId);
        if (row.binds == null) {
            row.binds = new ArrayList<BindValue>();
        }
        int filled = countFilled(row.binds);
        log.logInfo("export cursor sql_id=" + sqlId + " child=" + row.meta.childNumber
                + " inst_id=" + row.meta.instId + " binds=" + row.binds.size()
                + " filled=" + filled + " pick=datasource:" + src.getClass().getSimpleName());
        return row;
    }

    private static Path packagePath(Path outdir, Row row) {
        return outdir.resolve(REPLAY_DIR).resolve(
                row.meta.sqlId + "__c" + row.meta.childNumber + "__i" + row.meta.instId);
    }

    private static int countFilled(List<BindValue> binds) {
        int filled = 0;
        if (binds == null) {
            return 0;
        }
        for (BindValue b : binds) {
            if (b.value != null && !b.value.isEmpty() && !"\\N".equals(b.value)) {
                filled++;
            }
        }
        return filled;
    }

    private void ensureReplayTable(Connection c) throws SQLException {
        String qn = HtzTables.qname(owner, HtzTables.REPLAY_PKG);
        if (HtzTables.tableExists(c, owner, HtzTables.REPLAY_PKG)) {
            if (pkIncludesInstId(c)) {
                log.logDbg("TABLE " + qn + " exists");
                return;
            }
            // 工具缓存表: 旧 PK 无 INST_ID 时自动重建 (数据可从 replay 目录重导出)
            log.logWarn("TABLE " + qn
                    + " PK missing INST_ID; dropping and recreating with RAC-safe key");
            HtzTables.exec(c, log, "drop_" + HtzTables.REPLAY_PKG, "DROP TABLE " + qn);
        }
        log.logInfo("TABLE " + qn + " creating");
        // DDL 隐式 commit: 须在本连接任何未提交 DML 之前执行 (不变式)
        String who = HtzTables.currentUser(c);
        String ddlBody = "("
                + "SQL_ID VARCHAR2(13) NOT NULL, "
                + "CHILD_NUMBER NUMBER NOT NULL, "
                + "INST_ID NUMBER NOT NULL, "
                + "HASH_VALUE NUMBER, "
                + "PARSING_SCHEMA VARCHAR2(128), "
                + "SQL_FULLTEXT CLOB, "
                + "BINDS_JSON CLOB, "
                + "SQL_LEN NUMBER, "
                + "SQL_SHA256 VARCHAR2(64), "
                + "COLLECT_TIME DATE, "
                + "CONSTRAINT PK_HTZ_SQL_REPLAY_PKG PRIMARY KEY (SQL_ID, CHILD_NUMBER, INST_ID))";
        if (!who.equalsIgnoreCase(owner)) {
            HtzTables.exec(c, log, "create_" + HtzTables.REPLAY_PKG,
                    "CREATE TABLE " + qn + " " + ddlBody);
        } else {
            HtzTables.exec(c, log, "create_" + HtzTables.REPLAY_PKG,
                    "CREATE TABLE " + HtzTables.REPLAY_PKG + " " + ddlBody);
        }
        log.logInfo("TABLE " + qn + " created");
    }

    /** 旧表 PK 无 INST_ID 时拒绝继续写入, 避免 RAC 静默覆盖 */
    private boolean pkIncludesInstId(Connection c) throws SQLException {
        String sql = "SELECT COUNT(*) FROM user_cons_columns cc "
                + "JOIN user_constraints c ON c.constraint_name = cc.constraint_name "
                + "WHERE c.table_name = ? AND c.constraint_type = 'P' AND cc.column_name = 'INST_ID'";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, HtzTables.REPLAY_PKG);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                return rs.getInt(1) > 0;
            }
        } catch (SQLException e) {
            log.logWarn("cannot verify " + HtzTables.REPLAY_PKG + " PK columns: " + e.getMessage());
            return true;
        }
    }

    /** 旧表补 SQL_SHA256 列 (SQL Map 一致性指纹) */
    private void ensureSqlSha256Column(Connection c) throws SQLException {
        String qn = HtzTables.qname(owner, HtzTables.REPLAY_PKG);
        if (!HtzTables.tableExists(c, owner, HtzTables.REPLAY_PKG)) {
            return;
        }
        if (columnExists(c, HtzTables.REPLAY_PKG, "SQL_SHA256")) {
            return;
        }
        log.logInfo("TABLE " + qn + " adding column SQL_SHA256");
        HtzTables.exec(c, log, "alter_add_sql_sha256",
                "ALTER TABLE " + qn + " ADD SQL_SHA256 VARCHAR2(64)");
    }

    private boolean columnExists(Connection c, String table, String column) throws SQLException {
        String sql = "SELECT COUNT(*) FROM user_tab_columns WHERE table_name = ? AND column_name = ?";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, table);
            ps.setString(2, column);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                return rs.getInt(1) > 0;
            }
        } catch (SQLException e) {
            log.logWarn("cannot verify column " + table + "." + column + ": " + e.getMessage());
            return false;
        }
    }

    private void upsertHtz(Connection c, Row row) throws SQLException {
        String qn = HtzTables.qname(owner, HtzTables.REPLAY_PKG);
        String json = JsonBinds.write(row.binds);
        String sha = ReplayPackageMeta.sha256Utf8(row.sqlText);
        row.meta.sqlSha256 = sha;
        log.logDbg("jdbc upsert " + qn + " sql_id=" + row.meta.sqlId
                + " child=" + row.meta.childNumber + " inst_id=" + row.meta.instId
                + " sql_sha256=" + sha);
        // 逐步 commit: 单 sql_id 的 DELETE+INSERT 原子; 不保证整轮可 rollback
        try (PreparedStatement del = c.prepareStatement(
                "DELETE FROM " + qn + " WHERE sql_id = ? AND child_number = ? AND inst_id = ?")) {
            del.setString(1, row.meta.sqlId);
            del.setInt(2, row.meta.childNumber);
            del.setInt(3, row.meta.instId);
            int dn = del.executeUpdate();
            log.logDbg("jdbc delete " + qn + " rows=" + dn);
        }

        try (PreparedStatement ins = c.prepareStatement(
                "INSERT INTO " + qn + " "
                        + "(sql_id, child_number, inst_id, hash_value, parsing_schema, "
                        + "sql_fulltext, binds_json, sql_len, sql_sha256, collect_time) "
                        + "VALUES (?,?,?,?,?,?,?,?,?,SYSDATE)")) {
            ins.setString(1, row.meta.sqlId);
            ins.setInt(2, row.meta.childNumber);
            ins.setInt(3, row.meta.instId);
            ins.setLong(4, row.meta.hashValue);
            ins.setString(5, row.meta.parsingSchema);
            ins.setString(6, row.sqlText);
            ins.setString(7, json);
            ins.setInt(8, row.meta.sqlLen);
            ins.setString(9, sha);
            ins.executeUpdate();
        }
        c.commit();
        log.logDbg("jdbc insert " + qn + " ok");
    }

    private Path writeFiles(Path outdir, Row row) throws IOException {
        Path pkg = packagePath(outdir, row);
        Files.createDirectories(pkg);
        String sha = ReplayPackageMeta.sha256Utf8(row.sqlText);
        row.meta.sqlSha256 = sha;
        String meta = "sql_id=" + row.meta.sqlId + "\n"
                + "child_number=" + row.meta.childNumber + "\n"
                + "inst_id=" + row.meta.instId + "\n"
                + "hash_value=" + row.meta.hashValue + "\n"
                + "parsing_schema=" + row.meta.parsingSchema + "\n"
                + "sql_len=" + row.meta.sqlLen + "\n"
                + ReplayPackageMeta.META_SQL_SHA256 + "=" + sha + "\n";
        Files.write(pkg.resolve("meta.txt"), meta.getBytes(StandardCharsets.UTF_8));
        Files.write(pkg.resolve("orig.sql"), row.sqlText.getBytes(StandardCharsets.UTF_8));
        // 落盘后立刻回读校验, 防止编码/截断导致与业务 sql_fulltext 不一致
        byte[] written = Files.readAllBytes(pkg.resolve("orig.sql"));
        String roundTrip = new String(written, StandardCharsets.UTF_8);
        if (!row.sqlText.equals(roundTrip)) {
            throw new IOException("orig.sql round-trip mismatch for sql_id=" + row.meta.sqlId
                    + " (in_chars=" + row.sqlText.length() + " out_chars=" + roundTrip.length() + ")");
        }
        String writtenSha = ReplayPackageMeta.sha256Utf8(roundTrip);
        if (!sha.equals(writtenSha)) {
            throw new IOException("orig.sql sha256 mismatch after write for sql_id=" + row.meta.sqlId
                    + " expected=" + sha + " actual=" + writtenSha);
        }
        String json = JsonBinds.write(row.binds);
        Files.write(pkg.resolve("binds.json"), (json + "\n").getBytes(StandardCharsets.UTF_8));
        StringBuilder bt = new StringBuilder("# position|datatype|value\n");
        for (BindValue b : row.binds) {
            bt.append(b.position).append("|")
                    .append(PipeEscape.escape(b.datatype)).append("|")
                    .append(PipeEscape.escape(b.value)).append("\n");
        }
        Files.write(pkg.resolve("binds.txt"), bt.toString().getBytes(StandardCharsets.UTF_8));
        log.logDbg("sql_sha256=" + sha + " sql_id=" + row.meta.sqlId);
        log.logDbg("wrote package files " + pkg);
        return pkg;
    }
}
