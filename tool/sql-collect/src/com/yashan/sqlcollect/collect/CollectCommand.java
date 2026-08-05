package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.cli.Args;
import com.yashan.sqlcollect.config.JdbcConfig;
import com.yashan.sqlcollect.db.HtzSqlSource;
import com.yashan.sqlcollect.db.JdbcPool;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.db.LiveSqlSource;
import com.yashan.sqlcollect.db.SqlDataSource;
import com.yashan.sqlcollect.log.DualLogger;
import com.yashan.sqlcollect.model.SqlCandidate;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** collect 子命令编排 */
public class CollectCommand {

    public static final String COLLECTED_FILE = "collected_sqlids.txt";
    /** 成功写出有效报告的子目录 */
    public static final String REPORT_DIR = "reports";
    /** 跳过/不完整报告 stub 子目录 */
    public static final String SKIPPED_DIR = "skipped";
    public static final String DEFAULT_OUTDIR = "./sql_collect";
    public static final String DEFAULT_LOG_DIR = "logs";
    public static final int DEFAULT_INTERVAL_WITH_COUNT = 600;

    public int run(Args args) {
        DualLogger log = null;
        try {
            Path logDir = Paths.get(args.opt("log-dir", DEFAULT_LOG_DIR));
            boolean debug = args.resolveDebug();
            log = new DualLogger(logDir, "collect", debug);
            log.logInfo("debug=" + debug);
            return runBody(args, log);
        } catch (IOException e) {
            System.err.println("[ERROR] log init failed: " + e.getMessage());
            return 2;
        } finally {
            if (log != null) {
                log.close();
            }
        }
    }

