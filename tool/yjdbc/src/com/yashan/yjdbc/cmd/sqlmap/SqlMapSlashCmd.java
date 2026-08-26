package com.yashan.yjdbc.cmd.sqlmap;

import com.yashan.yjdbc.cmd.sqlmap.support.config.JdbcConfig;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcPool;
import com.yashan.yjdbc.cmd.sqlmap.support.log.DualLogger;
import com.yashan.yjdbc.config.SessionConfig;
import com.yashan.yjdbc.slash.SlashCategory;
import com.yashan.yjdbc.slash.SlashCommand;
import com.yashan.yjdbc.slash.SlashContext;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * \sqlmap — SQLMAP 工具包 (会话 JDBC; 由 sql_collect sqlmap 迁入).
 */
public final class SqlMapSlashCmd implements SlashCommand {

    private static final List<String> TOPICS = Collections.unmodifiableList(Arrays.asList(
            "create", "list", "show", "drop", "export", "genbind",
            "genexec", "lit2bind", "perf", "verify"));

    @Override
    public String name() {
        return "sqlmap";
    }

    @Override
    public String description() {
        return "SQLMAP toolkit (create/list/show/drop/verify/...)";
    }

    @Override
    public String category() {
        return SlashCategory.SQLMAP;
    }

    @Override
    public List<String> topics() {
        return TOPICS;
    }

    @Override
    public void help(PrintStream out) {
        printHelp(out);
    }

