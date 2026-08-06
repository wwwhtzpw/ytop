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
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * 导出 replay/ 目录文件包.
 * 游标与 bind 一律经 {@link SqlDataSource} (live 或 HTZ), 不在本类直查 gv$/v$sql*.
 *
 * <p>writeFiles 由 CollectCommand.writeFiles 决定 (backup=false; 其余=!skipX).
 * <pre>
 * sink   | -X | writeFiles
 * -------|----|----------------
 * file   | no | true
 * file   | yes| false
 * table  | no | true
 * table  | yes| false
 * both   | no | true
 * both   | yes| false
 * backup | —  | false (collect 不调用 export)
 * </pre>
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
     * 导出 replay 目录文件.
     *
     * @param src        游标/bind 数据源 (live 或 HTZ)
     * @param writeFiles false 时不写 replay/ 目录
     * @return 包目录路径; sql 不在 src 或 writeFiles=false 时返回 null
     */
    public Path export(JdbcSession session, String sqlId, Path outdir, String kind,
                       SqlDataSource src, boolean writeFiles)
            throws SQLException {
        if (!writeFiles) {
            log.logDbg("replay export skipped (writeFiles=false) sql_id=" + sqlId);
            return null;
        }
        if (src == null) {
            throw new SQLException("SqlDataSource is null for export sql_id=" + sqlId);
        }
        log.logStep("replay_export", sqlId + " kind=" + kind + " owner=" + owner
                + " writeFiles=" + writeFiles);
        Row row = loadFromSource(session.getConnection(), sqlId, src);
        if (row == null) {
            log.logWarn("replay export: sql_id not found in data source: " + sqlId);
            return null;
        }
        Path pkg;
        try {
            pkg = writeFiles(outdir, row);
        } catch (IOException e) {
            log.logError("write replay package failed for " + sqlId + ": " + e.getMessage());
            throw new SQLException("write replay package failed for " + sqlId, e);
        }

        String tag = "REFRESH".equalsIgnoreCase(kind) ? "refresh" : "new";
        log.logDbg(String.format("%s export sql_id=%s child=%d inst_id=%d len=%d binds=%d -> %s",
                tag, sqlId, row.meta.childNumber, row.meta.instId, row.meta.sqlLen, row.binds.size(),
                pkg));
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
        // 方案 A: peep 混合 ?/:SYS_B_* 时按 LTR 对齐并改写全 ?, 供 JDBC replay
        LiteralBindRewrite.Aligned aligned = LiteralBindRewrite.align(row.sqlText, row.binds);
        if (!aligned.warnings.isEmpty()) {
            for (String w : aligned.warnings) {
                log.logWarn("bind align: " + w + "; sql_id=" + sqlId);
            }
        }
        if (aligned.binds != null && !aligned.binds.isEmpty()) {
            row.sqlText = aligned.sql;
            row.binds = aligned.binds;
            row.meta.sqlLen = row.sqlText.length();
        }
        int filled = countFilled(row.binds);
        log.logInfo("export cursor sql_id=" + sqlId + " child=" + row.meta.childNumber
                + " inst_id=" + row.meta.instId + " binds=" + row.binds.size()
                + " filled=" + filled + " pick=datasource:" + src.getClass().getSimpleName()
                + " bind_align=A");
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