    private int runBody(Args args, DualLogger log) {
        SinkMode sink;
        try {
            sink = SinkMode.resolve(args);
        } catch (IllegalArgumentException e) {
            log.logError(e.getMessage());
            return 2;
        }
        boolean skipX = args.flag("skip-replay-export");

        Integer interval = args.optInt("interval", null);
        Integer count = args.optInt("count", null);
        if (interval != null && interval < 1) {
            log.logError("--interval must be >= 1");
            return 2;
        }
        if (count != null && count < 1) {
            log.logError("--count must be >= 1");
            return 2;
        }

        if (args.flag("init-config")) {
            try {
                String dest = JdbcConfig.writeTemplate(
                        args.opt("jdbc-config", JdbcConfig.DEFAULT_CONFIG), args.flag("overwrite"));
                log.logInfo("wrote jdbc config template: " + dest);
                log.logInfo("edit jdbc_jar / jdbc_url / user / password / [map.*] then re-run collect");
                return 0;
            } catch (IOException e) {
                log.logError(e.getMessage());
                return 2;
            }
        }

        Path baseOut = Paths.get(args.opt("outdir", DEFAULT_OUTDIR)).toAbsolutePath().normalize();
        final Path outdir;
        try {
            com.yashan.sqlcollect.util.RunDirResolver.Result rr =
                    com.yashan.sqlcollect.util.RunDirResolver.resolve(baseOut, args.flag("new-run"));
            outdir = rr.runDir;
            Files.createDirectories(outdir);
            if (sink != SinkMode.TABLE) {
                Files.createDirectories(outdir.resolve(REPORT_DIR));
                Files.createDirectories(outdir.resolve(SKIPPED_DIR));
            }
            log.logInfo("outdir_base=" + rr.baseOutdir);
            log.logInfo("run_dir=" + outdir + " mode=" + rr.mode
                    + (rr.created ? " (created)" : ""));
        } catch (IOException e) {
            log.logError("create run dir failed: " + e.getMessage());
            return 2;
        }
        Path collectedPath = outdir.resolve(COLLECTED_FILE);
        ensureCollectedFile(collectedPath);

        JdbcConfig cfg;
        try {
            cfg = JdbcConfig.load(args.opt("jdbc-config", JdbcConfig.DEFAULT_CONFIG));
        } catch (IOException e) {
            log.logError(e.getMessage());
            return 2;
        }
        if (args.flag("schema-via-alter")) {
            cfg.schemaViaAlter = true;
        }
        String cs = args.opt("current-schema", null);
        if (cs != null && !cs.isEmpty()) {
            cfg.currentSchema = cs;
        }

        final SqlDataSource src = (sink == SinkMode.FILE)
                ? LiveSqlSource.INSTANCE
                : new HtzSqlSource(cfg.user);
        String sourceTag = (sink == SinkMode.FILE) ? "live" : "htz";

        int[] loop = resolveLoop(interval, count);
        Integer rounds = loop[0] == -1 ? null : loop[0];
        int sleepSec = loop[1];

        log.logInfo("sql-collect v" + com.yashan.sqlcollect.Version.VERSION + " collect");
        log.logInfo("jdbc_config=" + cfg.configPath);
        log.logInfo("jdbc_url=" + cfg.jdbcUrl);
        log.logInfo("sink=" + sink.name().toLowerCase() + " source=" + sourceTag);
        boolean explainPlan = args.flag("explain-plan");
        log.logInfo("report=jdbc-native (ORIGINAL+LITERAL+PLAN/objects+AWR P2)"
                + (sink == SinkMode.TABLE ? " (table sink: package only, no reports)" : ""));
        log.logInfo("explain_plan=" + explainPlan
                + (explainPlan ? " (SELECT/WITH CTE only; EXPLAIN PLAN FOR, no exec)" : " (default off)"));
        if (sink != SinkMode.TABLE) {
            log.logInfo("reports_dir=" + outdir.resolve(REPORT_DIR));
            log.logInfo("skipped_dir=" + outdir.resolve(SKIPPED_DIR));
        }
        log.logInfo("backup=" + (sink == SinkMode.FILE ? "off"
                : (sink == SinkMode.TABLE ? "on+package" : "on(B object-dedupe)")));
        log.logInfo("replay_export=" + (skipX ? "off" : "on")
                + " writeHtzPkg=" + writeHtzPkg(sink, skipX)
                + " writeFiles=" + writeFiles(sink, skipX));
        log.logInfo("schema_via_alter=" + cfg.schemaViaAlter);
        if (cfg.currentSchema != null && !cfg.currentSchema.isEmpty()) {
            log.logInfo("current_schema=" + cfg.currentSchema);
        }
        log.logInfo("htz_owner=" + com.yashan.sqlcollect.db.HtzTables.normalizeOwner(cfg.user));
        log.logInfo("loop rounds=" + (rounds == null ? "unlimited" : rounds)
                + " interval=" + (sleepSec < 0 ? "n/a" : sleepSec));
        log.logDbg("session_log=" + log.getSessionPath());
        log.logDbg("debug_log=" + log.getDebugPath());

        BackupService backupSvc = new BackupService(log, cfg.user);
        CandidateService candSvc = new CandidateService(log);
        ReportWriter reportWriter = new ReportWriter(log);
        reportWriter.setExplainPlan(explainPlan);
        reportWriter.setReportDataSource(src, sink != SinkMode.FILE, cfg.user);
        Integer reportTimeout = args.optInt("report-timeout", null);
        if (reportTimeout == null) {
            reportTimeout = args.optInt("timeout", null);
        }
        if (reportTimeout != null) {
            if (reportTimeout < 0) {
                log.logError("--report-timeout must be >= 0 (0=unlimited)");
                return 2;
            }
            reportWriter.setReportTimeoutSec(reportTimeout.intValue());
        }
        if (sink != SinkMode.TABLE) {
            log.logInfo("report_timeout_sec=" + reportWriter.getReportTimeoutSec()
                    + (reportWriter.getReportTimeoutSec() <= 0 ? " (unlimited)" : ""));
        }
        PackageExporter exporter = new PackageExporter(log, cfg.user);
        BindRefresh bindRefresh = new BindRefresh();
        JdbcPool pool = new JdbcPool(log, JdbcPool.DEFAULT_MAX_IDLE_PER_USER);
        log.logInfo("jdbc_pool max_idle_per_user=" + JdbcPool.DEFAULT_MAX_IDLE_PER_USER);

        int roundI = 0;
        int totalFail = 0;
        try {
            while (true) {
                roundI++;
                log.logStep("collect_round", String.valueOf(roundI));
                log.logInfo("sink=" + sink.name().toLowerCase() + " source=" + sourceTag);
                int failN = runRound(args, log, cfg, outdir, collectedPath, sink, skipX, src,
                        backupSvc, candSvc, reportWriter, exporter, bindRefresh, pool);
                if (failN < 0) {
                    log.logError("collect aborted due to HTZ/JDBC fatal error");
                    return 1;
                }
                totalFail += failN;
                if (rounds != null && roundI >= rounds) {
                    break;
                }
                if (sleepSec < 0) {
                    break;
                }
                log.logDbg("sleep " + sleepSec + "s ...");
                Thread.sleep(sleepSec * 1000L);
            }
        } catch (InterruptedException e) {
            log.logInfo("interrupted by user");
            Thread.currentThread().interrupt();
            return 130;
        } finally {
            pool.close();
        }
        if (totalFail > 0) {
            log.logError("collect finished with fail_n=" + totalFail);
            return 1;
        }
        return 0;
    }

