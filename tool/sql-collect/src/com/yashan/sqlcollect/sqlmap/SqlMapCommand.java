package com.yashan.sqlcollect.sqlmap;

import com.yashan.sqlcollect.cli.Args;
import com.yashan.sqlcollect.config.JdbcConfig;
import com.yashan.sqlcollect.db.JdbcPool;
import com.yashan.sqlcollect.log.DualLogger;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Locale;

/** sqlmap 子命令入口 */
public class SqlMapCommand {

    public static final String DEFAULT_LOG_DIR = "logs";

    public int run(Args top) {
        DualLogger log = null;
        try {
            SqlMapArgs a = SqlMapArgs.parse(top.sqlmapArgv);
            if (a.help || top.subcommand == null || top.subcommand.isEmpty()) {
                printHelp();
                return 0;
            }
            Path logDir = Paths.get(a.opt("log-dir", DEFAULT_LOG_DIR));
            boolean debug = a.resolveDebug();
            log = new DualLogger(logDir, "sqlmap", debug);
            log.logInfo("sqlmap subcommand=" + top.subcommand + " debug=" + debug);
            return dispatch(top.subcommand.toLowerCase(Locale.ROOT), a, log);
        } catch (IOException e) {
            System.err.println("[ERROR] log init failed: " + e.getMessage());
            return 2;
        } finally {
            if (log != null) {
                log.close();
            }
        }
    }

    private int dispatch(String sub, SqlMapArgs a, DualLogger log) {
        if ("lit2bind".equals(sub)) {
            String err = a.validateLit2bind();
            if (err != null) {
                log.logError(err);
                return 2;
            }
            return runLit2bind(a, log);
        }

        String cfgPath = a.opt("jdbc-config", JdbcConfig.DEFAULT_CONFIG);
        JdbcConfig cfg;
        try {
            cfg = JdbcConfig.load(cfgPath);
        } catch (IOException e) {
            log.logError(e.getMessage());
            return 2;
        }
        if (a.flag("schema-via-alter")) {
            cfg.schemaViaAlter = true;
        }
        String cur = a.opt("current-schema", null);
        if (cur != null && !cur.trim().isEmpty()) {
            cfg.currentSchema = cur.trim();
        }

        JdbcPool pool = new JdbcPool(log, JdbcPool.DEFAULT_MAX_IDLE_PER_USER);
        try {
            if ("export".equals(sub)) {
                String err = a.validateExport();
                if (err != null) {
                    log.logError(err);
                    return 2;
                }
                return SqlMapIo.exportSql(cfg, pool, a, log);
            }
            if ("genbind".equals(sub)) {
                String err = a.validateGenbind();
                if (err != null) {
                    log.logError(err);
                    return 2;
                }
                return SqlMapIo.genbind(cfg, pool, a, log);
            }
            if ("list".equals(sub)) {
                return SqlMapCatalog.list(cfg, pool, a, log);
            }
            if ("show".equals(sub)) {
                String err = a.validateShow();
                if (err != null) {
                    log.logError(err);
                    return 2;
                }
                return SqlMapCatalog.show(cfg, pool, a, log);
            }
            if ("drop".equals(sub)) {
                String err = a.validateDrop();
                if (err != null) {
                    log.logError(err);
                    return 2;
                }
                return SqlMapCatalog.drop(cfg, pool, a, log);
            }
            if ("create".equals(sub)) {
                String err = a.validateCreate();
                if (err != null) {
                    log.logError(err);
                    return 2;
                }
                return SqlMapDdl.create(cfg, pool, a, log);
            }
            if ("genexec".equals(sub)) {
                String err = a.validateGenexec();
                if (err != null) {
                    log.logError(err);
                    return 2;
                }
                return SqlMapExec.genexec(cfg, pool, a, log);
            }
            if ("perf".equals(sub)) {
                String err = a.validatePerf();
                if (err != null) {
                    log.logError(err);
                    return 2;
                }
                return SqlMapExec.perf(cfg, pool, a, log);
            }
            if ("verify".equals(sub)) {
                String err = a.validateVerify();
                if (err != null) {
                    log.logError(err);
                    return 2;
                }
                return SqlMapVerify.verify(cfg, pool, a, log);
            }
            log.logError("unknown sqlmap subcommand: " + sub);
            printHelp();
            return 2;
        } finally {
            pool.close();
        }
    }