    @Override
    public void helpTopic(String topic, PrintStream out) {
        if (topic == null || topic.isEmpty()) {
            help(out);
            return;
        }
        String t = topic.toLowerCase(Locale.ROOT);
        if (!TOPICS.contains(t)) {
            out.println("Error: unknown sqlmap topic: " + topic);
            out.println("Topics: " + joinTopics());
            out.println("Try: \\help sqlmap");
            return;
        }
        out.println("\\sqlmap " + t);
        out.println();
        if ("create".equals(t)) {
            out.println("Create SQLMAP from source + target (sql_id and/or SQL file).");
            out.println("Source (exactly one):");
            helpOpt(out, "-s, --src-sql-id <id>", "Source cursor sql_id");
            helpOpt(out, "-r, --src-file <path>", "Source SQL text file");
            out.println("Target (exactly one):");
            helpOpt(out, "-t, --tgt-sql-id <id>", "Target cursor sql_id");
            helpOpt(out, "-f, --sql-file <path>", "Target SQL text file");
            out.println("Identity / behavior:");
            helpOpt(out, "-n, --map-name <name>", "Map name (default: auto)");
            helpOpt(out, "-u, --map-user <user>", "Map user (default: ALL)");
            helpOpt(out, "-D, --dry-run", "Print DDL only; no CREATE");
            helpOpt(out, "-F, --flush", "ALTER SYSTEM FLUSH SHARED_POOL after CREATE");
            helpOpt(out, "-o, --out <file>", "Write create summary (map/src/tgt lengths)");
            out.println("Optional verify-after-create (needs -e):");
            helpOpt(out, "-v, --verify <modes>", "plan|plan-eq|result|unordered (comma OK)");
            helpOpt(out, "-e, --exec", "Required if -v is set (run SQL for verify)");
            out.println("Optional binds (when -v needs binds):");
            helpOpt(out, "-b, --bind-file <arg>", "<file> | backup | view");
            helpOpt(out, "  (with backup|view)", "Requires -s for bind lookup sql_id");
            out.println("Common: -d/--no-debug -A -C (see \\sqlmap -h).");
            out.println();
            out.println("Source x target matrix (4 combos):");
            out.println("  -s + -t | -s + -f | -r + -t | -r + -f");
            out.println("Mutex: -s vs -r; -t vs -f.");
            out.println();
            out.println("Examples:");
            out.println("  \\sqlmap create -r src.sql -f tgt.sql -n m1 -D");
            out.println("  \\sqlmap create -s <sid> -f tgt.sql -n m1 -F -v result -e");
            out.println("  \\sqlmap create -s <sid> -t <tid> -n m1");
        } else if ("list".equals(t)) {
            out.println("List rows in SYS.SQL_MAP$ (name, user, hash, lengths, text prefix).");
            helpOpt(out, "-L, --limit <n>", "Max rows to show (default 500)");
            out.println("Common: -d/--no-debug.");
            out.println();
            out.println("Example:");
            out.println("  \\sqlmap list -L 50 --no-debug");
        } else if ("show".equals(t)) {
            out.println("Show one SQLMAP (full SRC/TGT CLOB text).");
            out.println("Lookup (exactly one):");
            helpOpt(out, "-n, --map-name <name>", "By map name");
            helpOpt(out, "-S, --sql-id <id>", "By source sql_id (hash / name prefix)");
            out.println("Mutex: -n vs -S.");
            out.println("Common: -d/--no-debug.");
            out.println();
            out.println("Examples:");
            out.println("  \\sqlmap show -n m1");
            out.println("  \\sqlmap show -S <sql_id>");
        } else if ("drop".equals(t)) {
            out.println("DROP SQLMAP by name.");
            helpOpt(out, "-n, --map-name <name>", "Required");
            out.println("Common: -d/--no-debug.");
            out.println();
            out.println("Example:");
            out.println("  \\sqlmap drop -n m1");
        } else if ("export".equals(t)) {
            out.println("Export sql_fulltext for a cursor sql_id to a file.");
            helpOpt(out, "-s, --src-sql-id <id>", "Required");
            helpOpt(out, "-o, --out <file>", "Output path (default: sql_<id>.sql)");
            out.println("Common: -d/--no-debug -A -C.");
            out.println();
            out.println("Example:");
            out.println("  \\sqlmap export -s <sid> -o src.sql");
        } else if ("genbind".equals(t)) {
            out.println("Export captured bind values for a cursor sql_id.");
            helpOpt(out, "-s, --src-sql-id <id>", "Required");
            helpOpt(out, "-o, --out <file>", "Output path (default: bind_<id>.txt)");
            helpOpt(out, "-b, --bind-file <kw>", "Optional source: backup | view only");
            out.println("Note: genbind -b cannot be a file path (use -o for output).");
            out.println("  Omit -b to auto-pick captured binds for -s.");
            out.println("Common: -d/--no-debug -A -C.");
            out.println();
            out.println("Examples:");
            out.println("  \\sqlmap genbind -s <sid> -o binds.txt");
            out.println("  \\sqlmap genbind -s <sid> -b view -o binds.txt");
        } else if ("genexec".equals(t)) {
            out.println("Prepare (and optionally execute) target SQL with binds.");
            out.println("Target (exactly one):");
            helpOpt(out, "-t, --tgt-sql-id <id>", "Load SQL text from cursor");
            helpOpt(out, "-f, --sql-file <path>", "Load SQL text from file");
            out.println("Binds (optional):");
            helpOpt(out, "-b, --bind-file <arg>", "<file> | backup | view");
            helpOpt(out, "  (backup|view)", "Requires -s/--src-sql-id for lookup");
            helpOpt(out, "-s, --src-sql-id <id>", "Bind lookup sql_id (also auto-bind if no -b)");
            out.println("Run / audit:");
            helpOpt(out, "-e, --exec, --run", "Actually execute (else dry prepare)");
            helpOpt(out, "-k, --marker <str>", "Append /* marker */ into SQL text");
            helpOpt(out, "-o, --out <file>", "Write prepared/audit SQL");
            out.println("Mutex: -t vs -f.");
            out.println("Common: -d/--no-debug -A -C.");
            out.println();
            out.println("Examples:");
            out.println("  \\sqlmap genexec -f tgt.sql");
            out.println("  \\sqlmap genexec -f tgt.sql -b binds.txt -e -o audit.sql");
            out.println("  \\sqlmap genexec -t <tid> -s <sid> -b view -e");
        } else if ("lit2bind".equals(t)) {
            out.println("Offline: rewrite literals in a SQL file to bind placeholders.");
            helpOpt(out, "-f, --sql-file <path>", "Required input SQL file");
            helpOpt(out, "-B, --bind-format <fmt>", "? (default) or :bN");
            helpOpt(out, "-o, --out <file>", "Rewritten SQL (default: bind_<infile>)");
            helpOpt(out, "-W, --bind-out <file>", "Extracted values (default: bind_values.txt)");
            out.println("No DB round-trip. Common: -d/--no-debug.");
            out.println();
            out.println("Examples:");
            out.println("  \\sqlmap lit2bind -f lit.sql -o out.sql -W binds.txt");
            out.println("  \\sqlmap lit2bind -f lit.sql -B :bN");
        } else if ("perf".equals(t)) {
            out.println("Compare client elapsed (and plan stats when available) src vs tgt.");
            helpOpt(out, "-s, --src-sql-id <id>", "Required source cursor");
            out.println("Target (exactly one):");
            helpOpt(out, "-t, --tgt-sql-id <id>", "Target cursor");
            helpOpt(out, "-f, --sql-file <path>", "Target SQL file");
            out.println("Binds / run:");
            helpOpt(out, "-b, --bind-file <arg>", "<file> | backup | view (view/backup need -s)");
            helpOpt(out, "-e, --exec", "Execute both sides (else dry / prepare only)");
            helpOpt(out, "-k, --marker <str>", "Marker comment for cursor lookup");
            helpOpt(out, "-o, --out <file>", "Write perf summary lines");
            out.println("Mutex: -t vs -f.");
            out.println("Common: -d/--no-debug -A -C.");
            out.println();
            out.println("Examples:");
            out.println("  \\sqlmap perf -s <sid> -f tgt.sql -o perf.txt");
            out.println("  \\sqlmap perf -s <sid> -t <tid> -e -o perf.txt");
        } else if ("verify".equals(t)) {
            out.println("Verify a map or a src/tgt pair. Always requires -e/--exec.");
            out.println("Modes (-v/--verify, required; comma or repeat OK):");
            helpOpt(out, "plan", "Capture/compare plan hashes");
            helpOpt(out, "plan-eq", "Require equal plan hash");
            helpOpt(out, "result", "Compare result sets");
            helpOpt(out, "unordered", "With result: ignore row order");
            out.println("Path A - existing map:");
            helpOpt(out, "-n, --map-name <name>", "Load SRC/TGT from SQL_MAP$");
            helpOpt(out, "-s + -b backup|view", "Optional: binds from sql_id (only extra with -n)");
            out.println("Path B - text matrix (same 4 combos as create):");
            helpOpt(out, "-s/-r and -t/-f", "Exactly one source + one target");
            out.println("Binds: -b <file>|backup|view (backup|view needs -s).");
            helpOpt(out, "-k, --marker <str>", "Optional marker for stats lookup");
            helpOpt(out, "-A / -C", "Schema switch before exec");
            out.println("Mutex: -n vs full text matrix (except -n -s -b backup|view).");
            out.println("Removed: --verify-plan / --verify-result / ... use -v instead.");
            out.println();
            out.println("Examples:");
            out.println("  \\sqlmap verify -n m1 -v result -e");
            out.println("  \\sqlmap verify -n m1 -v plan,result -e");
            out.println("  \\sqlmap verify -r src.sql -f tgt.sql -v result -e");
            out.println("  \\sqlmap verify -n m1 -s <sid> -b view -v result -e");
        }
        out.println();
        out.println("Full help: \\sqlmap -h");
    }

