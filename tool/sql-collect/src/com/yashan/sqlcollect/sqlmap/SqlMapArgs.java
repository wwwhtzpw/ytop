package com.yashan.sqlcollect.sqlmap;

import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * sqlmap 子命令本地 argv 解析 (短选项作用域独立于 collect/replay).
 */
public final class SqlMapArgs {

    public final Map<String, String> options = new HashMap<String, String>();
    public boolean help;

    public static SqlMapArgs parse(List<String> argv) {
        SqlMapArgs a = new SqlMapArgs();
        if (argv == null) {
            return a;
        }
        int i = 0;
        while (i < argv.size()) {
            String tok = argv.get(i);
            if ("--help".equals(tok) || "-h".equals(tok)) {
                a.help = true;
                i++;
                continue;
            }
            if ("--run".equals(tok)) {
                a.options.put("exec", "true");
                i++;
                continue;
            }
            if (tok.startsWith("--")) {
                String key = tok.substring(2);
                String val = "true";
                if (key.contains("=")) {
                    int eq = key.indexOf('=');
                    val = key.substring(eq + 1);
                    key = key.substring(0, eq);
                } else if (i + 1 < argv.size() && isValue(argv.get(i + 1))) {
                    val = argv.get(i + 1);
                    i++;
                }
                putOption(a, normalizeKey(key), val);
                i++;
                continue;
            }
            if (tok.startsWith("-") && tok.length() == 2) {
                char c = tok.charAt(1);
                if (c == 'h') {
                    a.help = true;
                    i++;
                    continue;
                }
                String key = mapShort(c);
                if (key == null) {
                    key = String.valueOf(c);
                }
                String val = "true";
                if (needsValue(c) && i + 1 < argv.size() && isValue(argv.get(i + 1))) {
                    val = argv.get(i + 1);
                    i++;
                } else if (!needsValue(c) && i + 1 < argv.size() && isValue(argv.get(i + 1))
                        && looksLikeBoolOrPath(c, argv.get(i + 1))) {
                    // -d false / -e 无值
                    if (c == 'd') {
                        val = argv.get(i + 1);
                        i++;
                    }
                }
                if (c == 'e') {
                    a.options.put("exec", "true");
                } else {
                    a.options.put(key, val);
                }
                i++;
                continue;
            }
            i++;
        }
        return a;
    }

    /** --verify 可多次出现或逗号拼接, 其它键覆盖. */
    private static void putOption(SqlMapArgs a, String key, String val) {
        if ("verify".equals(key)) {
            String prev = a.options.get("verify");
            if (prev == null || prev.isEmpty() || "true".equalsIgnoreCase(prev)) {
                a.options.put("verify", val);
            } else {
                a.options.put("verify", prev + "," + val);
            }
            return;
        }
        a.options.put(key, val);
    }

    private static String normalizeKey(String key) {
        String k = key.toLowerCase(Locale.ROOT);
        if ("src-sqlid".equals(k) || "source-sql-id".equals(k)) {
            return "src-sql-id";
        }
        if ("tgt-sqlid".equals(k) || "target-sql-id".equals(k)) {
            return "tgt-sql-id";
        }
        return k;
    }

    static String mapShort(char c) {
        switch (c) {
            case 's':
                return "src-sql-id";
            case 't':
                return "tgt-sql-id";
            case 'f':
                return "sql-file";
            case 'o':
                return "out";
            case 'b':
                return "bind-file";
            case 'j':
                return "jdbc-config";
            case 'l':
                return "log-dir";
            case 'd':
                return "debug";
            case 'A':
                return "schema-via-alter";
            case 'C':
                return "current-schema";
            case 'e':
                return "exec";
            case 'n':
                return "map-name";
            case 'u':
                return "map-user";
            case 'S':
                return "sql-id";
            case 'r':
                return "src-file";
            case 'D':
                return "dry-run";
            case 'F':
                return "flush";
            case 'v':
                return "verify";
            case 'k':
                return "marker";
            case 'L':
                return "limit";
            case 'B':
                return "bind-format";
            case 'W':
                return "bind-out";
            default:
                return null;
        }
    }

    static boolean needsValue(char c) {
        return c == 's' || c == 't' || c == 'f' || c == 'o' || c == 'b' || c == 'j' || c == 'l'
                || c == 'C' || c == 'd'
                || c == 'n' || c == 'u' || c == 'S' || c == 'r' || c == 'v' || c == 'k' || c == 'L'
                || c == 'B' || c == 'W';
        // -D dry-run / -F flush / -e exec / -A schema-via-alter: flags, no value
    }

    private static boolean looksLikeBoolOrPath(char c, String v) {
        return c == 'd';
    }

