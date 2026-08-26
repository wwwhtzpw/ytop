package com.yashan.yjdbc.slash;

import java.io.PrintStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * \help: 斜杠命令帮助 (完整档; 不含 sqlplus 索引).
 * yjdbc 壳本身用法见客户端命令 HELP (非本命令).
 */
public final class HelpCommand implements SlashCommand {

    @Override
    public String name() {
        return "help";
    }

    @Override
    public String description() {
        return "Show help for slash commands";
    }

    @Override
    public String category() {
        return SlashCategory.META;
    }

    @Override
    public List<String> topics() {
        List<String> t = new ArrayList<String>();
        t.add("categories");
        t.add("category");
        t.add("search");
        return t;
    }

    @Override
    public void help(PrintStream out) {
        out.println("\\help - slash command help");
        out.println();
        out.println("Usage:");
        out.println("  \\help");
        out.println("  \\help <cmd>");
        out.println("  \\help <cmd> <topic>");
        out.println("  \\help categories");
        out.println("  \\help category <name>");
        out.println("  \\help search <keyword>...");
        out.println("  \\?                    (alias of \\help)");
        out.println();
        out.println("Notes:");
        out.println("  - Only documents slash (\\) commands.");
        out.println("  - For yjdbc shell usage, type: HELP");
        out.println("  - Use \\<cmd> -h for the same text as \\help <cmd>.");
    }

    @Override
    public void helpTopic(String topic, PrintStream out) {
        if (topic == null) {
            help(out);
            return;
        }
        String t = topic.toLowerCase(Locale.ROOT);
        if ("categories".equals(t) || "category".equals(t) || "search".equals(t)) {
            help(out);
            return;
        }
        out.println("Error: unknown help topic: " + topic);
        out.println("Topics: categories, category, search");
    }

    @Override
    public int run(SlashContext ctx, List<String> argv) {
        PrintStream out = ctx.out();
        PrintStream err = ctx.err();
        SlashRegistry reg = ctx.registry();
        if (argv == null || argv.isEmpty()) {
            printCatalog(out, reg.listAll());
            return 0;
        }
        String a0 = argv.get(0);
        if ("-h".equalsIgnoreCase(a0) || "--help".equalsIgnoreCase(a0)
                || "help".equalsIgnoreCase(a0)) {
            help(out);
            return 0;
        }
        if ("categories".equalsIgnoreCase(a0)) {
            printCategories(out, reg);
            return 0;
        }
        if ("category".equalsIgnoreCase(a0)) {
            if (argv.size() < 2) {
                err.println("Error: \\help category requires a name");
                return 2;
            }
            List<SlashCommand> list = reg.byCategory(argv.get(1));
            if (list.isEmpty()) {
                err.println("Error: no commands in category: " + argv.get(1));
                return 2;
            }
            printCatalog(out, list);
            return 0;
        }
        if ("search".equalsIgnoreCase(a0)) {
            if (argv.size() < 2) {
                err.println("Error: \\help search requires a keyword");
                return 2;
            }
            List<String> needles = argv.subList(1, argv.size());
            List<SlashCommand> hits = reg.search(needles);
            if (hits.isEmpty()) {
                err.println("No slash commands matched; try \\help");
                return 1;
            }
            out.println("Search results:");
            for (SlashCommand c : hits) {
                out.println(String.format("  \\%-10s %s", c.name(), c.description()));
                List<String> topics = c.topics();
                if (topics != null && !topics.isEmpty()) {
                    StringBuilder tb = new StringBuilder("             topic: ");
                    for (int i = 0; i < topics.size(); i++) {
                        if (i > 0) {
                            tb.append(", ");
                        }
                        tb.append(topics.get(i));
                    }
                    out.println(tb.toString());
                }
            }
            return 0;
        }
        SlashCommand cmd = reg.find(a0);
        if (cmd == null) {
            err.println("Error: unknown command: \\" + a0);
            err.println("Try: \\help search " + a0 + "  or  \\help");
            return 2;
        }
        if (argv.size() == 1) {
            cmd.help(out);
            return 0;
        }
        cmd.helpTopic(argv.get(1), out);
        return 0;
    }

    private static void printCatalog(PrintStream out, List<SlashCommand> cmds) {
        Map<String, List<SlashCommand>> byCat = new LinkedHashMap<String, List<SlashCommand>>();
        List<SlashCommand> sorted = new ArrayList<SlashCommand>(cmds);
        Collections.sort(sorted, new Comparator<SlashCommand>() {
            @Override
            public int compare(SlashCommand a, SlashCommand b) {
                return a.name().compareToIgnoreCase(b.name());
            }
        });
        for (SlashCommand c : sorted) {
            String cat = c.category() == null ? SlashCategory.MISC : c.category();
            List<SlashCommand> list = byCat.get(cat);
            if (list == null) {
                list = new ArrayList<SlashCommand>();
                byCat.put(cat, list);
            }
            list.add(c);
        }
        out.println("Slash commands (type \\help <cmd> for details)");
        out.println();
        List<String> cats = new ArrayList<String>(byCat.keySet());
        Collections.sort(cats);
        for (String cat : cats) {
            out.println("[" + cat + "]");
            for (SlashCommand c : byCat.get(cat)) {
                out.println(String.format("  %-10s %s", c.name(), c.description()));
            }
            out.println();
        }
        out.println("Use: \\help <cmd> | \\help <cmd> <topic> | \\help search <kw>");
        out.println("Shell usage: HELP   (client command, not slash)");
    }

    private static void printCategories(PrintStream out, SlashRegistry reg) {
        Map<String, Integer> counts = new LinkedHashMap<String, Integer>();
        for (SlashCommand c : reg.listAll()) {
            String cat = c.category() == null ? SlashCategory.MISC : c.category();
            Integer n = counts.get(cat);
            counts.put(cat, n == null ? 1 : n + 1);
        }
        out.println("Slash command categories:");
        List<String> keys = new ArrayList<String>(counts.keySet());
        Collections.sort(keys);
        for (String k : keys) {
            out.println(String.format("  %-10s %d", k, counts.get(k)));
        }
        out.println();
        out.println("Use: \\help category <name>");
    }
}
