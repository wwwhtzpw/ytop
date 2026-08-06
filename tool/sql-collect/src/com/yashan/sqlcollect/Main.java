package com.yashan.sqlcollect;

import com.yashan.sqlcollect.cli.Args;
import com.yashan.sqlcollect.collect.CollectCommand;
import com.yashan.sqlcollect.replay.ReplayCommand;
import com.yashan.sqlcollect.sqlmap.SqlMapCommand;

import java.util.logging.Level;
import java.util.logging.Logger;

/** 入口: collect | replay | check | sqlmap | top | --version | -h */
public class Main {

    public static void main(String[] argv) {
        quietYashanJdbcJul();
        if (!Version.ensureRuntimeSupported()) {
            System.exit(1);
        }
        Args args = Args.parse(argv);
        if (args.version) {
            System.out.println("sql-collect " + Version.VERSION
                    + " (Java " + Version.MIN_JAVA_MAJOR + "+; runtime "
                    + System.getProperty("java.version", "?") + ")");
            System.exit(0);
        }
        if (args.help) {
            if ("sqlmap".equals(args.command)) {
                SqlMapCommand.printHelp();
                System.exit(0);
            }
            if ("top".equals(args.command)) {
                com.yashan.sqlcollect.collect.TopCommand.printHelp();
                System.exit(0);
            }
            printHelp();
            System.exit(0);
        }
        int rc;
        if ("replay".equals(args.command)) {
            rc = new ReplayCommand().run(args);
        } else if ("check".equals(args.command)) {
            rc = new CheckCommand().run(args);
        } else if ("sqlmap".equals(args.command)) {
            rc = new SqlMapCommand().run(args);
        } else if ("top".equals(args.command)) {
            rc = new com.yashan.sqlcollect.collect.TopCommand().run(args);
        } else {
            rc = new CollectCommand().run(args);
        }
        System.exit(rc);
    }