    /** sink 矩阵: 是否写 HTZ_SQL_REPLAY_PKG. */
    static boolean writeHtzPkg(SinkMode sink, boolean skipX) {
        if (sink == SinkMode.FILE) {
            return false;
        }
        if (sink == SinkMode.TABLE) {
            return true;
        }
        return !skipX;
    }

    /** sink 矩阵: 是否写 replay/ 文件. */
    static boolean writeFiles(SinkMode sink, boolean skipX) {
        if (sink == SinkMode.TABLE) {
            return false;
        }
        return !skipX;
    }

    /** @return fail count, or negative to abort whole collect */
    private int runRound(Args args, DualLogger log, JdbcConfig cfg, Path outdir, Path collectedPath,
                         SinkMode sink, boolean skipX, SqlDataSource src,
                         BackupService backupSvc, CandidateService candSvc, ReportWriter reportWriter,
                         PackageExporter exporter, BindRefresh bindRefresh, JdbcPool pool) {
        int failN = 0;
        List<String> backupNew = new ArrayList<String>();
        boolean backupOk = true;
        boolean useHtz = sink != SinkMode.FILE;
        try (JdbcSession session = openSession(cfg, log, pool)) {
            session.getConnection().setAutoCommit(false);
            try {
                String who = com.yashan.sqlcollect.db.HtzTables.currentUser(session.getConnection());
                log.logDbg("jdbc session user=" + who + " htz_owner="
                        + com.yashan.sqlcollect.db.HtzTables.normalizeOwner(cfg.user));
            } catch (SQLException e) {
                log.logDbg("jdbc session user lookup failed: " + e.getMessage());
            }

            // FILE: 完全跳过 BackupService; TABLE|BOTH: 增量备份 HTZ_GV_*
            if (sink != SinkMode.FILE) {
                try {
                    BackupService.Result br = backupSvc.run(session);
                    backupNew = br.newSqlIds;
                } catch (SQLException e) {
                    // WARN 后继续候选; table 本轮计失败 (backupOk → failN++)
                    backupOk = false;
                    log.logWarn("backup step failed; continue collect: " + e.getMessage());
                    try {
                        session.getConnection().rollback();
                    } catch (SQLException ignored) {
                    }
                    if (sink == SinkMode.TABLE) {
                        log.logError("table sink backup failed; round will count as failed");
                    }
                }
            }

            // --sql-id / -s: 手动定向采集 (只处理给定 sql_id, 不扫候选池)
            List<String> forceIds = splitCsv(args.opt("sql-id", ""));
            if (!forceIds.isEmpty()) {
                log.logInfo("mode=force-sql-id targets=" + forceIds.size()
                        + " ids=" + forceIds);
                for (String sid : forceIds) {
                    try {
                        if (!collectForced(session, log, reportWriter, exporter, outdir, collectedPath,
                                sid, sink, skipX, src)) {
                            failN++;
                        }
                    } catch (SQLException e) {
                        log.logError("HTZ/export fatal for " + sid + ": " + e.getMessage()
                                + " (rollback current unit only; prior sql_id commits kept)");
                        try {
                            session.getConnection().rollback();
                        } catch (SQLException ignored) {
                        }
                        return -1;
                    }
                }
                if (!backupOk) {
                    failN++;
                }
                return failN;
            }

            Set<String> collected = loadCollected(collectedPath);
            List<SqlCandidate> items = candSvc.list(session, sink, backupNew);
            List<SqlCandidate> newItems = new ArrayList<SqlCandidate>();
            for (SqlCandidate c : items) {
                if (!collected.contains(c.sqlId)) {
                    newItems.add(c);
                }
            }
            List<SqlCandidate> refreshItems = new ArrayList<SqlCandidate>();
            // TABLE 必刷包表; FILE|BOTH 在未 -X 时刷文件/包
            boolean doRefresh = (sink == SinkMode.TABLE) || !skipX;
            if (doRefresh) {
                for (SqlCandidate c : items) {
                    if (collected.contains(c.sqlId)
                            && bindRefresh.needsRefresh(session, outdir, c.sqlId, useHtz, cfg.user)) {
                        refreshItems.add(c);
                    }
                }
            }
            log.logDbg("round collected=" + collected.size() + " candidates=" + items.size()
                    + " backup_new=" + backupNew.size() + " collect_new=" + newItems.size()
                    + " refresh=" + refreshItems.size());

            for (SqlCandidate item : newItems) {
                try {
                    boolean ok;
                    if (sink == SinkMode.TABLE) {
                        ok = collectTableOnly(session, log, exporter, outdir, collectedPath, item, src);
                    } else {
                        ok = collectOne(session, log, reportWriter, exporter, outdir, collectedPath,
                                item, sink, skipX, src);
                    }
                    if (!ok) {
                        failN++;
                    }
                } catch (SQLException e) {
                    log.logError("HTZ/export fatal for " + item.sqlId + ": " + e.getMessage()
                            + " (rollback current unit only; prior sql_id commits kept)");
                    try {
                        session.getConnection().rollback();
                    } catch (SQLException ignored) {
                    }
                    return -1;
                }
            }
            for (SqlCandidate item : refreshItems) {
                try {
                    if (!bindRefresh.shouldReExport(session, outdir, item.sqlId, src, cfg.user)) {
                        log.logDbg("refresh skip sql_id=" + item.sqlId);
                        continue;
                    }
                } catch (SQLException e) {
                    log.logDbg("refresh capture check failed: " + e.getMessage());
                }
                log.logStep("bind_refresh", item.sqlId);
                try {
                    boolean wFiles = writeFiles(sink, skipX);
                    boolean wHtz = writeHtzPkg(sink, skipX);
                    Path pkg = exporter.export(session, item.sqlId, outdir, "REFRESH",
                            src, wFiles, wHtz);
                    if (pkg != null) {
                        if (wFiles) {
                            log.logInfo("refresh export sql_id=" + item.sqlId
                                    + " " + PackageExporter.REPLAY_DIR + "/" + pkg.getFileName());
                        } else {
                            log.logInfo("refresh htz-pkg sql_id=" + item.sqlId);
                        }
                    } else {
                        failN++;
                        log.logWarn("refresh export failed for " + item.sqlId);
                    }
                } catch (SQLException e) {
                    log.logError("HTZ refresh fatal for " + item.sqlId + ": " + e.getMessage());
                    return -1;
                }
            }
        } catch (SQLException e) {
            log.logError("collect round JDBC failed: " + e.getMessage());
            return -1;
        } catch (Exception e) {
            log.logError("collect round failed: " + e.getMessage());
            return -1;
        }
        if (!backupOk) {
            failN++;
        }
        return failN;
    }