    private static boolean isValue(String tok) {
        if (tok == null || tok.isEmpty()) {
            return false;
        }
        if (tok.startsWith("--")) {
            return false;
        }
        if (tok.startsWith("-") && tok.length() > 1) {
            try {
                Integer.parseInt(tok);
                return true;
            } catch (NumberFormatException e) {
                return false;
            }
        }
        return true;
    }

    public boolean flag(String name) {
        String v = options.get(name.toLowerCase(Locale.ROOT));
        if (v == null) {
            return false;
        }
        return "true".equalsIgnoreCase(v) || "1".equals(v) || "yes".equalsIgnoreCase(v);
    }

    public String opt(String name, String def) {
        String v = options.get(name.toLowerCase(Locale.ROOT));
        return v == null ? def : v;
    }

    public boolean resolveDebug() {
        if (flag("no-debug")) {
            return false;
        }
        String v = opt("debug", null);
        if (v == null) {
            return true;
        }
        if ("false".equalsIgnoreCase(v) || "0".equals(v) || "no".equalsIgnoreCase(v)
                || "off".equalsIgnoreCase(v)) {
            return false;
        }
        return true;
    }

    public boolean resolveExec() {
        return flag("exec") || flag("run");
    }

    /** --verify plan|plan-eq|result|unordered（可逗号组合或重复 --verify） */
    public boolean hasVerifyMode(String mode) {
        String v = opt("verify", null);
        if (v == null || v.isEmpty() || "true".equalsIgnoreCase(v)) {
            return false;
        }
        String want = mode.toLowerCase(Locale.ROOT);
        String[] parts = v.split("[,\\s]+");
        for (int i = 0; i < parts.length; i++) {
            String p = parts[i].trim().toLowerCase(Locale.ROOT);
            if (want.equals(p)) {
                return true;
            }
        }
        return false;
    }

    public boolean wantVerifyPlan() {
        return hasVerifyMode("plan") || wantPlanEq();
    }

    public boolean wantPlanEq() {
        return hasVerifyMode("plan-eq");
    }

    public boolean wantVerifyResult() {
        return hasVerifyMode("result");
    }

    public boolean wantUnordered() {
        return hasVerifyMode("unordered");
    }

    /** 拒绝已删除的旧旗标, 提示改用 --verify */
    String rejectRemovedVerifyFlags() {
        String[] old = new String[] {
                "verify-plan", "verify-result", "verify-unordered",
                "plan-eq", "verify-plan-strict"
        };
        for (int i = 0; i < old.length; i++) {
            if (options.containsKey(old[i])) {
                return "removed flag --" + old[i]
                        + "; use --verify plan|plan-eq|result|unordered";
            }
        }
        return null;
    }

    /** @return 错误信息; null=OK */
    public String validateCreate() {
        boolean srcId = notEmpty(opt("src-sql-id", null));
        boolean srcFile = notEmpty(opt("src-file", null));
        boolean tgtId = notEmpty(opt("tgt-sql-id", null));
        boolean tgtFile = notEmpty(opt("sql-file", null));
        if (srcId && srcFile) {
            return "create: -s/--src-sql-id and --src-file are mutually exclusive";
        }
        if (!srcId && !srcFile) {
            return "create requires source: -s/--src-sql-id or --src-file";
        }
        if (tgtId && tgtFile) {
            return "create: -t/--tgt-sql-id and -f/--sql-file are mutually exclusive";
        }
        if (!tgtId && !tgtFile) {
            return "create requires target: -t/--tgt-sql-id or -f/--sql-file";
        }
        String bindErr = validateBindSource();
        if (bindErr != null) {
            return bindErr;
        }
        String old = rejectRemovedVerifyFlags();
        if (old != null) {
            return old;
        }
        return null;
    }

    public String validateShow() {
        boolean name = notEmpty(opt("map-name", null));
        boolean sid = notEmpty(opt("sql-id", null));
        if (name && sid) {
            return "show: --map-name and --sql-id are mutually exclusive";
        }
        if (!name && !sid) {
            return "show requires --map-name or --sql-id";
        }
        return null;
    }

    public String validateDrop() {
        if (!notEmpty(opt("map-name", null))) {
            return "drop requires --map-name";
        }
        return null;
    }