    private static int runLit2bind(SqlMapArgs a, DualLogger log) {
        try {
            Path in = Paths.get(a.opt("sql-file", ""));
            String sql = new String(Files.readAllBytes(in), StandardCharsets.UTF_8);
            String fmt = a.opt("bind-format", "?");
            Lit2Bind.Result r = Lit2Bind.convert(sql, fmt);
            String outSql = a.opt("out", null);
            if (outSql == null || outSql.isEmpty()) {
                String name = in.getFileName().toString();
                outSql = "bind_" + name;
            }
            String bindOut = a.opt("bind-out", "bind_values.txt");
            Files.write(Paths.get(outSql), r.sql.getBytes(StandardCharsets.UTF_8));
            StringBuilder bv = new StringBuilder();
            for (String v : r.values) {
                bv.append(v == null ? "NULL" : v).append('\n');
            }
            Files.write(Paths.get(bindOut), bv.toString().getBytes(StandardCharsets.UTF_8));
            log.logInfo("lit2bind wrote sql=" + outSql + " binds=" + bindOut
                    + " placeholders=" + r.values.size());
            System.out.println("[OK] lit2bind sql=" + outSql + " binds=" + bindOut
                    + " n=" + r.values.size());
            return 0;
        } catch (IOException e) {
            log.logError("lit2bind failed: " + e.getMessage());
            return 1;
        }
    }

