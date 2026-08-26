package com.yashan.yjdbc.cmd.sqlmap.support.collect;

import com.yashan.yjdbc.cmd.sqlmap.support.model.BindValue;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * LITERAL SQL 绑字面量改写, 以及混合 ? / :SYS_B_* 的 JDBC 对齐 (方案 A).
 *
 * <p>方案 A (Yashan peep): capture 常先全部 ?, 再全部 :SYS_*; 文本 LTR 可能交错.
 * 对齐方式: 最新 capture 按 position 排序后分组; 扫 peep 文本 LTR;
 * 遇 ? 按序取 name=? 的值; 遇 :name / :SYS_B_* 按名字取值; 再改写为全 ?.
 */
public final class LiteralBindRewrite {

    /** 单 bind 字面量最大字符数; 超出截断并标注 */
    public static final int MAX_LITERAL_CHARS = 8000;

    /** JDBC 对齐结果: 全 ? SQL + 按 LTR 重排的绑定 (position=1..N, name=?). */
    public static final class Aligned {
        public String sql = "";
        public List<BindValue> binds = new ArrayList<BindValue>();
        public final List<String> warnings = new ArrayList<String>();
    }

    private static final class Ph {
        final int start;
        final int end;
        final String token;

        Ph(int start, int end, String token) {
            this.start = start;
            this.end = end;
            this.token = token;
        }
    }

    private LiteralBindRewrite() {}

    /**
     * 方案 A: 将 peep SQL 与 capture 绑定对齐为 JDBC 可执行的全 ? 形式.
     * 无占位或无绑定时原样返回 (binds 浅拷贝).
     */
    public static Aligned align(String sql, List<BindValue> binds) {
        Aligned out = new Aligned();
        if (sql == null) {
            return out;
        }
        out.sql = sql;
        if (binds == null || binds.isEmpty()) {
            return out;
        }
        List<Ph> phs = scanPlaceholders(sql);
        if (phs.isEmpty()) {
            out.binds = copyBinds(binds);
            return out;
        }

        List<BindValue> sorted = copyBinds(binds);
        Collections.sort(sorted, new Comparator<BindValue>() {
            public int compare(BindValue a, BindValue b) {
                return Integer.compare(a.position, b.position);
            }
        });

        List<BindValue> qVals = new ArrayList<BindValue>();
        Map<String, BindValue> byName = new LinkedHashMap<String, BindValue>();
        for (BindValue b : sorted) {
            if (b == null) {
                continue;
            }
            if (isQuestionName(b.name)) {
                qVals.add(b);
            } else {
                String key = normalizeBindName(b.name);
                if (key != null) {
                    byName.put(key, b);
                }
            }
        }

        StringBuilder sb = new StringBuilder(sql.length());
        List<BindValue> aligned = new ArrayList<BindValue>(phs.size());
        int qi = 0;
        int cursor = 0;
        for (int i = 0; i < phs.size(); i++) {
            Ph ph = phs.get(i);
            sb.append(sql, cursor, ph.start);
            sb.append('?');
            cursor = ph.end;

            BindValue src;
            if ("?".equals(ph.token)) {
                if (qi >= qVals.size()) {
                    out.warnings.add("not enough ? capture values for LTR placeholder #" + (i + 1));
                    src = emptyBind(i + 1);
                } else {
                    src = qVals.get(qi++);
                }
            } else {
                String key = normalizeBindName(ph.token);
                src = key == null ? null : byName.get(key);
                if (src == null) {
                    out.warnings.add("missing named capture for " + ph.token
                            + " at LTR #" + (i + 1));
                    src = emptyBind(i + 1);
                }
            }
            BindValue nb = new BindValue();
            nb.position = i + 1;
            nb.name = "?";
            nb.datatype = src.datatype == null ? "" : src.datatype;
            nb.value = src.value == null ? "" : src.value;
            nb.wasCaptured = src.wasCaptured == null ? "" : src.wasCaptured;
            aligned.add(nb);
        }
        sb.append(sql, cursor, sql.length());
        out.sql = sb.toString();
        out.binds = aligned;
        if (qi < qVals.size()) {
            out.warnings.add("unused ? capture values=" + (qVals.size() - qi));
        }
        return out;
    }

