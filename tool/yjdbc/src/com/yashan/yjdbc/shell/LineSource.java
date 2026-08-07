package com.yashan.yjdbc.shell;

import jline.Terminal;
import jline.TerminalFactory;
import jline.console.ConsoleReader;
import jline.console.KeyMap;
import jline.console.Operation;
import jline.console.history.MemoryHistory;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.io.StringReader;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * 交互行输入: JLine (行编辑+历史展示) 或普通 BufferedReader.
 * 会话历史由 {@link SessionHistory} 维护; JLine 禁止自动入史.
 */
public interface LineSource {

    String readLine(String prompt) throws IOException;

    /** ACCEPT / &amp; 展开 / PAUSE 等二次读入; 永不写入 SessionHistory. */
    String readSecondaryLine() throws IOException;

    void syncHistory(SessionHistory hist);

    void close();

    /**
     * 统一加固 Win/macOS/Linux 常见删除与翻页键序列.
     * Backspace 常为 0x08 或 0x7f; Forward Delete 多为 ESC[3~;
     * PageUp/PageDown (ESC[5~/[6~) 映射为历史翻页 (JLine 默认未绑).
     */
    static void applyCrossPlatformKeyBindings(KeyMap keys) {
        if (keys == null) {
            return;
        }
        keys.bind(String.valueOf((char) 8), Operation.BACKWARD_DELETE_CHAR);
        keys.bind(String.valueOf((char) 127), Operation.BACKWARD_DELETE_CHAR);
        keys.bind("\u001b[3~", Operation.DELETE_CHAR);
        // 部分终端 / Windows 控制台变体
        keys.bind("\u001b[3;5~", Operation.DELETE_CHAR);
        keys.bind("\u001b[5~", Operation.PREVIOUS_HISTORY);
        keys.bind("\u001b[6~", Operation.NEXT_HISTORY);
    }

    /**
     * @param wantJLine 尝试 JLine; 失败则 WARN 并回退 Plain
     */
    static LineSource open(boolean wantJLine, SessionHistory hist, PrintStream err) {
        if (wantJLine) {
            try {
                return new JLineSource(hist);
            } catch (Throwable t) {
                if (err != null) {
                    err.println("WARN: JLine unavailable, falling back to plain input: "
                            + t.getMessage());
                }
            }
        }
        return new PlainSource();
    }

    /**
     * 将会话历史桥到 {@link BufferedReader#readLine()}, 供 SessionConfig / ACCEPT 使用.
     * 每次 readLine 走 {@link #readSecondaryLine()} (不入史).
     */
    static BufferedReader asSecondaryBufferedReader(final LineSource ls) {
        return new BufferedReader(new StringReader("")) {
            @Override
            public String readLine() throws IOException {
                return ls.readSecondaryLine();
            }
        };
    }

    /**
     * 会话内提交历史: 去重 + 上限; 不依赖 JLine.
     * add 契约: null 忽略; trim 后空串不入史; 与最后一条全文相同不追加; 超 max 丢最旧.
     */
    final class SessionHistory {
        public static final int DEFAULT_MAX = 500;
        private final int max;
        private final ArrayList<String> entries = new ArrayList<String>();

        public SessionHistory() {
            this(DEFAULT_MAX);
        }

        public SessionHistory(int max) {
            this.max = max <= 0 ? DEFAULT_MAX : max;
        }

        public void add(String text) {
            if (text == null) {
                return;
            }
            String t = text.trim();
            if (t.isEmpty()) {
                return;
            }
            if (!entries.isEmpty() && t.equals(entries.get(entries.size() - 1))) {
                return;
            }
            entries.add(t);
            while (entries.size() > max) {
                entries.remove(0);
            }
        }

        public List<String> snapshot() {
            return Collections.unmodifiableList(new ArrayList<String>(entries));
        }

        public int size() {
            return entries.size();
        }

        /** 去掉行尾 ; 或 \\G/\\g, 与 rememberSql 对齐. */
        public static String stripSqlTerminator(String raw) {
            if (raw == null) {
                return "";
            }
            String t = raw.trim();
            if (t.endsWith("\\G") || t.endsWith("\\g")) {
                return t.substring(0, t.length() - 2).trim();
            }
            if (t.endsWith(";")) {
                return t.substring(0, t.length() - 1).trim();
            }
            return t;
        }
    }

    final class PlainSource implements LineSource {
        private final BufferedReader br = new BufferedReader(
                new InputStreamReader(System.in, Charset.defaultCharset()));

        @Override
        public String readLine(String prompt) throws IOException {
            if (prompt != null && !prompt.isEmpty()) {
                System.out.print(prompt);
                System.out.flush();
            }
            return br.readLine();
        }

        @Override
        public String readSecondaryLine() throws IOException {
            return br.readLine();
        }

        @Override
        public void syncHistory(SessionHistory hist) {
            // no-op
        }

        @Override
        public void close() {
            // leave System.in open
        }
    }

    final class JLineSource implements LineSource {
        private final ConsoleReader cr;
        private final MemoryHistory mh;

        JLineSource(SessionHistory hist) throws IOException {
            // TerminalFactory AUTO: Unix(macOS/Linux) / Windows / AnsiWindows, 禁止写死 unix
            Terminal terminal = TerminalFactory.get();
            cr = new ConsoleReader(System.in, System.out, terminal);
            LineSource.applyCrossPlatformKeyBindings(cr.getKeys());
            mh = new MemoryHistory();
            mh.setMaxSize(SessionHistory.DEFAULT_MAX);
            cr.setHistory(mh);
            // 禁止每行自动入史; 仅由 Repl 在完整提交后 syncHistory
            cr.setHistoryEnabled(false);
            syncHistory(hist);
        }

        @Override
        public String readLine(String prompt) throws IOException {
            return cr.readLine(prompt == null ? "" : prompt);
        }

        @Override
        public String readSecondaryLine() throws IOException {
            return cr.readLine("");
        }

        @Override
        public void syncHistory(SessionHistory hist) {
            mh.clear();
            if (hist == null) {
                return;
            }
            for (String e : hist.snapshot()) {
                mh.add(e);
            }
        }

        @Override
        public void close() {
            try {
                cr.shutdown();
            } catch (Exception ignored) {
                // ignore
            }
        }
    }
}
