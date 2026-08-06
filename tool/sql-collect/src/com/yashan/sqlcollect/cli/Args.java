package com.yashan.sqlcollect.cli;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 简易 argv 解析 (collect/replay/check/sqlmap).
 * 短选项: 常用小写 / 不常用大写; 映射为 kebab-case 长名后写入 options.
 * sqlmap: subcommand 之后全部 token 进入 sqlmapArgv, 禁止全局 mapShortOption.
 */
public class Args {

    public String command = "collect";
    /** sqlmap 二级子命令 (create/list/...); 非 sqlmap 时为空 */
    public String subcommand = "";
    /** sqlmap subcommand 之后的原始 argv (本地 SqlMapArgs 解析) */
    public final List<String> sqlmapArgv = new ArrayList<String>();
    public final Map<String, String> options = new HashMap<String, String>();
    public final List<String> positional = new ArrayList<String>();
    public boolean help;
    public boolean version;

    public static Args parse(String[] argv) {
        Args a = new Args();
        List<String> rest = new ArrayList<String>();
        for (String s : argv) {
            rest.add(s);
        }
        int i = 0;
        if (!rest.isEmpty() && ("collect".equals(rest.get(0)) || "replay".equals(rest.get(0))
                || "check".equals(rest.get(0)) || "sqlmap".equals(rest.get(0))
                || "top".equals(rest.get(0)))) {
            a.command = rest.get(0);
            i = 1;
        }
        if ("sqlmap".equals(a.command)) {
            // 允许 sqlmap --help (无 subcommand)
            if (i < rest.size()) {
                String tok = rest.get(i);
                if ("--help".equals(tok) || "-h".equals(tok)) {
                    a.help = true;
                    i++;
                } else if (!tok.startsWith("-")) {
                    a.subcommand = tok;
                    i++;
                }
            }
            while (i < rest.size()) {
                a.sqlmapArgv.add(rest.get(i));
                i++;
            }
            return a;
        }
        while (i < rest.size()) {
            String tok = rest.get(i);
            if ("--help".equals(tok) || "-h".equals(tok)) {
                a.help = true;
                i++;
                continue;
            }
            if ("--version".equals(tok) || "-V".equals(tok)) {
                a.version = true;
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
                } else if (longTakesValue(key) && i + 1 < rest.size()
                        && isOptionValueToken(rest.get(i + 1))) {
                    val = rest.get(i + 1);
                    i++;
                }
                String norm = key.toLowerCase(Locale.ROOT);
                if ("sqlid".equals(norm)) {
                    norm = "sql-id"; // 别名: --sqlid
                }
                a.options.put(norm, val);
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
                if (c == 'V') {
                    a.version = true;
                    i++;
                    continue;
                }
                String mapped = mapShortOption(c);
                String key = mapped != null ? mapped : String.valueOf(c);
                String val = "true";
                if (c == 'd' && i + 1 < rest.size() && isBoolToken(rest.get(i + 1))) {
                    // -d false / -d true
                    val = rest.get(i + 1);
                    i++;
                } else if (shortNeedsValue(c) && i + 1 < rest.size()
                        && isOptionValueToken(rest.get(i + 1))) {
                    val = rest.get(i + 1);
                    i++;
                }
                a.options.put(key.toLowerCase(Locale.ROOT), val);
                i++;
                continue;
            }
            a.positional.add(tok);
            i++;
        }
        return a;
    }

    /**
     * 单字母短选项 → 长选项名.
     * 常用小写; 不常用大写. 返回 null 表示未登记 (仍按字面键存入).
     */
    public static String mapShortOption(char c) {
        switch (c) {
            case 'o':
                return "outdir";
            case 'l':
                return "log-dir";
            case 'j':
                return "jdbc-config";
            case 's':
                return "sql-id";
            case 'S':
                return "source";
            case 'i':
                return "interval";
            case 'c':
                return "count";
            case 't':
                return "timeout";
            case 'T':
                return "report-timeout";
            case 'p':
                return "parallel";
            case 'N':
                return "sessions";
            case 'f':
                return "force";
            case 'e':
                return "exec";
            case 'd':
                return "debug";
            case 'R':
                return "results-csv";
            case 'A':
                return "schema-via-alter";
            case 'C':
                return "current-schema";
            case 'M':
                return "on-sha-mismatch";
            case 'n':
                return "new-run";
            case 'I':
                return "init-config";
            case 'w':
                return "overwrite";
            case 'K':
                return "skip-backup";
            case 'B':
                return "backup-only";
            case 'X':
                return "skip-replay-export";
            case 'D':
                return "dry-run";
            case 'a':
                return "replay-all";
            case 'L':
                return "limit";
            case 'E':
                return "explain-plan";
            case 'U':
                return "exclude-schemas";
            case 'u':
                return "include-schemas";
            default:
                return null;
        }
    }

    /** 需要取值的短选项 (不含 -d: 可选 bool; 不含纯 flag). */
    static boolean shortNeedsValue(char c) {
        return c == 'o' || c == 'l' || c == 'j' || c == 's' || c == 'S' || c == 'i' || c == 'c'
                || c == 't' || c == 'T' || c == 'p' || c == 'N' || c == 'R' || c == 'C'
                || c == 'M' || c == 'L' || c == 'U' || c == 'u';
    }

    /** 需要取值的长选项; flag 类不吞下一个位置参数. */
    static boolean longTakesValue(String key) {
        if (key == null) {
            return false;
        }
        String k = key.toLowerCase(Locale.ROOT);
        if ("debug".equals(k)) {
            return true; // 允许 --debug false
        }
        return "jdbc-config".equals(k) || "log-dir".equals(k) || "outdir".equals(k)
                || "interval".equals(k) || "count".equals(k) || "sql-id".equals(k)
                || "report-timeout".equals(k) || "timeout".equals(k) || "replay-timeout".equals(k)
                || "current-schema".equals(k) || "source".equals(k)
                || "parallel".equals(k) || "sessions".equals(k) || "results-csv".equals(k)
                || "on-sha-mismatch".equals(k) || "limit".equals(k) || "sort".equals(k)
                || "run".equals(k) || "csv".equals(k) || "sqlid".equals(k)
                || "sink".equals(k) || "exclude-schemas".equals(k) || "include-schemas".equals(k)
                || "active-session".equals(k);
    }

    static boolean isBoolToken(String tok) {
        if (tok == null) {
            return false;
        }
        String s = tok.trim().toLowerCase(Locale.ROOT);
        return "true".equals(s) || "false".equals(s) || "1".equals(s) || "0".equals(s)
                || "yes".equals(s) || "no".equals(s) || "on".equals(s) || "off".equals(s);
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

    public Integer optInt(String name, Integer def) {
        String v = opt(name, null);
        if (v == null || v.isEmpty()) {
            return def;
        }
        try {
            return Integer.valueOf(v);
        } catch (NumberFormatException e) {
            return def;
        }
    }

    /**
     * 布尔选项; 未出现时返回 def.
     * true: true/1/yes/on; false: false/0/no/off.
     */
    public boolean optBool(String name, boolean def) {
        String v = options.get(name.toLowerCase(Locale.ROOT));
        if (v == null) {
            return def;
        }
        String s = v.trim();
        if (s.isEmpty()) {
            return def;
        }
        if ("false".equalsIgnoreCase(s) || "0".equals(s) || "no".equalsIgnoreCase(s)
                || "off".equalsIgnoreCase(s)) {
            return false;
        }
        if ("true".equalsIgnoreCase(s) || "1".equals(s) || "yes".equalsIgnoreCase(s)
                || "on".equalsIgnoreCase(s)) {
            return true;
        }
        return def;
    }

    /**
     * --debug 默认 true; --debug false / --no-debug 关闭.
     * 未写 --debug 时亦为 true.
     */
    public boolean resolveDebug() {
        if (flag("no-debug")) {
            return false;
        }
        return optBool("debug", true);
    }

    /**
     * 是否扫描 gv$/v$session 做活跃 SQL 置顶.
     * 默认 true; --active-session false / --no-active-session 关闭.
     */
    public boolean resolveActiveSession() {
        if (flag("no-active-session")) {
            return false;
        }
        return optBool("active-session", true);
    }

    /**
     * 指纹失败是否阻断回放. 默认 true (fail).
     * --on-sha-mismatch fail|warn|continue ; --allow-sha-mismatch => warn.
     *
     * @return true=失败则不回放; false=WARN 后仍回放
     */
    public boolean resolveShaMismatchFail() {
        if (flag("allow-sha-mismatch")) {
            return false;
        }
        String v = opt("on-sha-mismatch", "fail");
        if (v == null || v.trim().isEmpty()) {
            return true;
        }
        String s = v.trim().toLowerCase(Locale.ROOT);
        if ("fail".equals(s) || "error".equals(s) || "strict".equals(s) || "abort".equals(s)) {
            return true;
        }
        if ("warn".equals(s) || "continue".equals(s) || "allow".equals(s) || "skip".equals(s)) {
            return false;
        }
        throw new IllegalArgumentException(
                "--on-sha-mismatch must be fail|warn (got: " + v + ")");
    }

    /** 选项值: 普通 token, 或负整数 (如 -1), 排除 --flag / -x */
    static boolean isOptionValueToken(String tok) {
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

    /**
     * 对齐打印帮助行: 左列固定宽度, 右列说明.
     * left 为空时只打印续行缩进说明 (用于折行).
     */
    public static void helpOpt(String left, String right) {
        final int width = 34;
        if (left == null) {
            left = "";
        }
        if (right == null) {
            right = "";
        }
        if (left.isEmpty()) {
            System.out.println("  " + pad(width) + right);
            return;
        }
        if (left.length() >= width) {
            System.out.println("  " + left);
            System.out.println("  " + pad(width) + right);
            return;
        }
        System.out.println("  " + left + pad(width - left.length()) + right);
    }

    private static String pad(int n) {
        StringBuilder sb = new StringBuilder(n);
        for (int i = 0; i < n; i++) {
            sb.append(' ');
        }
        return sb.toString();
    }
}