    @Override
    public int run(SlashContext ctx, List<String> argv) throws Exception {
        List<String> args = argv == null ? Collections.<String>emptyList()
                : new ArrayList<String>(argv);
        if (args.isEmpty() || isHelpOnly(args)) {
            help(ctx.out());
            return 0;
        }
        String sub = args.get(0);
        List<String> rest = args.subList(1, args.size());
        if ("-h".equals(sub) || "--help".equals(sub)) {
            help(ctx.out());
            return 0;
        }
        SqlMapArgs a = SqlMapArgs.parse(rest);
        if (a.help) {
            helpTopic(sub, ctx.out());
            return 0;
        }
        boolean debug = a.resolveDebug();
        DualLogger log = new DualLogger(ctx.out(), ctx.err(), debug);
        try {
            log.logInfo("sqlmap subcommand=" + sub + " debug=" + debug);
            if (a.opt("jdbc-config", null) != null) {
                log.logWarn("-j/--jdbc-config ignored; using current yjdbc session");
            }
            if (a.opt("log-dir", null) != null) {
                log.logWarn("-l/--log-dir ignored in yjdbc \\sqlmap (stdout/stderr only)");
            }
            return dispatch(ctx, sub.toLowerCase(Locale.ROOT), a, log);
        } finally {
            log.close();
        }
    }