    /**
     * 仅将占位符改为 ?, 不改绑定值顺序 (用于 genbind 已按 LTR 写值的文件).
     */
    public static String toQuestionMarks(String sql) {
        if (sql == null || sql.isEmpty()) {
            return sql == null ? "" : sql;
        }
        List<Ph> phs = scanPlaceholders(sql);
        if (phs.isEmpty()) {
            return sql;
        }
        StringBuilder sb = new StringBuilder(sql.length());
        int cursor = 0;
        for (Ph ph : phs) {
            sb.append(sql, cursor, ph.start);
            sb.append('?');
            cursor = ph.end;
        }
        sb.append(sql, cursor, sql.length());
        return sb.toString();
    }

    public static String rewrite(String sql, List<BindValue> binds) {
        if (sql == null) {
            return "";
        }
        if (binds == null || binds.isEmpty()) {
            return sql;
        }
        Aligned a = align(sql, binds);
        String text = a.sql;
        List<String> warnings = new ArrayList<String>(a.warnings);
        for (BindValue b : a.binds) {
            if (b == null) {
                continue;
            }
            String repl = toLiteral(b, warnings);
            int q = indexOfQuestionOutsideQuotes(text);
            if (q < 0) {
                warnings.add("no placeholder for bind pos=" + b.position + " name=" + b.name);
                continue;
            }
            text = text.substring(0, q) + repl + text.substring(q + 1);
        }
        if (!warnings.isEmpty()) {
            StringBuilder sb = new StringBuilder(text);
            sb.append("\n-- LITERAL WARN: ");
            for (int i = 0; i < warnings.size(); i++) {
                if (i > 0) {
                    sb.append("; ");
                }
                sb.append(warnings.get(i));
            }
            return sb.toString();
        }
        return text;
    }

    static String toLiteral(BindValue b, List<String> warnings) {
        String raw = b.value;
        if (raw == null || raw.isEmpty() || "\\N".equals(raw)) {
            return "NULL";
        }
        String dt = b.datatype == null ? "" : b.datatype.toUpperCase(Locale.ROOT);
        String v = raw;
        boolean truncated = false;
        if (v.length() > MAX_LITERAL_CHARS) {
            v = v.substring(0, MAX_LITERAL_CHARS);
            truncated = true;
            warnings.add("truncated value pos=" + b.position + " to " + MAX_LITERAL_CHARS + " chars");
        }
        String lit;
        if (dt.contains("NUMBER") || dt.contains("DECIMAL") || dt.contains("INT")
                || dt.contains("FLOAT") || dt.contains("DOUBLE") || dt.contains("BINARY_")) {
            lit = v.trim();
        } else if (dt.contains("DATE") && !dt.contains("TIMESTAMP")) {
            lit = "to_date('" + escapeQuote(v) + "')";
        } else if (dt.contains("TIMESTAMP") || dt.contains("TIME")) {
            lit = "to_timestamp('" + escapeQuote(v) + "')";
        } else {
            lit = "'" + escapeQuote(v) + "'";
        }
        if (truncated) {
            lit = lit + " /*truncated*/";
        }
        return lit;
    }

    /** 主模式; 兼容旧调用. */
    static String bindPattern(String name) {
        List<String> ps = bindPatterns(name);
        return ps.isEmpty() ? null : ps.get(0);
    }

    /**
     * 生成候选占位符模式 (先试再回退 ?).
     * SYS_B: SQL 文本常为 :SYS_B_0; 部分库/工具为 :"SYS_B_0".
     */
    static List<String> bindPatterns(String name) {
        List<String> out = new ArrayList<String>();
        if (name == null || name.trim().isEmpty() || "?".equals(name.trim())) {
            return out;
        }
        String n = name.trim();
        String bare = n.startsWith(":") ? n.substring(1) : n;
        bare = bare.replace("\"", "");
        if (bare.regionMatches(true, 0, "SYS_B_", 0, 6)) {
            out.add(":" + bare);
            out.add(":\"" + bare + "\"");
            return out;
        }
        if (n.startsWith(":")) {
            out.add(n);
            return out;
        }
        out.add(":" + n.replaceFirst("^:+", ""));
        return out;
    }

    static boolean usesQuestionBind(String text) {
        return indexOfQuestionOutsideQuotes(text) >= 0;
    }

