package com.yashan.yjdbc.slash;

import java.io.PrintStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

/**
 * 斜杠命令 SPI: 新命令实现本接口并注册到 SlashRegistry.
 */
public interface SlashCommand {
    /** 不含反斜杠, 小写, 如 sqlmap. */
    String name();

    /** 一览用一行摘要 (英文 ASCII). */
    String description();

    /** 分类, 见 SlashCategory. */
    String category();

    /** 子主题 / 子命令名 (小写); 无则 empty. */
    List<String> topics();

    /** 整命令帮助 (等同 \<cmd> -h). */
    void help(PrintStream out);

    /**
     * 子主题帮助; topic 未知时打印英文错误并列出 topics.
     */
    void helpTopic(String topic, PrintStream out);

    /** 搜索关键字; 默认 name + description 分词 + topics. */
    default List<String> keywords() {
        List<String> ks = new ArrayList<String>();
        ks.add(name());
        if (description() != null) {
            for (String t : description().toLowerCase(Locale.ROOT).split("\\s+")) {
                if (!t.isEmpty()) {
                    ks.add(t);
                }
            }
        }
        if (topics() != null) {
            ks.addAll(topics());
        }
        return ks;
    }

    /**
     * argv 为 name 之后的 token.
     * @return 进程风格退出码; 0=ok
     */
    int run(SlashContext ctx, List<String> argv) throws Exception;
}