    /**
     * sink=table: 只 upsert HTZ_SQL_REPLAY_PKG, 不写报告/文件包.
     * 成功 → appendCollected.
     */
    private boolean collectTableOnly(JdbcSession session, DualLogger log, PackageExporter exporter,
                                     Path outdir, Path collectedPath, SqlCandidate item,
                                     SqlDataSource src) throws SQLException {
        String sqlId = item.sqlId;
        log.logInfo("new sql_id=" + sqlId + " schema=" + item.schema + " len=" + item.sqlLen
                + " sink=table");
        log.logStep("collect_table", sqlId);
        try {
            Path pkg = exporter.export(session, sqlId, outdir, "NEW", src, false, true);
            if (pkg == null) {
                log.logWarn("htz package upsert failed for " + sqlId + "; not marked collected");
                return false;
            }
            log.logInfo("new done htz-pkg sql_id=" + sqlId);
            appendCollected(collectedPath, sqlId);
            return true;
        } catch (SQLException e) {
            throw e;
        } catch (Exception e) {
            log.logWarn("collect_table failed " + sqlId + ": " + e.getMessage());
            return false;
        }
    }

    /**
     * sink=file|both: 写报告; 按矩阵导出文件/包表.
     * Task 7 将切换报告 HTZ 段; 本期仍用 JdbcReportBuilder, 存在性优先 src.exists.
     */
    private boolean collectOne(JdbcSession session, DualLogger log, ReportWriter reportWriter,
                               PackageExporter exporter, Path outdir, Path collectedPath,
                               SqlCandidate item, SinkMode sink, boolean skipX,
                               SqlDataSource src) throws SQLException {
        String sqlId = item.sqlId;
        log.logInfo("new sql_id=" + sqlId + " schema=" + item.schema + " len=" + item.sqlLen);
        log.logStep("collect_one", sqlId);
        boolean wFiles = writeFiles(sink, skipX);
        boolean wHtz = writeHtzPkg(sink, skipX);
        try {
            boolean present;
            if (sink == SinkMode.FILE) {
                present = reportWriter.sqlIdPresentForReport(session, sqlId);
            } else {
                // BOTH: HTZ 事实源; Task 7 完整报告段切换
                present = src.exists(session.getConnection(), sqlId);
            }
            if (!present) {
                log.logInfo("skip report sql_id=" + sqlId
                        + (sink == SinkMode.FILE
                        ? " (not in gv$sql/v$sql or gv$sqlstats/v$sqlstats)"
                        : " (not in HTZ_GV_SQL)"));
                Path stub = writeSkippedReport(outdir, sqlId, ReportWriter.skippedStub(sqlId,
                        sink == SinkMode.FILE
                                ? "(not in gv$sql/gv$sqlstats)"
                                : "(not in HTZ_GV_SQL)"));
                log.logDbg("skip stub=" + stub);
                return true;
            }
            String report = reportWriter.buildReport(session, sqlId);
            if (!reportWriter.isValidReport(report)) {
                Path stub = writeSkippedReport(outdir, sqlId, report);
                log.logWarn("report incomplete for " + sqlId + "; saved under skipped/, not marked collected"
                        + " path=" + stub);
                return false;
            }
            Path outFile = writeOkReport(outdir, sqlId, report);
            if (wFiles || wHtz) {
                Path pkg = exporter.export(session, sqlId, outdir, "NEW", src, wFiles, wHtz);
                if (pkg == null) {
                    log.logWarn("report OK but export failed for " + sqlId
                            + "; not marked collected (will retry next round)");
                    return false;
                }
                if (wFiles) {
                    log.logInfo("new done and export sql_id=" + sqlId
                            + " report=" + displayPath(outFile)
                            + " and " + PackageExporter.REPLAY_DIR + "/" + pkg.getFileName());
                } else {
                    log.logInfo("new done sql_id=" + sqlId + " report=" + displayPath(outFile)
                            + " htz-pkg=ok");
                }
            } else {
                // both -X: 仅报告即可 collected
                log.logInfo("new done sql_id=" + sqlId + " report=" + displayPath(outFile));
            }
            appendCollected(collectedPath, sqlId);
            return true;
        } catch (SQLException e) {
            throw e;
        } catch (Exception e) {
            log.logWarn("collect_one failed " + sqlId + ": " + e.getMessage());
            return false;
        }
    }

