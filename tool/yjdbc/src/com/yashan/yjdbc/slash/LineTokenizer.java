package com.yashan.yjdbc.slash;

import java.util.ArrayList;
import java.util.List;

/**
 * 按空白拆分命令行, 支持单引号 / 双引号包裹.
 */
public final class LineTokenizer {
    private LineTokenizer() {
    }

    public static List<String> tokenize(String line) {
        List<String> out = new ArrayList<String>();
        if (line == null) {
            return out;
        }
        String s = line.trim();
        if (s.isEmpty()) {
            return out;
        }
        StringBuilder cur = new StringBuilder();
        char quote = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (quote != 0) {
                if (c == quote) {
                    quote = 0;
                } else {
                    cur.append(c);
                }
                continue;
            }
            if (c == '\'' || c == '"') {
                quote = c;
                continue;
            }
            if (Character.isWhitespace(c)) {
                if (cur.length() > 0) {
                    out.add(cur.toString());
                    cur.setLength(0);
                }
                continue;
            }
            cur.append(c);
        }
        if (cur.length() > 0) {
            out.add(cur.toString());
        }
        return out;
    }
}
