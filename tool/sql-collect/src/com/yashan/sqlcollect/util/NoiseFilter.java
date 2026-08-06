package com.yashan.sqlcollect.util;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/** SQL 噪声过滤 (与 Python sql_collect 对齐) */
public final class NoiseFilter {

    public static final String PROBE_TAG = "sql_collect_probe";
    public static final int MIN_SQL_CHARS = 20;
    /** 内置排除 parsing_schema (不可去掉; 额外名单由 ini/CLI 追加) */
    public static final String[] EXCLUDE_SCHEMAS = {"SYS", "SYSDBA", "SYSTEM"};

    private static final Pattern WS = Pattern.compile("\\s+");
    private static final Pattern SPLIT = Pattern.compile("[,;\\s]+");

    private NoiseFilter() {}

    /** 内置排除名单副本. */
    public static List<String> builtinExcludeSchemas() {
        List<String> out = new ArrayList<String>();
        for (String s : EXCLUDE_SCHEMAS) {
            out.add(s);
        }
        return out;
    }

    /**
     * 合并内置 + 若干 CSV/空白分隔片段, 去重保序, 全大写.
     * null/空片段忽略.
     */
    public static List<String> mergeExcludeSchemas(String... csvParts) {
        LinkedHashSet<String> set = new LinkedHashSet<String>();
        for (String s : EXCLUDE_SCHEMAS) {
            set.add(s);
        }
        if (csvParts != null) {
            for (String part : csvParts) {
                addParsed(set, part);
            }
        }
        return new ArrayList<String>(set);
    }

    /**
     * 仅解析 CSV/空白分隔 schema 名单 (无内置), 去重保序, 全大写.
     * 用于 include-schemas 白名单; 空表示不限制.
     */
    public static List<String> parseSchemaList(String... csvParts) {
        LinkedHashSet<String> set = new LinkedHashSet<String>();
        if (csvParts != null) {
            for (String part : csvParts) {
                addParsed(set, part);
            }
        }
        return new ArrayList<String>(set);
    }

    /** 将名单拼成 SQL NOT IN 列表: 'SYS','SYSDBA',... */
    public static String sqlNotInList(Collection<String> schemas) {
        return sqlQuotedList(schemas, true);
    }

    /** 将名单拼成 SQL IN 列表; 空名单返回 null (表示不加 IN 谓词). */
    public static String sqlInList(Collection<String> schemas) {
        List<String> list = normalizeExcludeSchemas(schemas);
        if (list.isEmpty()) {
            return null;
        }
        return sqlQuotedList(list, false);
    }

    private static String sqlQuotedList(Collection<String> schemas, boolean fallbackBuiltin) {
        List<String> list = normalizeExcludeSchemas(schemas);
        if (list.isEmpty()) {
            if (!fallbackBuiltin) {
                return null;
            }
            list = builtinExcludeSchemas();
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append('\'').append(escapeSqlLiteral(list.get(i))).append('\'');
        }
        return sb.toString();
    }

    /**
     * parsing_schema 过滤片段 (不含前导 AND):
     * UPPER(expr) NOT IN (...); 若 include 非空再 AND UPPER(expr) IN (...).
     */
    public static String sqlSchemaFilter(String upperExpr, Collection<String> exclude,
                                         Collection<String> include) {
        String expr = upperExpr == null || upperExpr.isEmpty()
                ? "UPPER(parsing_schema_name)" : upperExpr;
        StringBuilder sb = new StringBuilder();
        sb.append(expr).append(" NOT IN (").append(sqlNotInList(exclude)).append(')');
        String inList = sqlInList(include);
        if (inList != null) {
            sb.append(" AND ").append(expr).append(" IN (").append(inList).append(')');
        }
        return sb.toString();
    }

    /** 规范化: trim、大写、去重保序; 丢弃含非法字符的项. */
    public static List<String> normalizeExcludeSchemas(Collection<String> schemas) {
        LinkedHashSet<String> set = new LinkedHashSet<String>();
        if (schemas != null) {
            for (String s : schemas) {
                addOne(set, s);
            }
        }
        return new ArrayList<String>(set);
    }