    public String validateVerify() {
        boolean name = notEmpty(opt("map-name", null));
        boolean srcId = notEmpty(opt("src-sql-id", null));
        boolean srcFile = notEmpty(opt("src-file", null));
        boolean tgtId = notEmpty(opt("tgt-sql-id", null));
        boolean tgtFile = notEmpty(opt("sql-file", null));
        boolean hasText = srcId || srcFile || tgtId || tgtFile;
        if (name && hasText) {
            // -n 时允许附带 -s + -b backup|view, 仅作绑定来源 sql_id
            boolean bindOnly = isBindSourceKeyword() && srcId && !srcFile && !tgtId && !tgtFile;
            if (!bindOnly) {
                return "verify: --map-name cannot combine with source/target sql-id or files"
                        + " (except -s with -b backup|view for binds)";
            }
        }
        if (!name && !hasText) {
            return "verify requires --map-name or source/target (same matrix as create)";
        }
        if (!name) {
            String c = validateCreate();
            if (c != null) {
                return c.replace("create", "verify");
            }
        }
        String bindErr = validateBindSource();
        if (bindErr != null) {
            return bindErr;
        }
        String old = rejectRemovedVerifyFlags();
        if (old != null) {
            return old;
        }
        String verr = validateVerifyModes();
        if (verr != null) {
            return verr;
        }
        if (!wantVerifyPlan() && !wantVerifyResult()) {
            return "verify requires --verify plan|plan-eq|result";
        }
        if (!resolveExec()) {
            return "verify requires --exec to run SQL";
        }
        return null;
    }

    /**
     * -b 取值: backup|view 为关键字; 其它视为绑定文件路径.
     * @return backup / view / null(未设或文件路径)
     */
    public String bindSourceKeyword() {
        String bf = opt("bind-file", null);
        if (bf == null) {
            return null;
        }
        String t = bf.trim();
        if ("backup".equalsIgnoreCase(t) || "view".equalsIgnoreCase(t)) {
            return t.toLowerCase(Locale.ROOT);
        }
        return null;
    }

    public boolean isBindSourceKeyword() {
        return bindSourceKeyword() != null;
    }

    /** -b backup|view 时必须有 -s/--src-sql-id. */
    public String validateBindSource() {
        String kw = bindSourceKeyword();
        if (kw == null) {
            return null;
        }
        if (!notEmpty(opt("src-sql-id", null))) {
            return "-b " + kw + " requires -s/--src-sql-id (sql_id for bind lookup)";
        }
        return null;
    }

    /** 校验 --verify 取值; 无 --verify 键时跳过（走旧旗标） */
    String validateVerifyModes() {
        String v = opt("verify", null);
        if (v == null || v.isEmpty()) {
            return null;
        }
        if ("true".equalsIgnoreCase(v)) {
            return "verify requires a mode: plan|plan-eq|result|unordered";
        }
        String[] parts = v.split("[,\\s]+");
        for (int i = 0; i < parts.length; i++) {
            String p = parts[i].trim().toLowerCase(Locale.ROOT);
            if (p.isEmpty()) {
                continue;
            }
            if (!"plan".equals(p) && !"plan-eq".equals(p) && !"result".equals(p)
                    && !"unordered".equals(p)) {
                return "unknown --verify mode: " + p + " (use plan|plan-eq|result|unordered)";
            }
        }
        return null;
    }

    public String validateExport() {
        if (!notEmpty(opt("src-sql-id", null))) {
            return "export requires -s/--src-sql-id";
        }
        return null;
    }

    public String validateGenbind() {
        if (!notEmpty(opt("src-sql-id", null))) {
            return "genbind requires -s/--src-sql-id";
        }
        String bf = opt("bind-file", null);
        if (bf != null && !bf.trim().isEmpty() && bindSourceKeyword() == null) {
            return "genbind -b must be backup or view (output path is -o)";
        }
        return validateBindSource();
    }

    public String validateLit2bind() {
        if (!notEmpty(opt("sql-file", null))) {
            return "lit2bind requires -f/--sql-file";
        }
        return null;
    }

    public String validateGenexec() {
        boolean tgtId = notEmpty(opt("tgt-sql-id", null));
        boolean tgtFile = notEmpty(opt("sql-file", null));
        if (tgtId && tgtFile) {
            return "genexec: -t/--tgt-sql-id and -f/--sql-file are mutually exclusive";
        }
        if (!tgtId && !tgtFile) {
            return "genexec requires -t/--tgt-sql-id or -f/--sql-file";
        }
        return validateBindSource();
    }

    public String validatePerf() {
        if (!notEmpty(opt("src-sql-id", null))) {
            return "perf requires -s/--src-sql-id";
        }
        String g = validateGenexec();
        if (g != null && g.startsWith("genexec requires")) {
            return "perf requires -t/--tgt-sql-id or -f/--sql-file";
        }
        return g;
    }

    private static boolean notEmpty(String s) {
        return s != null && !s.trim().isEmpty();
    }
}
