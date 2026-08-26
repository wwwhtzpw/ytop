package com.yashan.yjdbc.cmd.sqlmap;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/**
 * 字面量 → 绑定占位符 (对齐 sqlmap.py convert_literals_to_binds).
 * 与 LiteralBindRewrite (bind→literal, 报告用) 方向相反, 禁止合并.
 */
public final class Lit2Bind {

    public static final class Result {
        public final String sql;
        public final List<String> values;

        public Result(String sql, List<String> values) {
            this.sql = sql;
            this.values = values;
        }
    }

    private static final Pattern NUM_PREV =
            Pattern.compile("(=|>=|<=|<>|!=|>|<|\\(|,)$");

    private Lit2Bind() {
    }

    /**
     * @param bindFormat "?" | ":1" | ":name" | ":bN" (:bN 与 :name 同义, 生成 :b1,:b2,...)
     */
    public static Result convert(String sql, String bindFormat) {
        if (sql == null) {
            sql = "";
        }
        String fmt = bindFormat == null || bindFormat.isEmpty() ? "?" : bindFormat;
        // 帮助与示例使用 -B :bN; 兼容历史 :name
        if (":bn".equalsIgnoreCase(fmt) || "bn".equalsIgnoreCase(fmt)) {
            fmt = ":name";
        }
        List<String> values = new ArrayList<String>();
        StringBuilder result = new StringBuilder();
        int i = 0;
        int bindIdx = 0;
        boolean inComment = false;

        while (i < sql.length()) {
            char ch = sql.charAt(i);

            if (!inComment && ch == '-' && i + 1 < sql.length() && sql.charAt(i + 1) == '-') {
                inComment = true;
            }

            if (inComment) {
                result.append(ch);
                if (ch == '\n') {
                    inComment = false;
                }
                i++;
                continue;
            }

            if (ch == '\'') {
                int j = i - 1;
                while (j >= 0) {
                    char c = sql.charAt(j);
                    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                        j--;
                        continue;
                    }
                    break;
                }
                if (j >= 0) {
                    String preceding = sql.substring(Math.max(0, j - 5), j + 1).toUpperCase();
                    boolean isValue = false;
                    char pj = sql.charAt(j);
                    if (pj == '=' || pj == '>' || pj == '<' || pj == '!') {
                        isValue = true;
                    } else if (preceding.contains("LIKE")) {
                        isValue = true;
                    }
                    if (isValue) {
                        int end = i + 1;
                        while (end < sql.length()) {
                            if (sql.charAt(end) == '\'') {
                                if (end + 1 < sql.length() && sql.charAt(end + 1) == '\'') {
                                    end += 2;
                                    continue;
                                }
                                break;
                            }
                            end++;
                        }
                        String value = sql.substring(i + 1, end).replace("''", "'");
                        bindIdx++;
                        result.append(placeholder(fmt, bindIdx));
                        values.add(value);
                        i = end + 1;
                        continue;
                    }
                }
                result.append(ch);
                i++;
                if (i < sql.length() && sql.charAt(i) == '\'') {
                    result.append(sql.charAt(i));
                    i++;
                }
                continue;
            }

            if (Character.isDigit(ch)) {
                int j = result.length() - 1;
                while (j >= 0) {
                    char c = result.charAt(j);
                    if (c == ' ' || c == '\t') {
                        j--;
                        continue;
                    }
                    break;
                }
                if (j >= 0) {
                    String preceding = result.substring(Math.max(0, j - 4), j + 1);
                    if (NUM_PREV.matcher(preceding).find()) {
                        int end = i;
                        while (end < sql.length()
                                && (Character.isDigit(sql.charAt(end)) || sql.charAt(end) == '.')) {
                            end++;
                        }
                        String value = sql.substring(i, end);
                        bindIdx++;
                        result.append(placeholder(fmt, bindIdx));
                        values.add(value);
                        i = end;
                        continue;
                    }
                }
            }

            result.append(ch);
            i++;
        }

        return new Result(result.toString(), values);
    }

    private static String placeholder(String fmt, int n) {
        if (":1".equals(fmt)) {
            return ":" + n;
        }
        if (":name".equals(fmt) || ":bn".equalsIgnoreCase(fmt)) {
            return ":b" + n;
        }
        return "?";
    }
}