    private static void printHelp() {
        System.out.println("sql-collect " + Version.VERSION + " - JDBC SQL collect + replay + sqlmap");
        System.out.println("Requires Java " + Version.MIN_JAVA_MAJOR
                + "+ (bytecode target 8; tested on 8/11/17/21).");
        System.out.println();
        System.out.println("Usage:");
        System.out.println("  sql-collect [--version|-V] [--help|-h]");
        System.out.println("  sql-collect check   [options]");
        System.out.println("  sql-collect collect [options]");
        System.out.println("  sql-collect replay  [options]");
        System.out.println("  sql-collect top     [options]   rank reports/*.txt by db_time");
        System.out.println("  sql-collect sqlmap  <subcommand> [options]");
        System.out.println();
        System.out.println("Commands:");
        Args.helpOpt("check", "JDBC health check before long collect/replay");
        Args.helpOpt("collect", "Poll SQL, backup HTZ_GV_* and/or write reports by --sink");
        Args.helpOpt("replay", "Replay SQL from file / HTZ package / gv$");
        Args.helpOpt("top", "Rank SQL from reports/*.txt (default sort: db_time)");
        Args.helpOpt("sqlmap", "SQLMAP toolkit (see: sql-collect sqlmap -h)");
        System.out.println();
        System.out.println("Global options:");
        Args.helpOpt("-h, --help", "Show this help and exit");
        Args.helpOpt("-V, --version", "Print version and exit");
        System.out.println();
        System.out.println("Check options:");
        Args.helpOpt("-j, --jdbc-config <file>", "JDBC ini path (default: ./jdbc_replay.ini)");
        Args.helpOpt("-l, --log-dir <dir>", "Log directory (default: ./logs)");
        Args.helpOpt("-d, --debug [bool]", "Debug logging (default: on; -d false to disable)");
        System.out.println();
        System.out.println("Collect options:");
        Args.helpOpt("-o, --outdir <dir>", "Base output dir (default: ./sql_collect);");
        Args.helpOpt("", "runs under DIR/yyyyMMddHHmmss");
        Args.helpOpt("-n, --new-run", "Create a new timestamp run dir (default: reuse latest)");
        Args.helpOpt("-l, --log-dir <dir>", "Log directory (default: ./logs)");
        Args.helpOpt("-j, --jdbc-config <file>", "JDBC ini path (default: ./jdbc_replay.ini)");
        Args.helpOpt("-I, --init-config", "Write jdbc_replay.ini template");
        Args.helpOpt("-w, --overwrite", "With -I/--init-config, replace existing file");
        Args.helpOpt("-i, --interval <sec>", "Poll interval seconds (default: 60 if neither -i nor -c;");
        Args.helpOpt("", "with -c only: default 600; -n creates run dir once, rounds reuse it)");
        Args.helpOpt("-c, --count <n>", "Number of collect rounds (default: unlimited)");
        System.out.println();
        System.out.println("  Sink modes (--sink, default: both):");
        Args.helpOpt("  file", "live gv$/v$ -> reports(+replay); no HTZ writes");
        Args.helpOpt("", "alias: -K / --skip-backup");
        Args.helpOpt("  backup", "live gv$/v$ -> HTZ_GV_* only; no reports/replay");
        Args.helpOpt("  both", "live -> HTZ_GV_* -> reports(+replay); read HTZ");
        Args.helpOpt("  table", "HTZ_GV_* -> reports(+replay); no BackupService");
        Args.helpOpt("--sink <mode>", "Select sink: file | backup | both | table (default: both)");
        Args.helpOpt("-K, --skip-backup", "Alias for --sink file");
        Args.helpOpt("-B, --backup-only", "REMOVED; use --sink backup (errors if used)");
        Args.helpOpt("-X, --skip-replay-export", "Skip replay/ for file|table|both (reports only);");
        Args.helpOpt("", "error with backup");
        Args.helpOpt("-s, --sql-id <id[,id...]>", "Collect ONLY these sql_id(s) (manual one-shot;");
        Args.helpOpt("", "skips candidate scan; comma-separated OK)");
        Args.helpOpt("-T, --report-timeout <sec>", "Report gather timeout (default: 600; 0=unlimited)");
        Args.helpOpt("-E, --explain-plan", "Also append EXPLAIN PLAN (default off;");
        Args.helpOpt("", "SELECT/WITH CTE only via v$sql.COMMAND_TYPE; no exec)");
        Args.helpOpt("--include-uncaptured-binds", "Also backup gv$sql_bind_capture rows with");
        Args.helpOpt("", "WAS_CAPTURED=NO / empty last_captured (default: skip them)");
        Args.helpOpt("-U, --exclude-schemas <list>", "Extra parsing_schema to skip (comma/space);");
        Args.helpOpt("", "builtin SYS,SYSDBA,SYSTEM; also jdbc_replay.ini exclude-schemas");
        Args.helpOpt("-u, --include-schemas <list>", "Only collect these parsing_schema (comma/space);");
        Args.helpOpt("", "empty=all except exclude; also jdbc_replay.ini include-schemas");
        Args.helpOpt("--active-session [bool]", "Prioritize sql_id from gv$/v$session (default: on)");
        Args.helpOpt("--no-active-session", "Disable session scan (alias: --active-session false)");
        Args.helpOpt("-A, --schema-via-alter", "ALTER SESSION for current_schema on connect");
        Args.helpOpt("-C, --current-schema <name>", "Optional schema for collect session");
        Args.helpOpt("-d, --debug [bool]", "Debug logging (default: on)");
        Args.helpOpt("--no-debug", "Alias for -d false (long-only)");
        System.out.println();
        System.out.println("Replay options:");
        Args.helpOpt("-j, --jdbc-config <file>", "JDBC ini path (default: ./jdbc_replay.ini)");
        Args.helpOpt("-I, --init-config", "Write jdbc_replay.ini template");
        Args.helpOpt("-w, --overwrite", "With -I/--init-config, replace existing file");
        Args.helpOpt("-S, --source <mode>", "Replay source: file | gv (default: file)");
        Args.helpOpt("", "(htz / HTZ_SQL_REPLAY_PKG removed)");
        Args.helpOpt("-s, --sql-id <id[,id...]>", "Target sql_id(s)");
        Args.helpOpt("-o, --outdir <dir>", "Base dir (default: ./sql_collect); latest run or -n");
        Args.helpOpt("-n, --new-run", "Create a new timestamp run dir");
        Args.helpOpt("-D, --dry-run", "Validate only (DEFAULT; no execute)");
        Args.helpOpt("-e, --exec", "LIVE execute (required for real replay)");
        Args.helpOpt("-f, --force", "Allow non-query SQL (with --exec)");
        Args.helpOpt("-a, --replay-all", "Backup replay_results.csv then replay all");
        Args.helpOpt("", "(default: incremental skip already-ok)");
        Args.helpOpt("-p, --parallel <n>", "Parallel targets (default: 1)");
        Args.helpOpt("-N, --sessions <n>", "Concurrent sessions per SQL (default: 1)");
        Args.helpOpt("-t, --timeout <sec>", "Overall replay timeout (default: 600; 0=unlimited;");
        Args.helpOpt("", "exit 124 on timeout)");
        Args.helpOpt("-R, --results-csv <path>", "replay_results.csv path (default: RUN_DIR/...)");
        Args.helpOpt("-A, --schema-via-alter", "Login as jdbc user + ALTER SESSION");
        Args.helpOpt("-M, --on-sha-mismatch <mode>", "fail=block (DEFAULT); warn=WARN then continue");
        Args.helpOpt("--allow-sha-mismatch", "Alias for -M warn (long-only)");
        Args.helpOpt("-d, --debug [bool]", "Debug logging (default: on)");
        Args.helpOpt("--no-debug", "Alias for -d false (long-only)");
        Args.helpOpt("-l, --log-dir <dir>", "Log directory (default: ./logs)");
        System.out.println();
        System.out.println("Notes:");
        System.out.println("  - Short options: common=lowercase, uncommon=UPPERCASE.");
        System.out.println("  - Long-only aliases: --no-debug, --allow-sha-mismatch.");
        System.out.println("  - sqlmap has its own short-option map (sql-collect sqlmap -h).");
        System.out.println("  - top is offline (scans reports/*.txt; no JDBC). See: sql-collect top -h");
        System.out.println("  - Scope note: collect/replay -n=new-run; sqlmap -n=map-name.");
        System.out.println();
        System.out.println("Top options (see also: sql-collect top -h):");
        Args.helpOpt("-o, --outdir <dir>", "Collect base or run dir (default: ./sql_collect)");
        Args.helpOpt("--run <yyyyMMddHHmmss>", "Run subdirectory under -o");
        Args.helpOpt("-L, --limit <n>", "Show top N (default: 50; 0=all)");
        Args.helpOpt("--sort <col[:asc|desc]>", "Default db_time:desc");
        Args.helpOpt("--csv <file>", "Export shown rows to CSV");
        System.out.println();
        System.out.println("Examples:");
        System.out.println("  sql-collect check -j jdbc_replay.ini");
        System.out.println("  sql-collect collect -j jdbc_replay.ini -o ./sql_collect -c 1 -n");
        System.out.println("  sql-collect collect --sink file -j jdbc_replay.ini -o ./sql_collect -c 1 -n");
        System.out.println("  sql-collect collect --sink backup -j jdbc_replay.ini -o ./sql_collect -c 1 -n");
        System.out.println("  sql-collect collect --sink table -j jdbc_replay.ini -o ./sql_collect -c 1 -n");
        System.out.println("  sql-collect collect -s <sql_id> -j jdbc_replay.ini -o ./sql_collect -n");
        System.out.println("  sql-collect collect -s <sql_id> -K -j jdbc_replay.ini -o ./sql_collect -n");
        System.out.println("  sql-collect collect -s <sql_id> -E -K -n -j jdbc_replay.ini -o ./sql_collect");
        System.out.println("  sql-collect collect -I -w -j jdbc_replay.ini");
        System.out.println("  sql-collect top -o ./sql_collect -L 20");
        System.out.println("  sql-collect top -o ./sql_collect --sort cpu --csv top.csv");
        System.out.println("  sql-collect replay -S gv -s <sql_id> -e -j jdbc_replay.ini");
        System.out.println("  sql-collect replay -S file -a -D -j jdbc_replay.ini");
        System.out.println("  sql-collect sqlmap create -s <src> -t <tgt> -n m1 -j jdbc_replay.ini");
        System.out.println("  sql-collect sqlmap -h");
    }

    /**
     * 压制 YashanDB JDBC 驱动 JUL INFO 噪音 (如 maxStringLen), 避免刷 stderr/终端.
     * WARNING 及以上仍可见.
     */
    static void quietYashanJdbcJul() {
        try {
            Logger.getLogger("com.yashandb").setLevel(Level.WARNING);
            Logger.getLogger("com.yashandb.log").setLevel(Level.WARNING);
            Logger.getLogger("com.yashandb.jdbc").setLevel(Level.WARNING);
        } catch (Exception ignored) {
            // JUL 不可用时忽略
        }
    }
}