    static int indexOfQuestionOutsideQuotes(String text) {
        boolean inStr = false;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '\'') {
                if (inStr && i + 1 < text.length() && text.charAt(i + 1) == '\'') {
                    i++;
                } else {
                    inStr = !inStr;
                }
            } else if (!inStr && c == '?') {
                return i;
            }
        }
        return -1;
    }

    static String replaceFirstOutsideQuotes(String text, String pattern, String replacement) {
        if (pattern == null || pattern.isEmpty()) {
            return text;
        }
        boolean inStr = false;
        int plen = pattern.length();
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '\'') {
                if (inStr && i + 1 < text.length() && text.charAt(i + 1) == '\'') {
                    i++;
                } else {
                    inStr = !inStr;
                }
                continue;
            }
            if (inStr) {
                continue;
            }
            if (i + plen <= text.length()
                    && text.regionMatches(true, i, pattern, 0, plen)) {
                char next = i + plen < text.length() ? text.charAt(i + plen) : 0;
                if (pattern.startsWith(":") && next >= '0' && next <= '9') {
                    continue;
                }
                return text.substring(0, i) + replacement + text.substring(i + plen);
            }
        }
        return text;
    }

    /** 引号外 LTR 扫描 ? / :name / :"SYS_B_0". */
    static List<Ph> scanPlaceholders(String sql) {
        List<Ph> out = new ArrayList<Ph>();
        if (sql == null || sql.isEmpty()) {
            return out;
        }
        boolean inStr = false;
        for (int i = 0; i < sql.length(); i++) {
            char c = sql.charAt(i);
            if (inStr) {
                if (c == '\'') {
                    if (i + 1 < sql.length() && sql.charAt(i + 1) == '\'') {
                        i++;
                    } else {
                        inStr = false;
                    }
                }
                continue;
            }
            if (c == '\'') {
                inStr = true;
                continue;
            }
            if (c == '?') {
                out.add(new Ph(i, i + 1, "?"));
                continue;
            }
            if (c == ':' && i + 1 < sql.length()) {
                char n1 = sql.charAt(i + 1);
                if (n1 == '"') {
                    int j = i + 2;
                    while (j < sql.length() && sql.charAt(j) != '"') {
                        j++;
                    }
                    if (j < sql.length()) {
                        String bare = sql.substring(i + 2, j);
                        out.add(new Ph(i, j + 1, ":" + bare));
                        i = j;
                    }
                    continue;
                }
                if (Character.isLetter(n1) || n1 == '_') {
                    int j = i + 1;
                    while (j + 1 < sql.length()) {
                        char x = sql.charAt(j + 1);
                        if (Character.isLetterOrDigit(x) || x == '_') {
                            j++;
                        } else {
                            break;
                        }
                    }
                    out.add(new Ph(i, j + 1, sql.substring(i, j + 1)));
                    i = j;
                }
            }
        }
        return out;
    }

    static boolean isQuestionName(String name) {
        if (name == null) {
            return true;
        }
        String t = name.trim();
        return t.isEmpty() || "?".equals(t);
    }

    /** 归一为 :NAME (大写 SYS_B; 其它保留原大小写去引号). */
    static String normalizeBindName(String name) {
        if (name == null) {
            return null;
        }
        String n = name.trim();
        if (n.isEmpty() || "?".equals(n)) {
            return null;
        }
        if (n.startsWith(":")) {
            n = n.substring(1);
        }
        n = n.replace("\"", "");
        if (n.isEmpty()) {
            return null;
        }
        if (n.regionMatches(true, 0, "SYS_B_", 0, 6)) {
            return ":" + n.toUpperCase(Locale.ROOT);
        }
        return ":" + n;
    }

    private static List<BindValue> copyBinds(List<BindValue> binds) {
        List<BindValue> out = new ArrayList<BindValue>(binds.size());
        for (BindValue b : binds) {
            if (b == null) {
                continue;
            }
            BindValue c = new BindValue();
            c.position = b.position;
            c.name = b.name == null ? "" : b.name;
            c.datatype = b.datatype == null ? "" : b.datatype;
            c.value = b.value == null ? "" : b.value;
            c.wasCaptured = b.wasCaptured == null ? "" : b.wasCaptured;
            out.add(c);
        }
        return out;
    }

    private static BindValue emptyBind(int pos) {
        BindValue b = new BindValue();
        b.position = pos;
        b.name = "?";
        b.datatype = "";
        b.value = "";
        return b;
    }

    private static String escapeQuote(String s) {
        return s.replace("'", "''");
    }
}