    private int dispatch(SlashContext ctx, String sub, SqlMapArgs a, DualLogger log)
            throws SQLException {
        if ("lit2bind".equals(sub)) {
            String err = a.validateLit2bind();
            if (err != null) {
                log.logError(err);
                return 2;
            }
            return runLit2bind(a, log, ctx.out());
        }

        JdbcConfig cfg = sessionConfig(ctx);
        if (a.flag("schema-via-alter")) {
            cfg.schemaViaAlter = true;
        }
        String cur = a.opt("current-schema", null);
        if (cur != null && !cur.trim().isEmpty()) {
            cfg.currentSchema = cur.trim();
            cfg.schemaViaAlter = true;
        }

        Connection conn = ctx.db().connection();
        JdbcPool pool = new JdbcPool(conn, log);
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
            help(ctx.out());
            return 2;
        } finally {
            pool.close();
        }
    }

    private static JdbcConfig sessionConfig(SlashContext ctx) {
        JdbcConfig cfg = new JdbcConfig();
        SessionConfig sc = ctx.session().config();
        cfg.jdbcUrl = sc.url == null ? "" : sc.url;
        cfg.user = sc.user == null ? "" : sc.user;
        cfg.password = sc.password == null ? "" : sc.password;
        return cfg;
    }

    private static int runLit2bind(SqlMapArgs a, DualLogger log, PrintStream out) {
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
            out.println("[OK] lit2bind sql=" + outSql + " binds=" + bindOut
                    + " n=" + r.values.size());
            return 0;
        } catch (IOException e) {
            log.logError("lit2bind failed: " + e.getMessage());
            return 1;
        }
    }

    private static boolean isHelpOnly(List<String> args) {
        return args.size() == 1
                && ("-h".equals(args.get(0)) || "--help".equals(args.get(0)));
    }

    private static String joinTopics() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < TOPICS.size(); i++) {
            if (i > 0) {
                sb.append(", ");
            }
            sb.append(TOPICS.get(i));
        }
        return sb.toString();
    }

    private static void helpOpt(PrintStream out, String left, String right) {
        final int width = 34;
        if (left == null) {
            left = "";
        }
        if (right == null) {
            right = "";
        }
        if (left.length() >= width) {
            out.println("  " + left);
            out.println(String.format("  %" + width + "s %s", "", right));
        } else {
            out.println(String.format("  %-" + width + "s %s", left, right));
        }
    }

    static void printHelp(PrintStream out) {
        out.println("\\sqlmap - JDBC SQLMAP toolkit (current yjdbc session)");
        out.println();
        out.println("Usage:");
        out.println("  \\sqlmap <subcommand> [options]");
        out.println("  \\sqlmap -h | \\help sqlmap");
        out.println("  \\sqlmap <subcommand> -h | \\help sqlmap <subcommand>");
        out.println();
        out.println("Subcommands:");
        helpOpt(out, "create", "CREATE SQLMAP (sql_id and/or files)");
        helpOpt(out, "list", "List SYS.SQL_MAP$");
        helpOpt(out, "show", "Show one map (-n or -S)");
        helpOpt(out, "drop", "DROP SQLMAP (-n)");
        helpOpt(out, "export", "Export sql text (-s)");
        helpOpt(out, "genbind", "Export binds (-s; -o out)");
        helpOpt(out, "genexec", "Prepare/run target (-t or -f)");
        helpOpt(out, "lit2bind", "Offline literal -> bind rewrite");
        helpOpt(out, "perf", "Compare src vs tgt elapsed (-s + -t|-f)");
        helpOpt(out, "verify", "Verify map/pair (-v + -e required)");
        out.println();
        out.println("Common options (most subcommands):");
        helpOpt(out, "-h, --help", "Help (global or with subcommand)");
        helpOpt(out, "-d, --debug [bool]", "Debug logging (default: on)");
        helpOpt(out, "--no-debug", "Disable debug logging");
        helpOpt(out, "-e, --exec, --run", "Execute SQL (genexec/perf/verify/create -v)");
        helpOpt(out, "-A, --schema-via-alter", "ALTER SESSION schema switch");
        helpOpt(out, "-C, --current-schema <user>", "Set current schema (implies -A)");
        helpOpt(out, "-o, --out <file>", "Output / summary / audit file");
        helpOpt(out, "-b, --bind-file <arg>", "<file> | backup | view");
        helpOpt(out, "-j, --jdbc-config <file>", "IGNORED (session connection)");
        helpOpt(out, "-l, --log-dir <dir>", "IGNORED (stdout/stderr only)");
        out.println();
        out.println("Create / verify text sides:");
        helpOpt(out, "-s, --src-sql-id", "Source sql_id");
        helpOpt(out, "-r, --src-file", "Source SQL file");
        helpOpt(out, "-t, --tgt-sql-id", "Target sql_id");
        helpOpt(out, "-f, --sql-file", "Target SQL file (also lit2bind/genexec in)");
        helpOpt(out, "-n, --map-name", "Map name");
        helpOpt(out, "-u, --map-user", "Map user (default ALL)");
        helpOpt(out, "-D, --dry-run", "create: no DDL");
        helpOpt(out, "-F, --flush", "create: flush shared pool");
        helpOpt(out, "-v, --verify <modes>", "plan|plan-eq|result|unordered");
        helpOpt(out, "-S, --sql-id", "show: lookup by sql_id");
        helpOpt(out, "-L, --limit", "list: row limit (default 500)");
        helpOpt(out, "-k, --marker", "genexec/perf/verify marker comment");
        helpOpt(out, "-B, --bind-format", "lit2bind: ? or :bN");
        helpOpt(out, "-W, --bind-out", "lit2bind: values file");
        out.println();
        out.println("Create matrix: (-s|-r) x (-t|-f).  Mutex: -s/-r, -t/-f.");
        out.println("Connection: current yjdbc session (no jdbc_replay.ini).");
        out.println();
        out.println("Examples:");
        out.println("  \\sqlmap list -L 50");
        out.println("  \\sqlmap create -r src.sql -f tgt.sql -n m1 -D");
        out.println("  \\sqlmap create -s <sid> -f tgt.sql -n m1 -F -v result -e");
        out.println("  \\sqlmap lit2bind -f lit.sql -B :bN -o out.sql -W binds.txt");
        out.println("  \\sqlmap verify -n m1 -v result -e");
    }
}
