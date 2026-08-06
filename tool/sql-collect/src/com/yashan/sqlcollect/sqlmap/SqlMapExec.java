package com.yashan.sqlcollect.sqlmap;

import com.yashan.sqlcollect.collect.LiteralBindRewrite;
import com.yashan.sqlcollect.config.JdbcConfig;
import com.yashan.sqlcollect.db.JdbcPool;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.db.SqlLookup;
import com.yashan.sqlcollect.log.DualLogger;
import com.yashan.sqlcollect.model.BindValue;
import com.yashan.sqlcollect.replay.SqlExecutor;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.List;

/** genexec / perf */
public final class SqlMapExec {

    private SqlMapExec() {
    }

    public static int genexec(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                Connection c = sess.getConnection();
                String sql;
                String schema = cfg.currentSchema;
                String tgtId = a.opt("tgt-sql-id", null);
                if (tgtId != null && !tgtId.trim().isEmpty()) {
                    SqlLookup.SqlTextInfo info = SqlLookup.loadSqlText(c, tgtId.trim(),
                            SqlMapIo.warn(log));
                    if (!info.found) {
                        log.logError("target sql_id not found: " + tgtId);
                        return 1;
                    }
                    sql = info.sqlText;
                    if (schema == null || schema.isEmpty()) {
                        schema = info.schema;
                    }
                } else {
                    sql = SqlMapIo.readFile(a.opt("sql-file", ""));
                }
                String marker = a.opt("marker", null);
                if (marker != null && !marker.isEmpty()) {
                    sql = sql + "\n/* " + marker + " */";
                }
                List<String[]> binds = resolveBinds(c, a, log);
                AlignPair ap = alignForExec(c, a, sql, binds, log);
                sql = ap.sql;
                binds = ap.binds;
                int ph = SqlExecutor.countPlaceholders(sql);
                log.logInfo("genexec placeholders=" + ph + " binds=" + binds.size()
                        + " kind=" + SqlExecutor.classifySql(sql)
                        + " exec=" + a.resolveExec() + " bind_align=" + ap.mode);
                if (ph > 0 && binds.size() < ph) {
                    log.logError("bind count " + binds.size() + " < placeholders " + ph
                            + "; provide -b or -s for genbind");
                    return 1;
                }
                boolean dry = !a.resolveExec();
                SqlExecutor.LineOut out = new SqlExecutor.LineOut() {
                    public void println(String line) {
                        log.logInfo(line);
                    }
                };
                SqlExecutor.ExecResult r = SqlExecutor.execute(
                        dry ? null : c, schema, sql, binds, dry, true,
                        cfg.user, 0, false, 20, out);
                String outPath = a.opt("out", null);
                if (outPath != null && !outPath.isEmpty()) {
                    StringBuilder sb = new StringBuilder();
                    sb.append("-- genexec summary dry=").append(dry).append('\n');
                    sb.append("-- kind=").append(r.kind).append(" ok=").append(r.ok)
                            .append(" elapsed_ms=").append(r.elapsedMs).append('\n');
                    sb.append(sql);
                    Files.write(Paths.get(outPath), sb.toString().getBytes(StandardCharsets.UTF_8));
                }
                if (!r.ok) {
                    log.logError("genexec failed: " + r.error);
                    return 1;
                }
                System.out.println("[OK] genexec " + (dry ? "dry-run" : "exec")
                        + " elapsed_ms=" + r.elapsedMs);
                return 0;
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("genexec failed: " + e.getMessage());
            return 1;
        }
    }

    public static int perf(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                Connection c = sess.getConnection();
                String srcId = a.opt("src-sql-id", "").trim();
                SqlLookup.SqlTextInfo srcInfo = SqlLookup.loadSqlText(c, srcId, SqlMapIo.warn(log));
                if (!srcInfo.found) {
                    log.logError("source sql_id not found: " + srcId);
                    return 1;
                }
                SqlMapDdl.Resolved tgt = SqlMapDdl.resolveSide(c, a, false, log);
                if (tgt.error != null) {
                    log.logError(tgt.error);
                    return 1;
                }
                List<String[]> binds = resolveBinds(c, a, log);
                if (binds.isEmpty()) {
                    binds = SqlLookup.toReplayRows(
                            SqlLookup.loadBindsBySqlId(c, srcId, SqlMapIo.warn(log)));
                }
                AlignPair srcAp = alignForExec(c, a, srcInfo.sqlText, binds, log);
                String srcSql = srcAp.sql;
                binds = srcAp.binds;
                boolean dry = !a.resolveExec();
                SqlExecutor.LineOut out = new SqlExecutor.LineOut() {
                    public void println(String line) {
                        log.logInfo(line);
                    }
                };
                String schema = cfg.currentSchema;
                if (schema == null || schema.isEmpty()) {
                    schema = srcInfo.schema;
                }
                SqlExecutor.ExecResult srcR = SqlExecutor.execute(
                        dry ? null : c, schema, srcSql, binds, dry, true,
                        cfg.user, 0, false, 5, out);
                String marker = a.opt("marker", null);
                String tgtSql = tgt.text;
                if (marker != null && !marker.isEmpty() && !tgtSql.contains("/*")) {
                    tgtSql = tgtSql + "\n/* " + marker + " */";
                }
                // 目标侧仅改写占位为 ? (绑定已按源 LTR 对齐)
                tgtSql = LiteralBindRewrite.toQuestionMarks(tgtSql);
                SqlExecutor.ExecResult tgtR = SqlExecutor.execute(
                        dry ? null : c, schema, tgtSql, binds, dry, true,
                        cfg.user, 0, false, 5, out);

                SqlMapVerify.SqlStats srcSt = SqlMapVerify.lookupSqlStats(
                        c, srcId, srcInfo.sqlText, null, log);
                SqlMapVerify.SqlStats tgtSt = SqlMapVerify.lookupSqlStats(
                        c, tgt.sqlId, tgtSql, marker, log);

                StringBuilder summary = new StringBuilder();
                summary.append("perf dry=").append(dry).append('\n');
                summary.append(String.format(java.util.Locale.ROOT,
                        "src elapsed_ms=%d plan_hash=%s buffer_gets=%s executions=%s sql_id=%s%n",
                        Long.valueOf(srcR.elapsedMs),
                        srcSt == null ? "-" : String.valueOf(srcSt.planHash),
                        srcSt == null || srcSt.bufferGets == null ? "-" : String.valueOf(srcSt.bufferGets),
                        srcSt == null || srcSt.executions == null ? "-" : String.valueOf(srcSt.executions),
                        srcId));
                summary.append(String.format(java.util.Locale.ROOT,
                        "tgt elapsed_ms=%d plan_hash=%s buffer_gets=%s executions=%s sql_id=%s%n",
                        Long.valueOf(tgtR.elapsedMs),
                        tgtSt == null ? "-" : String.valueOf(tgtSt.planHash),
                        tgtSt == null || tgtSt.bufferGets == null ? "-" : String.valueOf(tgtSt.bufferGets),
                        tgtSt == null || tgtSt.executions == null ? "-" : String.valueOf(tgtSt.executions),
                        tgt.sqlId == null || tgt.sqlId.isEmpty()
                                ? (tgtSt == null ? "-" : tgtSt.sqlId) : tgt.sqlId));
                System.out.print(summary.toString());
                log.logInfo(summary.toString().trim().replace('\n', ' '));

                String outPath = a.opt("out", null);
                if (outPath != null && !outPath.isEmpty()) {
                    Files.write(Paths.get(outPath), summary.toString().getBytes(StandardCharsets.UTF_8));
                }
                if (!srcR.ok || !tgtR.ok) {
                    return 1;
                }
                System.out.println("[OK] perf done");
                return 0;
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("perf failed: " + e.getMessage());
            return 1;
        }
    }

    static List<String[]> resolveBinds(Connection c, SqlMapArgs a, DualLogger log) throws Exception {
        String bf = a.opt("bind-file", null);
        if (bf != null && !bf.isEmpty()) {
            String kw = a.bindSourceKeyword();
            if (kw != null) {
                String sid = a.opt("src-sql-id", null);
                if (sid == null || sid.trim().isEmpty()) {
                    log.logError("-b " + kw + " requires -s/--src-sql-id");
                    return new ArrayList<String[]>();
                }
                SqlLookup.BindSource src = "backup".equals(kw)
                        ? SqlLookup.BindSource.BACKUP : SqlLookup.BindSource.VIEW;
                log.logInfo("bind_source=" + kw + " sql_id=" + sid.trim());
                return SqlLookup.toReplayRows(
                        SqlLookup.loadBindsBySqlId(c, sid.trim(), src, SqlMapIo.warn(log)));
            }
            return SqlMapIo.readValueLines(bf);
        }
        String srcId = a.opt("src-sql-id", null);
        if (srcId != null && !srcId.trim().isEmpty()) {
            log.logInfo("bind_source=auto sql_id=" + srcId.trim());
            return SqlLookup.toReplayRows(
                    SqlLookup.loadBindsBySqlId(c, srcId.trim(), SqlMapIo.warn(log)));
        }
        return new ArrayList<String[]>();
    }

    /** 执行前对齐结果. */
    static final class AlignPair {
        String sql;
        List<String[]> binds;
        String mode = "none";
    }

    /**
     * 有命名 capture (via -b view/backup/auto 且仍带 peep 文本) 时走方案 A;
     * 仅值文件时只把 :name 改写为 ? (假定 genbind 已 LTR).
     */
    static AlignPair alignForExec(Connection c, SqlMapArgs a, String sql, List<String[]> binds,
                                  DualLogger log) {
        AlignPair ap = new AlignPair();
        ap.sql = sql == null ? "" : sql;
        ap.binds = binds == null ? new ArrayList<String[]>() : binds;
        if (ap.sql.isEmpty() || ap.binds.isEmpty()) {
            return ap;
        }
        String kw = a.bindSourceKeyword();
        String srcId = a.opt("src-sql-id", null);
        boolean fromCapture = (kw != null && srcId != null && !srcId.trim().isEmpty())
                || (a.opt("bind-file", null) == null && srcId != null && !srcId.trim().isEmpty());
        if (fromCapture && c != null && srcId != null && !srcId.trim().isEmpty()) {
            SqlLookup.BindSource src = SqlLookup.BindSource.AUTO;
            if ("backup".equals(kw)) {
                src = SqlLookup.BindSource.BACKUP;
            } else if ("view".equals(kw)) {
                src = SqlLookup.BindSource.VIEW;
            }
            List<BindValue> named = SqlLookup.loadBindsBySqlId(c, srcId.trim(), src,
                    SqlMapIo.warn(log));
            if (named != null && !named.isEmpty()) {
                LiteralBindRewrite.Aligned aligned = LiteralBindRewrite.align(ap.sql, named);
                for (String w : aligned.warnings) {
                    log.logInfo("[WARN] bind align: " + w);
                }
                ap.sql = aligned.sql;
                ap.binds = SqlLookup.toReplayRows(aligned.binds);
                ap.mode = "A";
                return ap;
            }
        }
        ap.sql = LiteralBindRewrite.toQuestionMarks(ap.sql);
        // 值文件: 按行序重编 position 1..N
        List<String[]> renum = new ArrayList<String[]>();
        for (int i = 0; i < ap.binds.size(); i++) {
            String[] b = ap.binds.get(i);
            renum.add(new String[] {
                String.valueOf(i + 1),
                b.length > 1 ? b[1] : "",
                b.length > 2 ? b[2] : ""
            });
        }
        ap.binds = renum;
        ap.mode = "qmark";
        return ap;
    }
}
