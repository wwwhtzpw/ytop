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

import com.yashan.sqlcollect.util.NoiseFilter;
import com.yashan.sqlcollect.util.RunDirResolver;

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
    /** 仅指定 -c 未指定 -i 时的轮询间隔 (秒) */
    public static final int DEFAULT_INTERVAL_WITH_COUNT = 600;
    /** 未指定 -i/-c 时: 无限轮询的默认间隔 (秒); 与历史 sql_collect 一致 */
    public static final int DEFAULT_INTERVAL_SEC = 60;

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
        final Path collectedPath;
        try {
            com.yashan.sqlcollect.util.RunDirResolver.Result rr =
                    com.yashan.sqlcollect.util.RunDirResolver.resolve(baseOut, args.flag("new-run"));
            outdir = rr.runDir;
            // resolve 已 ensure; 再校验一层, 失败直接退出
            if (!Files.isDirectory(outdir)) {
                log.logError("run dir missing after resolve: " + outdir);
                return 2;
            }
            if (sink != SinkMode.BACKUP) {
                RunDirResolver.ensureDirectory(outdir.resolve(REPORT_DIR));
                RunDirResolver.ensureDirectory(outdir.resolve(SKIPPED_DIR));
            }
            log.logInfo("outdir_base=" + rr.baseOutdir);
            log.logInfo("run_dir=" + outdir + " mode=" + rr.mode
                    + (rr.created ? " (created)" : ""));
            collectedPath = outdir.resolve(COLLECTED_FILE);
            ensureCollectedFile(collectedPath);
        } catch (IOException e) {
            log.logError("create run dir failed: " + e.getMessage());
            return 2;
        }

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

        // FILE=live 报告; BACKUP 仅入库(日志 source=live); BOTH|TABLE 业务读 HTZ
        final SqlDataSource src = (sink == SinkMode.FILE)
                ? LiveSqlSource.INSTANCE
                : new HtzSqlSource(cfg.user);
        String sourceTag = (sink == SinkMode.FILE || sink == SinkMode.BACKUP) ? "live" : "htz";

        int[] loop = resolveLoop(interval, count);
        Integer rounds = loop[0] == -1 ? null : loop[0];
        int sleepSec = loop[1];

        log.logInfo("sql-collect v" + com.yashan.sqlcollect.Version.VERSION + " collect");
        log.logInfo("jdbc_config=" + cfg.configPath);
        log.logInfo("jdbc_url=" + cfg.jdbcUrl);
        log.logInfo("sink=" + sink.name().toLowerCase() + " source=" + sourceTag);
        boolean explainPlan = args.flag("explain-plan");
        String reportNote = "";
        if (sink == SinkMode.BACKUP) {
            reportNote = " (backup sink: HTZ_GV only, no reports)";
        } else if (sink == SinkMode.TABLE) {
            reportNote = " (table sink: HTZ -> reports(+replay), no BackupService)";
        }
        log.logInfo("report=jdbc-native (ORIGINAL+LITERAL+PLAN/objects+AWR P2)" + reportNote);
        log.logInfo("explain_plan=" + explainPlan
                + (explainPlan ? " (SELECT/WITH CTE only; EXPLAIN PLAN FOR, no exec)" : " (default off)"));
        if (sink != SinkMode.BACKUP) {
            log.logInfo("reports_dir=" + outdir.resolve(REPORT_DIR));
            log.logInfo("skipped_dir=" + outdir.resolve(SKIPPED_DIR));
        }
        log.logInfo("backup=" + (sink == SinkMode.BACKUP || sink == SinkMode.BOTH ? "on" : "off"));
        log.logInfo("replay_export=" + (skipX ? "off" : "on")
                + " writeFiles=" + writeFiles(sink, skipX));
        log.logInfo("schema_via_alter=" + cfg.schemaViaAlter);
        if (cfg.currentSchema != null && !cfg.currentSchema.isEmpty()) {
            log.logInfo("current_schema=" + cfg.currentSchema);
        }
        log.logInfo("htz_owner=" + com.yashan.sqlcollect.db.HtzTables.normalizeOwner(cfg.user));
        List<String> excludeSchemas = NoiseFilter.mergeExcludeSchemas(
                cfg.excludeSchemasRaw, args.opt("exclude-schemas", null));
        List<String> includeSchemas = NoiseFilter.parseSchemaList(
                cfg.includeSchemasRaw, args.opt("include-schemas", null));
        log.logInfo("exclude_schemas=" + joinComma(excludeSchemas)
                + " (builtin SYS,SYSDBA,SYSTEM + ini + CLI)");
        log.logInfo("include_schemas="
                + (includeSchemas.isEmpty() ? "(all except exclude)" : joinComma(includeSchemas))
                + " (ini + CLI; empty=no whitelist)");
        log.logInfo("loop rounds=" + (rounds == null ? "unlimited" : rounds)
                + " interval=" + (sleepSec < 0 ? "n/a" : sleepSec));
        log.logDbg("session_log=" + log.getSessionPath());
        log.logDbg("debug_log=" + log.getDebugPath());

        BackupService backupSvc = new BackupService(log, cfg.user,
                args.flag("include-uncaptured-binds"), excludeSchemas, includeSchemas);
        log.logInfo("include_uncaptured_binds="
                + args.flag("include-uncaptured-binds")
                + " (default false: skip WAS_CAPTURED=NO)");
        boolean activeSession = resolveActiveSession(args, cfg);
        log.logInfo("active_session=" + activeSession
                + " (scan gv$/v$session to prioritize long-running sql_id; "
                + "--no-active-session / --active-session false to disable)");
        CandidateService candSvc = new CandidateService(log, excludeSchemas, includeSchemas);
        ReportWriter reportWriter = new ReportWriter(log);
        reportWriter.setExplainPlan(explainPlan);
        reportWriter.setReportDataSource(src, sink == SinkMode.BOTH || sink == SinkMode.TABLE, cfg.user);
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
        if (sink != SinkMode.BACKUP) {
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
                        activeSession, backupSvc, candSvc, reportWriter, exporter, bindRefresh, pool);
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

    /**
     * CLI 显式指定优先于 ini; 都未指定则默认 true.
     */
    static boolean resolveActiveSession(Args args, JdbcConfig cfg) {
        if (args.flag("no-active-session")
                || args.options.containsKey("active-session")) {
            return args.resolveActiveSession();
        }
        if (cfg != null && cfg.activeSessionIni != null) {
            return cfg.activeSessionIni.booleanValue();
        }
        return true;
    }

    /** sink 矩阵: 是否写 replay/ 文件 (backup 永不写). */
    static boolean writeFiles(SinkMode sink, boolean skipX) {
        if (sink == SinkMode.BACKUP) {
            return false;
        }
        return !skipX;
    }

    /** @return fail count, or negative to abort whole collect */
    private int runRound(Args args, DualLogger log, JdbcConfig cfg, Path outdir, Path collectedPath,
                         SinkMode sink, boolean skipX, SqlDataSource src, boolean activeSession,
                         BackupService backupSvc, CandidateService candSvc, ReportWriter reportWriter,
                         PackageExporter exporter, BindRefresh bindRefresh, JdbcPool pool) {
        int failN = 0;
        List<String> backupNew = new ArrayList<String>();
        boolean backupOk = true;
        boolean useHtz = sink == SinkMode.BOTH || sink == SinkMode.TABLE;
        try (JdbcSession session = openSession(cfg, log, pool)) {
            session.getConnection().setAutoCommit(false);
            try {
                String who = com.yashan.sqlcollect.db.HtzTables.currentUser(session.getConnection());
                log.logDbg("jdbc session user=" + who + " htz_owner="
                        + com.yashan.sqlcollect.db.HtzTables.normalizeOwner(cfg.user));
            } catch (SQLException e) {
                log.logDbg("jdbc session user lookup failed: " + e.getMessage());
            }

            // --sql-id / -s: 提前解析, 供 backup STATS MERGE 集合 R 与强制采集共用
            List<String> forceIds = splitCsv(args.opt("sql-id", ""));

            // BACKUP|BOTH: 增量备份 HTZ_GV_*; FILE|TABLE: 跳过 BackupService
            if (sink == SinkMode.BACKUP || sink == SinkMode.BOTH) {
                try {
                    BackupService.Result br = backupSvc.run(session, forceIds);
                    backupNew = br.newSqlIds;
                } catch (SQLException e) {
                    backupOk = false;
                    log.logWarn("backup step failed; continue collect: " + e.getMessage());
                    try {
                        session.getConnection().rollback();
                    } catch (SQLException ignored) {
                    }
                    if (sink == SinkMode.BACKUP) {
                        log.logError("backup sink failed; round will count as failed");
                    }
                }
            }

            // backup: 只入库 + collected, 不写报告/replay
            if (sink == SinkMode.BACKUP) {
                if (backupOk) {
                    for (String id : backupNew) {
                        try {
                            appendCollected(collectedPath, id);
                        } catch (IOException e) {
                            log.logWarn("append collected failed " + id + ": " + e.getMessage());
                            failN++;
                        }
                    }
                    log.logInfo("backup sink done backup_new=" + backupNew.size()
                            + " collected_appended=" + backupNew.size());
                } else {
                    failN++;
                }
                return failN;
            }

            // --sql-id / -s: 手动定向采集 (只处理给定 sql_id, 不扫候选池)
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
            List<String> backupNewForCand = (sink == SinkMode.BOTH) ? backupNew
                    : new ArrayList<String>();
            List<SqlCandidate> items = candSvc.list(session, sink, backupNewForCand, activeSession);
            List<SqlCandidate> newItems = new ArrayList<SqlCandidate>();
            for (SqlCandidate c : items) {
                if (!collected.contains(c.sqlId)) {
                    newItems.add(c);
                }
            }
            List<SqlCandidate> refreshItems = new ArrayList<SqlCandidate>();
            // FILE|TABLE|BOTH 在未 -X 时刷 replay/
            boolean doRefresh = writeFiles(sink, skipX);
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
                    boolean ok = collectOne(session, log, reportWriter, exporter, outdir, collectedPath,
                            item, sink, skipX, src);
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
                    Path pkg = exporter.export(session, item.sqlId, outdir, "REFRESH",
                            src, wFiles);
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

    /**
     * sink=file|table|both: 写报告; 按矩阵导出 replay/ (不写包表).
     */
    private boolean collectOne(JdbcSession session, DualLogger log, ReportWriter reportWriter,
                               PackageExporter exporter, Path outdir, Path collectedPath,
                               SqlCandidate item, SinkMode sink, boolean skipX,
                               SqlDataSource src) throws SQLException {
        String sqlId = item.sqlId;
        log.logInfo("new sql_id=" + sqlId + " schema=" + item.schema + " len=" + item.sqlLen
                + " sink=" + sink.name().toLowerCase());
        log.logStep("collect_one", sqlId);
        boolean wFiles = writeFiles(sink, skipX);
        try {
            boolean present;
            if (sink == SinkMode.FILE) {
                present = reportWriter.sqlIdPresentForReport(session, sqlId);
            } else {
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
            if (wFiles) {
                Path pkg = exporter.export(session, sqlId, outdir, "NEW", src, true);
                if (pkg == null) {
                    log.logWarn("report OK but export failed for " + sqlId
                            + "; not marked collected (will retry next round)");
                    return false;
                }
                log.logInfo("new done and export sql_id=" + sqlId
                        + " report=" + displayPath(outFile)
                        + " and " + PackageExporter.REPLAY_DIR + "/" + pkg.getFileName());
            } else {
                // -X: 仅报告即可 collected
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
     * 定向 sql_id force (-s):
     * FILE: 先 replay 再报告; TABLE|BOTH: 报告 + (未 -X) replay; 均不写包表.
     */
    private boolean collectForced(JdbcSession session, DualLogger log, ReportWriter reportWriter,
                                  PackageExporter exporter, Path outdir, Path collectedPath,
                                  String sqlId, SinkMode sink, boolean skipX,
                                  SqlDataSource src) throws SQLException {
        log.logInfo("force sql_id=" + sqlId + " sink=" + sink.name().toLowerCase());
        log.logStep("collect_force", sqlId);

        boolean wFiles = writeFiles(sink, skipX);
        boolean filesAlreadyDone = false;
        if (sink == SinkMode.FILE && wFiles) {
            Path pkg = exporter.export(session, sqlId, outdir, "NEW", src, true);
            if (pkg == null) {
                log.logWarn("force replay export failed for " + sqlId);
                return false;
            }
            log.logDbg("force export pkg=" + pkg);
            filesAlreadyDone = true;
        }
        return forceReportAndFiles(session, log, reportWriter, exporter, outdir, collectedPath,
                sqlId, sink, skipX, src, filesAlreadyDone);
    }

    /**
     * force 路径的报告 + (如需) replay 文件.
     *
     * @param filesAlreadyDone FILE 已先写 replay 时为 true
     */
    private boolean forceReportAndFiles(JdbcSession session, DualLogger log, ReportWriter reportWriter,
                                        PackageExporter exporter, Path outdir, Path collectedPath,
                                        String sqlId, SinkMode sink, boolean skipX,
                                        SqlDataSource src, boolean filesAlreadyDone) throws SQLException {
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
                        + (filesAlreadyDone ? " (export kept)" : ""));
                Path stub = writeSkippedReport(outdir, sqlId, ReportWriter.skippedStub(sqlId,
                        filesAlreadyDone ? "(not present; export kept)" : "(not present)"));
                log.logDbg("skip stub=" + stub);
                return true;
            }
            String report = reportWriter.buildReport(session, sqlId);
            reportOk = reportWriter.isValidReport(report);
            if (reportOk) {
                Path outFile = writeOkReport(outdir, sqlId, report);
                if (!filesAlreadyDone && writeFiles(sink, skipX)) {
                    Path pkgFiles = exporter.export(session, sqlId, outdir, "NEW", src, true);
                    if (pkgFiles == null) {
                        log.logWarn("force report OK but file export failed for " + sqlId
                                + "; not marked collected");
                        reportOk = false;
                    } else {
                        log.logInfo("force done and export sql_id=" + sqlId
                                + " report=" + displayPath(outFile)
                                + " and " + PackageExporter.REPLAY_DIR + "/" + pkgFiles.getFileName());
                    }
                } else {
                    log.logInfo("force done sql_id=" + sqlId + " report=" + displayPath(outFile));
                }
            } else {
                Path stub = writeSkippedReport(outdir, sqlId, report);
                log.logWarn("report incomplete for " + sqlId
                        + "; keep under skipped/"
                        + (filesAlreadyDone ? " (export already done)" : "")
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
        com.yashan.sqlcollect.util.RunDirResolver.ensureDirectory(dir);
        Path out = dir.resolve(sqlId + ".txt");
        Files.write(out, body.getBytes(StandardCharsets.UTF_8));
        deleteQuiet(outdir.resolve(SKIPPED_DIR).resolve(sqlId + ".txt"));
        return out;
    }

    /** 跳过/不完整 → outdir/skipped/; 并删除 reports/ 中同名文件 */
    static Path writeSkippedReport(Path outdir, String sqlId, String body) throws IOException {
        Path dir = outdir.resolve(SKIPPED_DIR);
        com.yashan.sqlcollect.util.RunDirResolver.ensureDirectory(dir);
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

    /**
     * 解析轮询参数.
     * @return int[0]=rounds (-1=无限), int[1]=sleepSec (-1=不睡, 仅一轮时)
     */
    static int[] resolveLoop(Integer interval, Integer count) {
        // 均未指定: 无限轮询 + 默认间隔 (目录只在进程启动时按 -n 建一次, 各轮复用)
        if (interval == null && count == null) {
            return new int[] {-1, DEFAULT_INTERVAL_SEC};
        }
        if (count != null && interval == null) {
            interval = DEFAULT_INTERVAL_WITH_COUNT;
        }
        if (interval != null && count == null) {
            return new int[] {-1, interval};
        }
        return new int[] {count, interval};
    }

    private static void ensureCollectedFile(Path path) throws IOException {
        if (Files.isRegularFile(path)) {
            return;
        }
        try {
            Files.write(path, ("# collected sql_id list\n").getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new IOException("create collected file failed: " + path + ": " + e.getMessage(), e);
        }
        if (!Files.isRegularFile(path)) {
            throw new IOException("collected file missing after create: " + path);
        }
    }

    private static String joinComma(List<String> items) {
        if (items == null || items.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append(items.get(i));
        }
        return sb.toString();
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