    public static void printHelp() {
        System.out.println("sql-collect sqlmap - JDBC SQLMAP toolkit");
        System.out.println();
        System.out.println("Usage:");
        System.out.println("  sql-collect sqlmap <subcommand> [options]");
        System.out.println();
        System.out.println("Subcommands:");
        Args.helpOpt("create", "Create SQLMAP from source/target (sql_id or SQL file)");
        Args.helpOpt("list", "List rows in SYS.SQL_MAP$");
        Args.helpOpt("show", "Show one SQLMAP by --map-name or --sql-id");
        Args.helpOpt("drop", "DROP SQLMAP by --map-name");
        Args.helpOpt("export", "Export sql_fulltext for -s/--src-sql-id");
        Args.helpOpt("genbind", "Export captured bind values for -s/--src-sql-id");
        Args.helpOpt("genexec", "Prepare/run target SQL with binds (-t or -f)");
        Args.helpOpt("lit2bind", "Offline: rewrite literals to bind placeholders");
        Args.helpOpt("perf", "Compare client elapsed of source vs target");
        Args.helpOpt("verify", "Verify map/pair: --verify MODE (requires --exec)");
        System.out.println();
        System.out.println("Common options:");
        Args.helpOpt("-h, --help", "Show this help and exit");
        Args.helpOpt("-j, --jdbc-config <file>", "JDBC ini path (default: jdbc_replay.ini)");
        Args.helpOpt("-l, --log-dir <dir>", "Log directory (default: logs)");
        Args.helpOpt("-d, --debug [bool]", "Debug logging (default: on; use -d false to disable)");
        Args.helpOpt("--no-debug", "Disable debug logging");
        Args.helpOpt("-e, --exec, --run", "Actually execute SQL (genexec/perf/verify)");
        Args.helpOpt("-A, --schema-via-alter", "Switch schema via ALTER SESSION");
        Args.helpOpt("-C, --current-schema <user>", "Set current schema before SQL");
        Args.helpOpt("-o, --out <file>", "Output file (export/genbind/genexec/create dry-run)");
        Args.helpOpt("-b, --bind-file <arg>", "Binds: <file> | backup | view");
        Args.helpOpt("", "file=one value per line (or pos|type|val);");
        Args.helpOpt("", "backup=HTZ_GV_SQL_BIND_CAPTURE; view=gv$/v$sql_bind_capture;");
        Args.helpOpt("", "backup|view require -s/--src-sql-id");
        System.out.println();
        System.out.println("Create / verify source-target options:");
        Args.helpOpt("-s, --src-sql-id <id>", "Source sql_id from gv$/v$sql");
        Args.helpOpt("-r, --src-file <file>", "Source SQL text file (mutex with -s)");
        Args.helpOpt("-t, --tgt-sql-id <id>", "Target sql_id from gv$/v$sql");
        Args.helpOpt("-f, --sql-file <file>", "Target SQL text file (mutex with -t;");
        Args.helpOpt("", "also input file for lit2bind)");
        Args.helpOpt("-n, --map-name <name>", "SQLMAP name (create/show/drop/verify); create default: map_<sqlId|f_<hash>>_<tsms>_<rnd>");
        Args.helpOpt("-u, --map-user <user>", "SQLMAP user scope (default: ALL)");
        Args.helpOpt("-S, --sql-id <id>", "Lookup SQLMAP by source sql_id (show only)");
        Args.helpOpt("-D, --dry-run", "Print CREATE SQLMAP DDL only; do not execute");
        Args.helpOpt("-F, --flush", "After create: ALTER SYSTEM FLUSH SHARED_POOL");
        Args.helpOpt("", "(default: do not flush)");
        Args.helpOpt("-v, --verify <mode>", "Verify modes: plan | plan-eq | result | unordered");
        Args.helpOpt("", "(comma-separated or repeatable; needs --exec)");
        Args.helpOpt("-k, --marker <text>", "Optional marker filter for verify/genexec");
        Args.helpOpt("-L, --limit <n>", "Max rows for list (default: 500)");
        System.out.println();
        System.out.println("lit2bind options:");
        Args.helpOpt("-f, --sql-file <file>", "Input SQL with literals (required)");
        Args.helpOpt("-B, --bind-format <fmt>", "Placeholder style: ? or :bN (default: ?)");
        Args.helpOpt("-W, --bind-out <file>", "Bind values output (default: bind_values.txt)");
        Args.helpOpt("-o, --out <file>", "Rewritten SQL output (default: bind_<input>)");
        System.out.println();
        System.out.println("Notes:");
        System.out.println("  - Short -t means --tgt-sql-id (not a timeout).");
        System.out.println("  - Short -S means --sql-id for show (not -s/--src-sql-id).");
        System.out.println("  - Common=lowercase, uncommon=UPPERCASE (-D/-F/-L/-S/-B/-W/-A/-C).");
        System.out.println("  - Long-only: --no-debug, --run (alias of -e/--exec).");
        System.out.println("  - CREATE uses JDBC Statement.execute(CREATE SQLMAP ...);");
        System.out.println("    no DBMS_SQL wrapper and no UPDATE SYS.SQL_MAP$.");
        System.out.println("  - Source/target should be the same SQL type (e.g. both WITH),");
        System.out.println("    or the engine may raise YAS-04810.");
        System.out.println("  - show/export -S/--sql-id need the cursor still in gv$/v$sql.");
        System.out.println("  - -b backup|view: only last_captured IS NOT NULL rows.");
        System.out.println();
        System.out.println("Examples:");
        System.out.println("  sql-collect sqlmap create -s <src_id> -t <tgt_id> -n m1 -j jdbc.ini");
        System.out.println("  sql-collect sqlmap create -r src.sql -f tgt.sql -n m1 -F -j jdbc.ini");
        System.out.println("  sql-collect sqlmap show -n m1 -j jdbc.ini");
        System.out.println("  sql-collect sqlmap show -S <src_id> -j jdbc.ini");
        System.out.println("  sql-collect sqlmap drop -n m1 -j jdbc.ini");
        System.out.println("  sql-collect sqlmap verify -n m1 -v result -e -b backup -s <src_id> -j jdbc.ini");
        System.out.println("  sql-collect sqlmap verify -s <src> -t <tgt> -v result -e -b view -j jdbc.ini");
        System.out.println("  sql-collect sqlmap export -s <src_id> -o src.sql -j jdbc.ini");
        System.out.println("  sql-collect sqlmap genbind -s <src_id> -b backup -o binds.txt -j jdbc.ini");
        System.out.println("  sql-collect sqlmap genbind -s <src_id> -b view -o binds.txt -j jdbc.ini");
        System.out.println("  sql-collect sqlmap genexec -t <tgt_id> -b binds.txt -e -j jdbc.ini");
        System.out.println("  sql-collect sqlmap perf -s <src_id> -t <tgt_id> -b backup -e -j jdbc.ini");
        System.out.println("  sql-collect sqlmap lit2bind -f lit.sql -B :bN -o bind.sql -W binds.txt");
        System.out.println("  sql-collect sqlmap list -L 100 -j jdbc.ini");
        System.out.println("  sql-collect sqlmap create -s <src> -t <tgt> -n m1 -D -j jdbc.ini");
    }
}