    /**
     * 定向 sql_id force (-s), 按 sink §5.4:
     * FILE: 先文件包再报告; TABLE: 只 upsert 包表 (不在 HTZ → 失败, 无 v$ 回落);
     * BOTH: 先包表, 再报告+文件包.
     */
    private boolean collectForced(JdbcSession session, DualLogger log, ReportWriter reportWriter,
                                  PackageExporter exporter, Path outdir, Path collectedPath,
                                  String sqlId, SinkMode sink, boolean skipX,
                                  SqlDataSource src) throws SQLException {
        log.logInfo("force sql_id=" + sqlId + " sink=" + sink.name().toLowerCase());
        log.logStep("collect_force", sqlId);

        if (sink == SinkMode.TABLE) {
            Path pkg = exporter.export(session, sqlId, outdir, "NEW", src, false, true);
            if (pkg == null) {
                log.logWarn("force htz-pkg failed for " + sqlId
                        + " (sql_id not in HTZ or upsert failed; no v$ fallback)");
                return false;
            }
            log.logInfo("force done htz-pkg sql_id=" + sqlId);
            try {
                appendCollected(collectedPath, sqlId);
            } catch (IOException e) {
                log.logWarn("append collected failed " + sqlId + ": " + e.getMessage());
            }
            return true;
        }

        if (sink == SinkMode.BOTH) {
            // 先包表 (未 -X); -X 时跳过包表, 仅报告
            if (writeHtzPkg(sink, skipX)) {
                Path pkgTable = exporter.export(session, sqlId, outdir, "NEW", src, false, true);
                if (pkgTable == null) {
                    log.logWarn("force htz-pkg failed for " + sqlId + "; abort force");
                    return false;
                }
                log.logDbg("force htz-pkg ok sql_id=" + sqlId);
            }
            return forceReportAndFiles(session, log, reportWriter, exporter, outdir, collectedPath,
                    sqlId, sink, skipX, src, true);
        }

        // FILE: 先文件包再报告
        boolean wFiles = writeFiles(sink, skipX);
        if (wFiles) {
            Path pkg = exporter.export(session, sqlId, outdir, "NEW", src, true, false);
            if (pkg == null) {
                log.logWarn("force replay export failed for " + sqlId);
                return false;
            }
            log.logDbg("force export pkg=" + pkg);
        }
        return forceReportAndFiles(session, log, reportWriter, exporter, outdir, collectedPath,
                sqlId, sink, skipX, src, false);
    }

