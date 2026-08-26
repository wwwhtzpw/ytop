package com.yashan.sqlcollect;

import com.yashan.sqlcollect.cli.Args;
import com.yashan.sqlcollect.collect.CollectCommand;
import com.yashan.sqlcollect.replay.ReplayCommand;

import java.util.logging.Level;
import java.util.logging.Logger;

/** 入口: collect | replay | check | top | --version | -h */
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
        } else if ("top".equals(args.command)) {
            rc = new com.yashan.sqlcollect.collect.TopCommand().run(args);
        } else if ("sqlmap".equals(args.command)) {
            System.err.println("Error: sqlmap moved to yjdbc. Use: ytop -E  then  \\sqlmap ...");
            System.err.println("See docs/yjdbc_sqlmap*.md under the yastop repo");
            rc = 2;
        } else {
            rc = new CollectCommand().run(args);
        }
        System.exit(rc);
    }

    private static void printHelp() {
        System.out.println("sql-collect " + Version.VERSION + " - JDBC SQL collect + replay");
        System.out.println("Requires Java " + Version.MIN_JAVA_MAJOR
                + "+ (bytecode target 8; tested on 8/11/17/21).");
        System.out.println();
        System.out.println("Usage:");
        System.out.println("  sql-collect [--version|-V] [--help|-h]");
        System.out.println("  sql-collect check   [options]");
        System.out.println("  sql-collect collect [options]");
        System.out.println("  sql-collect replay  [options]");
        System.out.println("  sql-collect top     [options]   rank reports/*.txt by db_time");
        System.out.println();
        System.out.println("Commands:");
        Args.helpOpt("check", "JDBC health check before long collect/replay");
        Args.helpOpt("collect", "Poll SQL, backup HTZ_GV_* and/or write reports by --sink");
        Args.helpOpt("replay", "Replay SQL from file / HTZ package / gv$");
        Args.helpOpt("top", "Rank SQL from reports/*.txt (default sort: db_time)");
        System.out.println();
        System.out.println("Note: SQLMAP is in yjdbc (ytop -E / \\sqlmap), not sql-collect.");
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
        System.out.println("Examples:");
        System.out.println("  sql-collect check -j jdbc_replay.ini");
        System.out.println("  sql-collect collect -j jdbc_replay.ini -o ./sql_collect -c 1 -n");
        System.out.println("  sql-collect replay -S gv -s <sql_id> -e -j jdbc_replay.ini");
        System.out.println("  sql-collect top -o ./sql_collect -L 20");
        System.out.println("  ytop -E   # then: \\sqlmap list");
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
