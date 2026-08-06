package com.yashan.sqlcollect.replay;

import com.yashan.sqlcollect.cli.Args;
import com.yashan.sqlcollect.collect.BindRefresh;
import com.yashan.sqlcollect.collect.CollectCommand;
import com.yashan.sqlcollect.config.JdbcConfig;
import com.yashan.sqlcollect.db.JdbcPool;
import com.yashan.sqlcollect.log.DualLogger;
import com.yashan.sqlcollect.util.JsonBinds;
import com.yashan.sqlcollect.util.PipeEscape;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/** replay 子命令 CLI */
public class ReplayCommand {

    public static final String DEFAULT_LOG_DIR = "logs";

    /** replay 整体超时默认秒数 (对齐 Python JDBC_TIMEOUT=600); 超时退出码 124 */
    public static final int DEFAULT_REPLAY_TIMEOUT_SEC = 600;

    /** 超时强制退出码 (与 Python subprocess TimeoutExpired -> 124 一致) */
    public static final int EXIT_TIMEOUT = 124;

    public int run(Args args) {
        DualLogger log = null;
        try {
            Path logDir = Paths.get(args.opt("log-dir", DEFAULT_LOG_DIR));
            boolean debug = args.resolveDebug();
            log = new DualLogger(logDir, "replay", debug);
            log.logDbg("debug=" + debug);
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

    private int runBody(Args args, final DualLogger log) {
        String cfgPath = args.opt("jdbc-config", JdbcConfig.DEFAULT_CONFIG);
        if (args.flag("init-config")) {
            try {
                String dest = JdbcConfig.writeTemplate(cfgPath, args.flag("overwrite"));
                log.logInfo("wrote jdbc config template: " + dest);
                log.logInfo("edit jdbc_jar / jdbc_url / user / password / [map.*] then re-run collect or replay");
                return 0;
            } catch (IOException e) {
                log.logError(e.getMessage());
                return 2;
            }
        }

        JdbcConfig cfg;
        try {
            cfg = JdbcConfig.load(cfgPath);
        } catch (IOException e) {
            log.logError(e.getMessage());
            return 2;
        }
        if (args.flag("schema-via-alter")) {
            cfg.schemaViaAlter = true;
        }

        String source = args.opt("source", "file").trim().toLowerCase();
        if ("gvsql".equals(source) || "gv$".equals(source) || "gv$sql".equals(source)) {
            source = "gv";
        }
        if ("htz".equals(source) || "table".equals(source) || "pkg".equals(source)) {
            log.logError("--source htz removed (HTZ_SQL_REPLAY_PKG deleted);"
                    + " use --source file or --source gv");
            return 2;
        }
        if (!"file".equals(source) && !"gv".equals(source)) {
            log.logError("--source must be file or gv");
            return 2;
        }

        List<String> sqlIds = parseSqlIdList(args.opt("sql-id", null));
        if ("gv".equals(source) && sqlIds.isEmpty()) {
            log.logError("--source gv requires --sql-id (comma-separated allowed)");
            return 2;
        }

        Path baseOut = Paths.get(args.opt("outdir", CollectCommand.DEFAULT_OUTDIR))
                .toAbsolutePath().normalize();
        final Path outdir;
        try {
            com.yashan.sqlcollect.util.RunDirResolver.Result rr =
                    com.yashan.sqlcollect.util.RunDirResolver.resolve(baseOut, args.flag("new-run"));
            outdir = rr.runDir;
            Files.createDirectories(outdir);
            log.logDbg("outdir_base=" + rr.baseOutdir);
            log.logDbg("run_dir=" + outdir + " mode=" + rr.mode
                    + (rr.created ? " (created)" : ""));
        } catch (IOException e) {
            log.logError("resolve run dir failed: " + e.getMessage());
            return 2;
        }

        // 默认 dry-run; 真执行须显式 --exec (breaking vs 旧版默认 EXECUTE)
        boolean wantExec = args.flag("exec");
        boolean wantDry = args.flag("dry-run");
        if (wantExec && wantDry) {
            log.logError("--exec and --dry-run are mutually exclusive");
            return 2;
        }
        boolean dry = !wantExec;
        String mode = dry ? "dry" : "exec";
        boolean force = args.flag("force");
        // 默认增量: 跳过已成功 exec; --replay-all 备份 CSV 后全量重跑
        boolean replayAll = args.flag("replay-all");
        boolean skipDone = !replayAll;
        Integer parallelOpt = args.optInt("parallel", null);
        Integer sessionsOpt = args.optInt("sessions", null);
        int parallel = parallelOpt == null ? 1 : parallelOpt.intValue();
        int sessions = sessionsOpt == null ? 1 : sessionsOpt.intValue();
        if (parallel < 1) {
            log.logError("--parallel must be >= 1");
            return 2;
        }
        if (sessions < 1) {
            log.logError("--sessions must be >= 1");
            return 2;
        }

        Integer timeoutOpt = args.optInt("timeout", null);
        if (timeoutOpt == null) {
            timeoutOpt = args.optInt("replay-timeout", null);
        }
        final int timeoutSec = timeoutOpt == null
                ? DEFAULT_REPLAY_TIMEOUT_SEC
                : timeoutOpt.intValue();
        if (timeoutSec < 0) {
            log.logError("--timeout must be >= 0 (0=unlimited)");
            return 2;
        }

        Map<String, String[]> maps = new HashMap<String, String[]>();
        for (Map.Entry<String, String[]> e : cfg.maps.entrySet()) {
            maps.put(e.getKey(), e.getValue());
        }
        // 未配置任何 [map.*] 时默认 ALTER SESSION 切 schema (与「无 map 就用 alter」预期一致)
        if (!cfg.schemaViaAlter && maps.isEmpty()) {
            cfg.schemaViaAlter = true;
            log.logDbg("login_mode auto=alter-session (no [map.*] in jdbc config)");
        }

        log.logInfo("sql-collect v" + com.yashan.sqlcollect.Version.VERSION + " replay"
                + " source=" + source
                + " mode=" + (dry ? "dry-run" : "exec")
                + " run_dir=" + outdir
                + " login=" + (cfg.schemaViaAlter ? "alter-session" : "map"));
        log.logDbg("outdir_base=" + outdir.getParent());
        log.logDbg("jdbc_config=" + cfg.configPath);
        log.logDbg("jdbc_url=" + cfg.jdbcUrl);
        if (cfg.schemaViaAlter) {
            log.logDbg("login_mode=alter-session (jdbc user=" + cfg.user + "; CURRENT_SCHEMA per sql)");
        } else {
            log.logDbg("login_mode=map (jdbc lookup=" + cfg.user + "; exec via [map.SCHEMA] or fallback)");
        }
        log.logDbg("jdbc_jar=" + cfg.jdbcJar);
        log.logDbg("user_maps=" + maps.size());
        log.logDbg("force=" + force + " (non-query blocked unless true)");
        log.logDbg("parallel=" + parallel + " (distinct SQL targets)");
        log.logDbg("sessions=" + sessions + " (concurrent sessions per SQL)");
        log.logDbg("replay_timeout_sec=" + timeoutSec
                + (timeoutSec <= 0 ? " (unlimited)" : ""));
        if (!sqlIds.isEmpty()) {
            log.logInfo("sql_id=" + join(sqlIds));
        }
        log.logDbg("skip_done=" + skipDone + (replayAll ? " (disabled by --replay-all)" : " (default incremental)"));
        log.logDbg("replay_all=" + replayAll);

        final boolean shaMismatchFail;
        try {
            shaMismatchFail = args.resolveShaMismatchFail();
        } catch (IllegalArgumentException e) {
            log.logError(e.getMessage());
            return 2;
        }
        log.logDbg("on_sha_mismatch=" + (shaMismatchFail ? "fail" : "warn")
                + (shaMismatchFail ? " (block replay on fingerprint mismatch)"
                : " (WARN then continue replay)"));

        try {
            Class.forName("com.yashandb.jdbc.Driver");
        } catch (ClassNotFoundException e) {
            log.logError("JDBC driver not found: " + e.getMessage());
            return 2;
        }

        final JdbcPool pool = new JdbcPool(log, JdbcPool.DEFAULT_MAX_IDLE_PER_USER);
        log.logDbg("jdbc_pool max_idle_per_user=" + JdbcPool.DEFAULT_MAX_IDLE_PER_USER);
        final ReplayEngine.LineOut lineOut = new ReplayEngine.LineOut() {
            public void println(String line) {
                log.logReplayLine(line);
            }

            public void step(String name, String detail) {
                log.logStep(name, detail);
            }

            public void dbg(String msg) {
                log.logDbg(msg);
            }
        };
        final ReplayEngine engine = new ReplayEngine(
                cfg.jdbcUrl, cfg.user, cfg.password, maps, cfg.schemaViaAlter, lineOut, pool);
        engine.setQueryTimeoutSec(timeoutSec);
        engine.setShaMismatchFail(shaMismatchFail);
        Path resultsPath = Paths.get(args.opt("results-csv",
                outdir.resolve("replay_results.csv").toString()));
        final java.util.Set<String> doneKeys = new java.util.HashSet<String>();
        try {
            ReplayResultCsv csv = new ReplayResultCsv(resultsPath);
            if (replayAll) {
                Path bak = csv.backupAndReset();
                if (bak != null) {
                    log.logInfo("replay-all: backed up results_csv to " + bak);
                } else {
                    log.logInfo("replay-all: no prior results_csv to backup");
                }
            } else if (skipDone) {
                doneKeys.addAll(csv.loadOkExecKeys());
                log.logDbg("skip_done keys=" + doneKeys.size() + " (rc=0 live, exclude dry-run)");
            }
            engine.setResultCsv(csv);
            log.logDbg("results_csv=" + csv.path());
        } catch (IOException e) {
            log.logError("results csv init failed: " + e.getMessage());
            return 2;
        }

        final java.util.concurrent.atomic.AtomicBoolean finished =
                new java.util.concurrent.atomic.AtomicBoolean(false);
        Thread watchdog = null;
        if (timeoutSec > 0) {
            final DualLogger logRef = log;
            final int toSec = timeoutSec;
            final Thread mainThread = Thread.currentThread();
            watchdog = new Thread(new Runnable() {
                public void run() {
                    try {
                        Thread.sleep(toSec * 1000L);
                    } catch (InterruptedException e) {
                        return;
                    }
                    if (finished.get()) {
                        return;
                    }
                    // 宽限期: 主线程可能已完成工作但尚未置 finished
                    try {
                        mainThread.join(2000L);
                    } catch (InterruptedException ignored) {
                    }
                    if (finished.get()) {
                        return;
                    }
                    String msg = "[ERROR] replay timeout after " + toSec
                            + "s; aborting process";
                    try {
                        logRef.logError(msg);
                    } catch (Exception ignored) {
                    }
                    System.err.println(msg);
                    // 对齐 Python proc.kill(): 强制结束整个 JVM 进程
                    Runtime.getRuntime().halt(EXIT_TIMEOUT);
                }
            }, "replay-timeout-watchdog");
            watchdog.setDaemon(true);
            watchdog.start();
        }

        int okN = 0;
        int failN = 0;
        try {
            if ("file".equals(source)) {
                BindRefresh br = new BindRefresh();
                List<Path> pkgs;
                if (sqlIds.isEmpty()) {
                    pkgs = br.listPackages(outdir, null);
                } else {
                    pkgs = new ArrayList<Path>();
                    for (String sid : sqlIds) {
                        pkgs.addAll(br.listPackages(outdir, sid));
                    }
                }
                if (pkgs.isEmpty()) {
                    log.logError("no replay packages under " + outdir + "/" + com.yashan.sqlcollect.collect.PackageExporter.REPLAY_DIR);
                    return 1;
                }
                if (skipDone && !doneKeys.isEmpty()) {
                    List<Path> filtered = new ArrayList<Path>();
                    int skipped = 0;
                    for (Path pkg : pkgs) {
                        String k = packageDoneKey(pkg);
                        if (k != null && doneKeys.contains(k)) {
                            skipped++;
                            log.logDbg("skip already-ok " + pkg.getFileName());
                            continue;
                        }
                        filtered.add(pkg);
                    }
                    log.logInfo("packages=" + pkgs.size() + " skipped=" + skipped
                            + " remain=" + filtered.size());
                    pkgs = filtered;
                    if (pkgs.isEmpty()) {
                        log.logInfo("all packages already ok; nothing to replay");
                        finished.set(true);
                        return 0;
                    }
                } else {
                    log.logInfo("packages=" + pkgs.size());
                }
                final String modeLabel = dry ? "dry-run-ok" : "exec-ok";
                int[] r = mapParallel(parallel, pkgs, new Worker<Path>() {
                    public boolean run(Path pkg) throws Exception {
                        return replayPackage(log, engine, pkg, mode, force, sessions, modeLabel);
                    }
                }, timeoutSec);
                okN = r[0];
                failN = r[1];
            } else if ("gv".equals(source)) {
                List<String> targets = filterSqlIdsByDone(sqlIds, doneKeys, skipDone, log);
                if (targets.isEmpty()) {
                    log.logInfo("all gv sql_id already ok; nothing to replay");
                    finished.set(true);
                    return 0;
                }
                log.logInfo("targets=" + targets.size());
                final String modeLabelGv = dry ? "dry-run-ok" : "exec-ok";
                int[] r = mapParallel(parallel, targets, new Worker<String>() {
                    public boolean run(String sid) throws Exception {
                        boolean ok;
                        try {
                            ok = replayWithSessions(engine, new Callable<ReplayEngine.ReplayResult>() {
                                public ReplayEngine.ReplayResult call() throws Exception {
                                    return engine.replayGv(sid, mode, force);
                                }
                            }, sessions, timeoutSec);
                        } catch (Exception e) {
                            String em = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
                            engine.noteFail(em);
                            log.logDbg("replayGv exception sql_id=" + sid + " err=" + em);
                            ok = false;
                        }
                        if (ok) {
                            String detail = engine.takeLastOkDetail();
                            log.logInfo(modeLabelGv + " source=gv sql_id=" + sid
                                    + (detail.isEmpty() ? "" : " " + detail));
                        } else {
                            String reason = engine.takeLastFailReason();
                            log.logWarn("fail source=gv sql_id=" + sid
                                    + (reason.isEmpty() ? "" : " reason=" + reason));
                        }
                        return ok;
                    }
                }, timeoutSec);
                okN = r[0];
                failN = r[1];
            } else {
                log.logError("unsupported --source: " + source);
                finished.set(true);
                return 2;
            }
            // 工作完成即标记, 勿等外层 finally, 降低 watchdog 误判
            finished.set(true);
        } catch (java.util.concurrent.TimeoutException e) {
            log.logError("replay timeout after " + timeoutSec + "s: " + e.getMessage());
            finished.set(true);
            if (watchdog != null) {
                watchdog.interrupt();
            }
            engine.close();
            pool.close();
            return EXIT_TIMEOUT;
        } catch (Exception e) {
            log.logError("replay failed: " + e.getMessage());
            finished.set(true);
            if (watchdog != null) {
                watchdog.interrupt();
            }
            engine.close();
            pool.close();
            return 1;
        } finally {
            finished.set(true);
            if (watchdog != null) {
                watchdog.interrupt();
            }
            engine.close();
            pool.close();
        }

        log.logInfo("replay summary ok=" + okN + " fail=" + failN);
        return failN > 0 ? 1 : 0;
    }

    private boolean replayPackage(DualLogger log, ReplayEngine engine, Path pkg, String mode, boolean force,
                                  int sessions, String okLabel)
            throws Exception {
        Path metaPath = pkg.resolve("meta.txt");
        Map<String, String> meta = readMeta(metaPath);
        String schema = meta.get("parsing_schema");
        Path sqlFile = pkg.resolve("orig.sql");
        Path bindsFile = pkg.resolve("binds.txt");
        Path bj = pkg.resolve("binds.json");
        if (Files.isRegularFile(bj)) {
            String raw = new String(Files.readAllBytes(bj), StandardCharsets.UTF_8);
            StringBuilder bt = new StringBuilder("# position|datatype|value\n");
            for (com.yashan.sqlcollect.model.BindValue b : JsonBinds.read(raw)) {
                bt.append(b.position).append("|")
                        .append(PipeEscape.escape(b.datatype)).append("|")
                        .append(PipeEscape.escape(b.value)).append("\n");
            }
            Files.write(bindsFile, bt.toString().getBytes(StandardCharsets.UTF_8));
        } else if (!Files.isRegularFile(bindsFile)) {
            Files.write(bindsFile, "# no binds\n".getBytes(StandardCharsets.UTF_8));
        }
        final String sqlId = meta.containsKey("sql_id") ? meta.get("sql_id") : pkg.getFileName().toString();
        final String expectedSha = meta.get(com.yashan.sqlcollect.model.ReplayPackageMeta.META_SQL_SHA256);
        int child = 0;
        int instId = 1;
        try {
            if (meta.containsKey("child_number")) {
                child = Integer.parseInt(meta.get("child_number").trim());
            }
        } catch (NumberFormatException ignored) {
        }
        try {
            if (meta.containsKey("inst_id")) {
                instId = Integer.parseInt(meta.get("inst_id").trim());
            }
        } catch (NumberFormatException ignored) {
        }
        final int childF = child;
        final int instF = instId;
        boolean ok;
        try {
            ok = replayWithSessions(engine, new Callable<ReplayEngine.ReplayResult>() {
                public ReplayEngine.ReplayResult call() throws Exception {
                    return engine.replayFile(
                            schema == null ? "" : schema,
                            sqlFile.toString(),
                            bindsFile.toString(),
                            mode,
                            force,
                            sqlId,
                            childF,
                            instF,
                            expectedSha);
                }
            }, sessions, 0);
        } catch (Exception e) {
            String em = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
            engine.noteFail(em);
            log.logDbg("replayPackage exception sql_id=" + sqlId + " err=" + em);
            ok = false;
        }
        if (ok) {
            String detail = engine.takeLastOkDetail();
            if (detail.isEmpty()) {
                log.logInfo(okLabel + " sql_id=" + sqlId
                        + " schema=" + (schema == null ? "" : schema)
                        + " pkg=" + pkg.getFileName());
            } else {
                log.logInfo(okLabel + " sql_id=" + sqlId
                        + " schema=" + (schema == null ? "" : schema)
                        + " " + detail
                        + " pkg=" + pkg.getFileName());
            }
        } else {
            String reason = engine.takeLastFailReason();
            if (reason.isEmpty()) {
                log.logWarn("fail sql_id=" + sqlId
                        + " schema=" + (schema == null ? "" : schema)
                        + " pkg=" + pkg.getFileName());
            } else {
                log.logWarn("fail sql_id=" + sqlId
                        + " schema=" + (schema == null ? "" : schema)
                        + " pkg=" + pkg.getFileName()
                        + " reason=" + reason);
            }
        }
        return ok;
    }

    private interface Worker<T> {
        boolean run(T target) throws Exception;
    }

    private static <T> int[] mapParallel(int parallel, List<T> targets, Worker<T> worker, int overallTimeoutSec)
            throws Exception {
        int okN = 0;
        int failN = 0;
        if (parallel <= 1 || targets.size() <= 1) {
            for (T t : targets) {
                if (worker.run(t)) {
                    okN++;
                } else {
                    failN++;
                }
            }
            return new int[] {okN, failN};
        }
        ExecutorService ex = Executors.newFixedThreadPool(Math.min(parallel, targets.size()));
        try {
            List<Future<Boolean>> futs = new ArrayList<Future<Boolean>>();
            for (final T t : targets) {
                futs.add(ex.submit(new Callable<Boolean>() {
                    public Boolean call() throws Exception {
                        return worker.run(t);
                    }
                }));
            }
            long deadlineMs = overallTimeoutSec > 0
                    ? System.currentTimeMillis() + (long) overallTimeoutSec * 1000L
                    : Long.MAX_VALUE;
            for (Future<Boolean> f : futs) {
                boolean ok;
                if (overallTimeoutSec > 0) {
                    long left = deadlineMs - System.currentTimeMillis();
                    if (left <= 0) {
                        throw new java.util.concurrent.TimeoutException("replay parallel wait");
                    }
                    ok = f.get(left, java.util.concurrent.TimeUnit.MILLISECONDS).booleanValue();
                } else {
                    ok = f.get().booleanValue();
                }
                if (ok) {
                    okN++;
                } else {
                    failN++;
                }
            }
        } finally {
            ex.shutdownNow();
            try {
                if (!ex.awaitTermination(30, java.util.concurrent.TimeUnit.SECONDS)) {
                    System.err.println("WARN: replay parallel workers did not terminate in 30s");
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        return new int[] {okN, failN};
    }

    private static boolean replayWithSessions(ReplayEngine engine, Callable<ReplayEngine.ReplayResult> task,
                                             int sessions, int overallTimeoutSec) throws Exception {
        sessions = Math.max(1, sessions);
        if (sessions == 1) {
            ReplayEngine.ReplayResult r = task.call();
            if (r.fail == 0 && r.ok > 0) {
                return true;
            }
            return r.success();
        }
        ExecutorService ex = Executors.newFixedThreadPool(sessions);
        try {
            List<Future<ReplayEngine.ReplayResult>> futs = new ArrayList<Future<ReplayEngine.ReplayResult>>();
            for (int i = 0; i < sessions; i++) {
                futs.add(ex.submit(task));
            }
            boolean okAll = true;
            long deadlineMs = overallTimeoutSec > 0
                    ? System.currentTimeMillis() + (long) overallTimeoutSec * 1000L
                    : Long.MAX_VALUE;
            for (Future<ReplayEngine.ReplayResult> f : futs) {
                ReplayEngine.ReplayResult r;
                if (overallTimeoutSec > 0) {
                    long left = deadlineMs - System.currentTimeMillis();
                    if (left <= 0) {
                        throw new java.util.concurrent.TimeoutException("replay sessions wait");
                    }
                    r = f.get(left, java.util.concurrent.TimeUnit.MILLISECONDS);
                } else {
                    r = f.get();
                }
                if (!r.success()) {
                    okAll = false;
                }
            }
            return okAll;
        } finally {
            ex.shutdownNow();
            try {
                if (!ex.awaitTermination(30, java.util.concurrent.TimeUnit.SECONDS)) {
                    System.err.println("WARN: replay session workers did not terminate in 30s");
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }

    private static Map<String, String> readMeta(Path metaPath) throws IOException {
        Map<String, String> meta = new HashMap<String, String>();
        if (!Files.isRegularFile(metaPath)) {
            return meta;
        }
        for (String line : Files.readAllLines(metaPath, StandardCharsets.UTF_8)) {
            if (line.contains("=")) {
                String[] kv = line.split("=", 2);
                meta.put(kv[0].trim(), kv[1].trim());
            }
        }
        return meta;
    }

    /** 从包目录/meta 解析增量跳过键 */
    static String packageDoneKey(Path pkg) {
        try {
            Map<String, String> meta = readMeta(pkg.resolve("meta.txt"));
            String sid = meta.get("sql_id");
            String name = pkg.getFileName().toString();
            if (sid == null || sid.isEmpty()) {
                int ix = name.indexOf("__c");
                sid = ix > 0 ? name.substring(0, ix) : name;
            }
            Integer childObj = null;
            Integer instObj = null;
            if (meta.containsKey("child_number")) {
                childObj = Integer.valueOf(parseMetaInt(meta.get("child_number"), 0));
            }
            if (meta.containsKey("inst_id")) {
                instObj = Integer.valueOf(parseMetaInt(meta.get("inst_id"), 1));
            }
            if (childObj == null || instObj == null) {
                int cAt = name.indexOf("__c");
                int iAt = name.indexOf("__i");
                if (cAt > 0 && iAt > cAt) {
                    try {
                        if (childObj == null) {
                            childObj = Integer.valueOf(name.substring(cAt + 3, iAt));
                        }
                        if (instObj == null) {
                            instObj = Integer.valueOf(name.substring(iAt + 3));
                        }
                    } catch (NumberFormatException ignored) {
                    }
                }
            }
            int child = childObj == null ? 0 : childObj.intValue();
            int inst = instObj == null ? 1 : instObj.intValue();
            return ReplayResultCsv.key(sid, child, inst);
        } catch (IOException e) {
            return null;
        }
    }

    private static int parseMetaInt(String s, int def) {
        if (s == null || s.trim().isEmpty()) {
            return def;
        }
        try {
            return Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }

    private static List<String> filterSqlIdsByDone(List<String> sqlIds,
                                                   java.util.Set<String> doneKeys,
                                                   boolean skipDone,
                                                   DualLogger log) {
        if (!skipDone || doneKeys == null || doneKeys.isEmpty()) {
            return sqlIds;
        }
        List<String> out = new ArrayList<String>();
        int skipped = 0;
        for (String sid : sqlIds) {
            if (ReplayResultCsv.hasOkExecForSqlId(doneKeys, sid)) {
                skipped++;
                log.logDbg("skip already-ok sql_id=" + sid);
                continue;
            }
            out.add(sid);
        }
        if (skipped > 0) {
            log.logInfo("sql_id skipped=" + skipped + " remain=" + out.size());
        }
        return out;
    }

    static List<String> parseSqlIdList(String raw) {
        List<String> out = new ArrayList<String>();
        if (raw == null || raw.trim().isEmpty()) {
            return out;
        }
        for (String part : raw.split(",")) {
            String sid = part.trim();
            if (!sid.isEmpty()) {
                out.add(sid);
            }
        }
        return out;
    }

    private static String join(List<String> parts) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < parts.size(); i++) {
            if (i > 0) {
                sb.append(",");
            }
            sb.append(parts.get(i));
        }
        return sb.toString();
    }
}
