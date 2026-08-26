package com.yashan.yjdbc.cli;

import com.yashan.yjdbc.config.SessionConfig;

/**
 * shell 子命令 argv 解析.
 */
public final class Args {
    private Args() {
    }

    public static SessionConfig parseShell(String[] args) {
        SessionConfig cfg = new SessionConfig();
        boolean passwordSet = false;
        for (int i = 0; i < args.length; i++) {
            String tok = args[i];
            if ("--url".equals(tok)) {
                cfg.url = needValue(args, ++i, "--url");
            } else if (tok.startsWith("--url=")) {
                cfg.url = tok.substring("--url=".length());
            } else if ("--user".equals(tok)) {
                cfg.user = needValue(args, ++i, "--user");
            } else if (tok.startsWith("--user=")) {
                cfg.user = tok.substring("--user=".length());
            } else if ("--password".equals(tok)) {
                cfg.password = i + 1 < args.length ? args[++i] : "";
                passwordSet = true;
            } else if (tok.startsWith("--password=")) {
                cfg.password = tok.substring("--password=".length());
                passwordSet = true;
            } else if ("--max-rows".equals(tok)) {
                cfg.maxRows = parseInt(needValue(args, ++i, "--max-rows"), "--max-rows");
            } else if (tok.startsWith("--max-rows=")) {
                cfg.maxRows = parseInt(tok.substring("--max-rows=".length()), "--max-rows");
            } else if ("--statement-timeout-sec".equals(tok)) {
                cfg.statementTimeoutSec = parseInt(
                        needValue(args, ++i, "--statement-timeout-sec"),
                        "--statement-timeout-sec");
            } else if (tok.startsWith("--statement-timeout-sec=")) {
                cfg.statementTimeoutSec = parseInt(
                        tok.substring("--statement-timeout-sec=".length()),
                        "--statement-timeout-sec");
            } else if ("--script".equals(tok)) {
                cfg.scriptPath = needValue(args, ++i, "--script");
                cfg.batch = true;
            } else if (tok.startsWith("--script=")) {
                cfg.scriptPath = tok.substring("--script=".length());
                cfg.batch = true;
            } else if ("--batch".equals(tok)) {
                cfg.batch = true;
            } else if ("--sql-home".equals(tok)) {
                cfg.sqlHome = needValue(args, ++i, "--sql-home");
            } else if (tok.startsWith("--sql-home=")) {
                cfg.sqlHome = tok.substring("--sql-home=".length());
            } else if ("--define".equals(tok)) {
                parseDefineArg(cfg, needValue(args, ++i, "--define"));
            } else if (tok.startsWith("--define=")) {
                parseDefineArg(cfg, tok.substring("--define=".length()));
            } else if ("--help".equals(tok) || "-h".equals(tok)) {
                usage();
                System.exit(0);
            } else {
                System.err.println("Unknown option: " + tok);
                usage();
                System.exit(2);
            }
        }
        if (cfg.url == null || cfg.url.trim().isEmpty()) {
            System.err.println("Error: --url is required");
            usage();
            System.exit(2);
        }
        if (cfg.user == null || cfg.user.trim().isEmpty()) {
            System.err.println("Error: --user is required");
            usage();
            System.exit(2);
        }
        if (!passwordSet) {
            cfg.password = "";
        }
        if (cfg.maxRows < 0) {
            System.err.println("Error: --max-rows must be >= 0");
            System.exit(2);
        }
        if (cfg.statementTimeoutSec < 0) {
            System.err.println("Error: --statement-timeout-sec must be >= 0");
            System.exit(2);
        }
        return cfg;
    }

    /** NAME=VALUE */
    private static void parseDefineArg(SessionConfig cfg, String s) {
        int eq = s.indexOf('=');
        if (eq <= 0) {
            System.err.println("Error: --define expects NAME=VALUE");
            System.exit(2);
        }
        cfg.define(s.substring(0, eq).trim(), s.substring(eq + 1));
    }

    private static String needValue(String[] args, int i, String opt) {
        if (i >= args.length) {
            System.err.println("Error: missing value for " + opt);
            System.exit(2);
        }
        return args[i];
    }

    private static int parseInt(String s, String opt) {
        try {
            return Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            System.err.println("Error: invalid integer for " + opt + ": " + s);
            System.exit(2);
            return 0;
        }
    }

    public static void usage() {
        System.out.println("yjdbc shell --url <jdbcUrl> --user <u> [--password <p>]");
        System.out.println("            [--script <file>] [--sql-home <dir>] [--batch]");
        System.out.println("            [--define NAME=VALUE]...   (repeatable; for -f / batch)");
        System.out.println("            [--max-rows N]");
    }
}
