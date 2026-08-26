package com.yashan.yjdbc.slash;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 斜杠命令注册与分发.
 */
public final class SlashRegistry {
    private final Map<String, SlashCommand> byName =
            new LinkedHashMap<String, SlashCommand>();

    public void register(SlashCommand cmd) {
        if (cmd == null || cmd.name() == null || cmd.name().trim().isEmpty()) {
            throw new IllegalArgumentException("slash command name required");
        }
        String key = cmd.name().trim().toLowerCase(Locale.ROOT);
        byName.put(key, cmd);
    }

    public SlashCommand find(String name) {
        if (name == null) {
            return null;
        }
        return byName.get(name.trim().toLowerCase(Locale.ROOT));
    }

    public List<SlashCommand> listAll() {
        return new ArrayList<SlashCommand>(byName.values());
    }

    public List<SlashCommand> byCategory(String category) {
        List<SlashCommand> out = new ArrayList<SlashCommand>();
        if (category == null) {
            return out;
        }
        String cat = category.trim().toLowerCase(Locale.ROOT);
        for (SlashCommand c : byName.values()) {
            String cc = c.category() == null ? SlashCategory.MISC : c.category();
            if (cat.equals(cc.toLowerCase(Locale.ROOT))) {
                out.add(c);
            }
        }
        return out;
    }

    public List<SlashCommand> search(List<String> tokens) {
        List<SlashCommand> out = new ArrayList<SlashCommand>();
        if (tokens == null || tokens.isEmpty()) {
            return out;
        }
        List<String> needles = new ArrayList<String>();
        for (String t : tokens) {
            if (t != null && !t.trim().isEmpty()) {
                needles.add(t.trim().toLowerCase(Locale.ROOT));
            }
        }
        if (needles.isEmpty()) {
            return out;
        }
        for (SlashCommand c : byName.values()) {
            if (matchesAll(c, needles)) {
                out.add(c);
            }
        }
        return out;
    }

    private static boolean matchesAll(SlashCommand c, List<String> needles) {
        StringBuilder hay = new StringBuilder();
        hay.append(nullToEmpty(c.name())).append(' ');
        hay.append(nullToEmpty(c.description())).append(' ');
        hay.append(nullToEmpty(c.category())).append(' ');
        if (c.topics() != null) {
            for (String t : c.topics()) {
                hay.append(nullToEmpty(t)).append(' ');
            }
        }
        if (c.keywords() != null) {
            for (String k : c.keywords()) {
                hay.append(nullToEmpty(k)).append(' ');
            }
        }
        String h = hay.toString().toLowerCase(Locale.ROOT);
        for (String n : needles) {
            if (!h.contains(n)) {
                return false;
            }
        }
        return true;
    }

    private static String nullToEmpty(String s) {
        return s == null ? "" : s;
    }

    /**
     * 分发以 \ 开头的整行; 返回命令退出码.
     */
    public int dispatch(SlashContext ctx, String rawLine) {
        if (rawLine == null) {
            return 2;
        }
        String line = rawLine.trim();
        if (line.startsWith("\\")) {
            line = line.substring(1).trim();
        }
        // 去掉误加的尾部分号
        if (line.endsWith(";")) {
            line = line.substring(0, line.length() - 1).trim();
        }
        List<String> tokens = LineTokenizer.tokenize(line);
        if (tokens.isEmpty()) {
            ctx.err().println("Error: empty slash command; try \\help");
            return 2;
        }
        String name = tokens.get(0);
        if ("?".equals(name)) {
            name = "help";
        }
        name = name.toLowerCase(Locale.ROOT);
        SlashCommand cmd = find(name);
        if (cmd == null) {
            ctx.err().println("Error: unknown slash command: \\" + name);
            ctx.err().println("Try: \\help  or  \\help search " + name);
            return 2;
        }
        List<String> argv = tokens.size() == 1
                ? Collections.<String>emptyList()
                : tokens.subList(1, tokens.size());
        try {
            return cmd.run(ctx, argv);
        } catch (Exception e) {
            String msg = e.getMessage();
            ctx.err().println("Error: \\" + name + " failed: "
                    + (msg == null ? e.getClass().getSimpleName() : msg));
            return 1;
        }
    }

    /** 内置命令: help + sqlmap. */
    public static SlashRegistry createDefault() {
        SlashRegistry r = new SlashRegistry();
        r.register(new HelpCommand());
        r.register(new com.yashan.yjdbc.cmd.sqlmap.SqlMapSlashCmd());
        return r;
    }

    public Collection<String> names() {
        return Collections.unmodifiableSet(byName.keySet());
    }
}
