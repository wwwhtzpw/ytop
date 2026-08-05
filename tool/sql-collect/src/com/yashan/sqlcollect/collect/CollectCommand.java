package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.cli.Args;
import com.yashan.sqlcollect.config.JdbcConfig;
import com.yashan.sqlcollect.db.JdbcPool;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.db.LiveSqlSource;
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
        if (args.flag("skip-backup") && args.flag("backup-only")) {
            log.logError("--skip-backup and --backup-only are mutually exclusive");
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
            Files.createDirectories(outdir.resolve(REPORT_DIR));
            Files.createDirectories(outdir.resolve(SKIPPED_DIR));
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

        int[] loop = resolveLoop(interval, count);
        Integer rounds = loop[0] == -1 ? null : loop[0];
        int sleepSec = loop[1];

        log.logInfo("sql-collect v" + com.yashan.sqlcollect.Version.VERSION + " collect");
        log.logInfo("jdbc_config=" + cfg.configPath);
        log.logInfo("jdbc_url=" + cfg.jdbcUrl);
        boolean explainPlan = args.flag("explain-plan");
        log.logInfo("report=jdbc-native (ORIGINAL+LITERAL+PLAN/objects+AWR P2)");
        log.logInfo("explain_plan=" + explainPlan
                + (explainPlan ? " (SELECT/WITH CTE only; EXPLAIN PLAN FOR, no exec)" : " (default off)"));
        log.logInfo("reports_dir=" + outdir.resolve(REPORT_DIR));
        log.logInfo("skipped_dir=" + outdir.resolve(SKIPPED_DIR));
        log.logInfo("backup=" + (args.flag("backup-only") ? "only"
                : (args.flag("skip-backup") ? "off" : "on(B object-dedupe)")));
        log.logInfo("replay_export=" + (args.flag("skip-replay-export") ? "off" : "on"));
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
        log.logInfo("report_timeout_sec=" + reportWriter.getReportTimeoutSec()
                + (reportWriter.getReportTimeoutSec() <= 0 ? " (unlimited)" : ""));
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
                int failN = runRound(args, log, cfg, outdir, collectedPath,
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

    /** @return fail count, or negative to abort whole collect */
    private int runRound(Args args, DualLogger log, JdbcConfig cfg, Path outdir, Path collectedPath,
                         BackupService backupSvc, CandidateService candSvc, ReportWriter reportWriter,
                         PackageExporter exporter, BindRefresh bindRefresh, JdbcPool pool) {
        int failN = 0;
        List<String> backupNew = new ArrayList<String>();
        boolean backupOk = true;
        try (JdbcSession session = openSession(cfg, log, pool)) {
            session.getConnection().setAutoCommit(false);
            try {
                String who = com.yashan.sqlcollect.db.HtzTables.currentUser(session.getConnection());
                log.logDbg("jdbc session user=" + who + " htz_owner="
                        + com.yashan.sqlcollect.db.HtzTables.normalizeOwner(cfg.user));
            } catch (SQLException e) {
                log.logDbg("jdbc session user lookup failed: " + e.getMessage());
            }
            if (!args.flag("skip-backup")) {
                try {
                    BackupService.Result br = backupSvc.run(session);
                    backupNew = br.newSqlIds;
                } catch (SQLException e) {
                    // 对齐 Python: backup 失败 WARN 后继续报告采集 (backup-only 则失败退出)
                    backupOk = false;
                    log.logWarn("backup step failed; continue report collect: " + e.getMessage());
                    try {
                        session.getConnection().rollback();
                    } catch (SQLException ignored) {
                    }
                    if (args.flag("backup-only")) {
                        log.logError("backup-only failed");
                        return 1;
                    }
                }
            }
            if (args.flag("backup-only")) {
                for (String sid : backupNew) {
                    log.logDbg("backup-new sql_id=" + sid);
                }
                log.logInfo("backup-only done backup_new=" + backupNew.size());
                return backupOk ? 0 : 1;
            }

            // --sql-id / -s: 手动定向采集 (只处理给定 sql_id, 不扫候选池)
            List<String> forceIds = splitCsv(args.opt("sql-id", ""));
            if (!forceIds.isEmpty()) {
                log.logInfo("mode=force-sql-id targets=" + forceIds.size()
                        + " ids=" + forceIds);
                for (String sid : forceIds) {
                    try {
                        if (!collectForced(session, log, reportWriter, exporter, outdir, collectedPath,
                                sid, args.flag("skip-replay-export"))) {
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
            List<SqlCandidate> items = candSvc.list(session);
            List<SqlCandidate> newItems = new ArrayList<SqlCandidate>();
            for (SqlCandidate c : items) {
                if (!collected.contains(c.sqlId)) {
                    newItems.add(c);
                }
            }
            List<SqlCandidate> refreshItems = new ArrayList<SqlCandidate>();
            if (!args.flag("skip-replay-export")) {
                for (SqlCandidate c : items) {
                    if (collected.contains(c.sqlId) && bindRefresh.needsRefresh(outdir, c.sqlId)) {
                        refreshItems.add(c);
                    }
                }
            }
            log.logDbg("round collected=" + collected.size() + " candidates=" + items.size()
                    + " backup_new=" + backupNew.size() + " collect_new=" + newItems.size()
                    + " refresh=" + refreshItems.size());

            for (SqlCandidate item : newItems) {
                try {
                    if (collectOne(session, log, reportWriter, exporter, outdir, collectedPath,
                            item, args.flag("skip-replay-export"))) {
                        // ok
                    } else {
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
                    if (!bindRefresh.shouldReExport(session, outdir, item.sqlId)) {
                        log.logDbg("refresh skip sql_id=" + item.sqlId);
                        continue;
                    }
                } catch (SQLException e) {
                    log.logDbg("refresh capture check failed: " + e.getMessage());
                }
                log.logStep("bind_refresh", item.sqlId);
                try {
                    // Task 5: 临时 Live + 双写; Task 6 按 sink 矩阵传 writeFiles/writeHtzPkg
                    Path pkg = exporter.export(session, item.sqlId, outdir, "REFRESH",
                            LiveSqlSource.INSTANCE, true, true);
                    if (pkg != null) {
                        log.logInfo("refresh export sql_id=" + item.sqlId
                                + " " + PackageExporter.REPLAY_DIR + "/" + pkg.getFileName());
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

    private boolean collectOne(JdbcSession session, DualLogger log, ReportWriter reportWriter,
                               PackageExporter exporter, Path outdir, Path collectedPath,
                               SqlCandidate item, boolean skipReplayExport) throws SQLException {
        String sqlId = item.sqlId;
        log.logInfo("new sql_id=" + sqlId + " schema=" + item.schema + " len=" + item.sqlLen);
        log.logStep("collect_one", sqlId);
        try {
            if (!reportWriter.sqlIdPresentForReport(session, sqlId)) {
                log.logInfo("skip report sql_id=" + sqlId
                        + " (not in gv$sql/v$sql or gv$sqlstats/v$sqlstats)");
                Path stub = writeSkippedReport(outdir, sqlId, ReportWriter.skippedStub(sqlId,
                        "(not in gv$sql/gv$sqlstats)"));
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
            if (!skipReplayExport) {
                // Task 5: 临时 Live + 双写; Task 6 按 sink 矩阵传 writeFiles/writeHtzPkg
                Path pkg = exporter.export(session, sqlId, outdir, "NEW",
                        LiveSqlSource.INSTANCE, true, true);
                if (pkg == null) {
                    log.logWarn("report OK but replay export failed for " + sqlId
                            + "; not marked collected (will retry next round)");
                    return false;
                }
                log.logInfo("new done and export sql_id=" + sqlId
                        + " report=" + displayPath(outFile)
                        + " and " + PackageExporter.REPLAY_DIR + "/" + pkg.getFileName());
            } else {
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
     * 定向 sql_id: 先导出 replay 包/HTZ (对齐 Python plant→export ASAP),
     * 再尽力写报告; 报告不完整不影响导出成功.
     */
    private boolean collectForced(JdbcSession session, DualLogger log, ReportWriter reportWriter,
                                  PackageExporter exporter, Path outdir, Path collectedPath,
                                  String sqlId, boolean skipReplayExport) throws SQLException {
        log.logInfo("force sql_id=" + sqlId);
        log.logStep("collect_force", sqlId);
        if (!skipReplayExport) {
            // Task 5: 临时 Live + 双写; Task 6 按 sink 矩阵传 writeFiles/writeHtzPkg
            Path pkg = exporter.export(session, sqlId, outdir, "NEW",
                    LiveSqlSource.INSTANCE, true, true);
            if (pkg == null) {
                log.logWarn("force replay export failed for " + sqlId);
                return false;
            }
            log.logDbg("force export pkg=" + pkg);
        }
        boolean reportOk = false;
        try {
            if (!reportWriter.sqlIdPresentForReport(session, sqlId)) {
                log.logInfo("skip report sql_id=" + sqlId
                        + " (not in gv$sql/v$sql or gv$sqlstats/v$sqlstats; export kept)");
                Path stub = writeSkippedReport(outdir, sqlId, ReportWriter.skippedStub(sqlId,
                        "(not in gv$sql/gv$sqlstats; export kept)"));
                log.logDbg("skip stub=" + stub);
                return true;
            }
            String report = reportWriter.buildReport(session, sqlId);
            reportOk = reportWriter.isValidReport(report);
            if (reportOk) {
                Path outFile = writeOkReport(outdir, sqlId, report);
                if (!skipReplayExport) {
                    log.logInfo("force done and export sql_id=" + sqlId
                            + " report=" + displayPath(outFile));
                } else {
                    log.logInfo("force done sql_id=" + sqlId + " report=" + displayPath(outFile));
                }
            } else {
                Path stub = writeSkippedReport(outdir, sqlId, report);
                log.logWarn("report incomplete for " + sqlId
                        + "; keep under skipped/ (export already done) path=" + stub);
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