    /**
     * force 路径的报告 (+ BOTH 时补写文件包).
     * @param bothPkgDone BOTH 已写包表; 若需文件则再 export writeFiles
     */
    private boolean forceReportAndFiles(JdbcSession session, DualLogger log, ReportWriter reportWriter,
                                        PackageExporter exporter, Path outdir, Path collectedPath,
                                        String sqlId, SinkMode sink, boolean skipX,
                                        SqlDataSource src, boolean bothPkgDone) throws SQLException {
        boolean reportOk = false;
        try {
            boolean present;
            if (sink == SinkMode.FILE) {
                present = reportWriter.sqlIdPresentForReport(session, sqlId);
            } else {
                present = src.exists(session.getConnection(), sqlId);
            }
            if (!present) {
                log.logInfo("skip report sql_id=" + sqlId
                        + (bothPkgDone ? " (export kept)" : ""));
                Path stub = writeSkippedReport(outdir, sqlId, ReportWriter.skippedStub(sqlId,
                        bothPkgDone ? "(not present; export kept)" : "(not present)"));
                log.logDbg("skip stub=" + stub);
                // BOTH 包表已成功: 仍可 collected? 设计 force both: 报告失败→保留包表, skipped
                // append 条件 both: 报告有效且包表成功... → 报告失败不 append
                return true;
            }
            String report = reportWriter.buildReport(session, sqlId);
            reportOk = reportWriter.isValidReport(report);
            if (reportOk) {
                Path outFile = writeOkReport(outdir, sqlId, report);
                if (bothPkgDone && writeFiles(sink, skipX)) {
                    Path pkgFiles = exporter.export(session, sqlId, outdir, "NEW", src, true, false);
                    if (pkgFiles == null) {
                        log.logWarn("force report OK but file export failed for " + sqlId
                                + "; not marked collected");
                        reportOk = false;
                    } else {
                        log.logInfo("force done and export sql_id=" + sqlId
                                + " report=" + displayPath(outFile)
                                + " and " + PackageExporter.REPLAY_DIR + "/" + pkgFiles.getFileName());
                    }
                } else if (bothPkgDone) {
                    log.logInfo("force done sql_id=" + sqlId + " report=" + displayPath(outFile)
                            + " htz-pkg=ok");
                } else {
                    log.logInfo("force done sql_id=" + sqlId + " report=" + displayPath(outFile));
                }
            } else {
                Path stub = writeSkippedReport(outdir, sqlId, report);
                log.logWarn("report incomplete for " + sqlId
                        + "; keep under skipped/"
                        + (bothPkgDone ? " (htz-pkg kept)" : " (export already done)")
                        + " path=" + stub);
            }
        } catch (Exception e) {
            log.logWarn("force report failed " + sqlId + ": " + e.getMessage());
        }
        if (reportOk) {
            try {
                appendCollected(collectedPath, sqlId);
            } catch (IOException e) {
                log.logWarn("append collected failed " + sqlId + ": " + e.getMessage());
            }
        }
        return true;
    }