    public static boolean isExcludedSchema(String schema) {
        return isExcludedSchema(schema, null);
    }

    /**
     * @param extraOrFull 若 null 仅用内置; 非 null 时视为完整名单 (已含内置更佳)
     */
    public static boolean isExcludedSchema(String schema, Collection<String> extraOrFull) {
        if (schema == null || schema.isEmpty()) {
            return true;
        }
        String u = schema.trim().toUpperCase(Locale.ROOT);
        Collection<String> list = extraOrFull;
        if (list == null || list.isEmpty()) {
            for (String ex : EXCLUDE_SCHEMAS) {
                if (ex.equals(u)) {
                    return true;
                }
            }
            return false;
        }
        for (String ex : list) {
            if (ex != null && u.equals(ex.trim().toUpperCase(Locale.ROOT))) {
                return true;
            }
        }
        return false;
    }

    /**
     * 是否通过 schema 过滤: 先排除名单, 再白名单 (白名单空=不限制).
     */
    public static boolean passesSchemaFilter(String schema, Collection<String> exclude,
                                             Collection<String> include) {
        if (isExcludedSchema(schema, exclude)) {
            return false;
        }
        List<String> inc = normalizeExcludeSchemas(include);
        if (inc.isEmpty()) {
            return true;
        }
        if (schema == null || schema.isEmpty()) {
            return false;
        }
        String u = schema.trim().toUpperCase(Locale.ROOT);
        return inc.contains(u);
    }

    public static boolean isNoiseText(String sqlText) {
        if (sqlText == null) {
            return true;
        }
        String t = sqlText.trim();
        if (t.isEmpty()) {
            return true;
        }
        if (t.contains(PROBE_TAG)) {
            return true;
        }
        if (t.length() < MIN_SQL_CHARS) {
            return true;
        }
        String u = t.toUpperCase(Locale.ROOT);
        if (u.startsWith("ALTER SESSION")) {
            return true;
        }
        if (u.startsWith("SET ")) {
            return true;
        }
        String compact = WS.matcher(u).replaceAll(" ").trim();
        if ("BEGIN NULL; END;".equals(compact) || "BEGIN END;".equals(compact)
                || "BEGIN;".equals(compact) || "END;".equals(compact)) {
            return true;
        }
        if (compact.startsWith("BEGIN ") && compact.length() < 40) {
            return true;
        }
        // JDBC 拉 DBMS_OUTPUT 时自身进库的匿名块, 勿采集
        if (compact.contains("DBMS_OUTPUT.GET_LINE")
                || compact.contains("DBMS_OUTPUT.ENABLE")
                || compact.contains("DBMS_OUTPUT.PUT_LINE")) {
            // 允许业务 SQL 文本偶然包含字样? 极少; 报告脚本本身不进候选
            if (compact.contains("DBMS_OUTPUT.GET_LINE") || compact.contains("DBMS_OUTPUT.ENABLE(")) {
                return true;
            }
        }
        if (compact.contains("? := L_LINE") || compact.contains("? := L_DONE")) {
            return true;
        }
        return false;
    }

    private static void addParsed(LinkedHashSet<String> set, String part) {
        if (part == null) {
            return;
        }
        String raw = part.trim();
        if (raw.isEmpty()) {
            return;
        }
        String[] toks = SPLIT.split(raw);
        for (String tok : toks) {
            addOne(set, tok);
        }
    }

    private static void addOne(LinkedHashSet<String> set, String raw) {
        if (raw == null) {
            return;
        }
        String s = raw.trim().toUpperCase(Locale.ROOT);
        if (s.isEmpty()) {
            return;
        }
        // 仅允许简单标识符, 避免注入 NOT IN 列表
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_' && c != '$' && c != '#') {
                return;
            }
        }
        set.add(s);
    }

    private static String escapeSqlLiteral(String s) {
        if (s == null) {
            return "";
        }
        return s.replace("'", "''");
    }
}