    /** 终端友好路径: 相对 cwd 则相对显示 */
    static String displayPath(Path p) {
        if (p == null) {
            return "";
        }
        Path abs = p.toAbsolutePath().normalize();
        try {
            Path cwd = Paths.get("").toAbsolutePath().normalize();
            if (abs.startsWith(cwd)) {
                return cwd.relativize(abs).toString().replace('\\', '/');
            }
        } catch (Exception ignored) {
        }
        return abs.toString().replace('\\', '/');
    }

    /** 有效报告 → outdir/reports/; 并删除 skipped/ 中同名文件 */
    static Path writeOkReport(Path outdir, String sqlId, String body) throws IOException {
        Path dir = outdir.resolve(REPORT_DIR);
        Files.createDirectories(dir);
        Path out = dir.resolve(sqlId + ".txt");
        Files.write(out, body.getBytes(StandardCharsets.UTF_8));
        deleteQuiet(outdir.resolve(SKIPPED_DIR).resolve(sqlId + ".txt"));
        return out;
    }

    /** 跳过/不完整 → outdir/skipped/; 并删除 reports/ 中同名文件 */
    static Path writeSkippedReport(Path outdir, String sqlId, String body) throws IOException {
        Path dir = outdir.resolve(SKIPPED_DIR);
        Files.createDirectories(dir);
        Path out = dir.resolve(sqlId + ".txt");
        Files.write(out, body.getBytes(StandardCharsets.UTF_8));
        deleteQuiet(outdir.resolve(REPORT_DIR).resolve(sqlId + ".txt"));
        return out;
    }

    private static void deleteQuiet(Path p) {
        try {
            Files.deleteIfExists(p);
        } catch (IOException ignored) {
        }
    }

    static List<String> splitCsv(String raw) {
        List<String> out = new ArrayList<String>();
        if (raw == null || raw.trim().isEmpty()) {
            return out;
        }
        for (String p : raw.split(",")) {
            String s = p.trim();
            if (!s.isEmpty()) {
                out.add(s);
            }
        }
        return out;
    }

    private JdbcSession openSession(JdbcConfig cfg, DualLogger log, JdbcPool pool)
            throws SQLException, ClassNotFoundException {
        return new JdbcSession(cfg, log, pool);
    }

    private static int[] resolveLoop(Integer interval, Integer count) {
        if (interval == null && count == null) {
            return new int[] {1, -1};
        }
        if (count != null && interval == null) {
            interval = DEFAULT_INTERVAL_WITH_COUNT;
        }
        if (interval != null && count == null) {
            return new int[] {-1, interval};
        }
        return new int[] {count, interval};
    }

    private static void ensureCollectedFile(Path path) {
        if (Files.isRegularFile(path)) {
            return;
        }
        try {
            Files.write(path, ("# collected sql_id list\n").getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) {
        }
    }

    static Set<String> loadCollected(Path path) {
        Set<String> set = new HashSet<String>();
        if (!Files.isRegularFile(path)) {
            return set;
        }
        try {
            for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
                String s = line.trim();
                if (s.isEmpty() || s.startsWith("#")) {
                    continue;
                }
                set.add(s);
            }
        } catch (IOException ignored) {
        }
        return set;
    }

    static void appendCollected(Path path, String sqlId) throws IOException {
        Files.write(path, (sqlId + "\n").getBytes(StandardCharsets.UTF_8),
                StandardOpenOption.CREATE, StandardOpenOption.APPEND);
    }
}
