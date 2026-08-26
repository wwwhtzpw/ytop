package com.yashan.yjdbc.shell;

import jline.Terminal;
import jline.TerminalFactory;
import jline.console.ConsoleReader;
import jline.console.KeyMap;
import jline.console.Operation;
import jline.console.UserInterruptException;
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
import java.util.Locale;

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
     * 提示符下 Ctrl+C: 清空当前输入行并重绘提示, 不退出进程.
     * 由 JLine UserInterruptException 转换而来.
     */
    final class LineInterruptedException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        LineInterruptedException() {
            super("interrupted");
        }
    }

    /**
     * 统一加固 Win/macOS/Linux 常见删除与翻页键序列.
     * Backspace 常为 0x08 或 0x7f; Forward Delete 多为 ESC[3~ 或 ESC[3;N~;
     * 新版终端 (kitty/WezTerm/iTerm2) 的 CSI-u 变体 ESC[3u / ESC[3;Nu 也归一到 DELETE_CHAR;
     * PageUp/PageDown (ESC[5~/[6~) 映射为历史翻页 (JLine 默认未绑).
     * 注意: 这些绑定只在真正进入 JLine 行编辑 (terminal.isSupported) 时生效;
     * 落入 readLineSimple 时无效, 见 {@link #ensureInteractiveTerminalProperty}.
     */
    static void applyCrossPlatformKeyBindings(KeyMap keys) {
        if (keys == null) {
            return;
        }
        keys.bind(String.valueOf((char) 8), Operation.BACKWARD_DELETE_CHAR);
        keys.bind(String.valueOf((char) 127), Operation.BACKWARD_DELETE_CHAR);
        keys.bind("\u001b[3~", Operation.DELETE_CHAR);
        // xterm modifyOtherKeys / 带修饰的 Delete: ESC[3;N~
        for (int n = 1; n <= 9; n++) {
            keys.bind("\u001b[3;" + n + "~", Operation.DELETE_CHAR);
        }
        // kitty / WezTerm / 新 iTerm2 的 CSI-u (modifyOtherKeys 终结符 u) Delete 变体
        keys.bind("\u001b[3u", Operation.DELETE_CHAR);
        for (int n = 2; n <= 7; n++) {
            keys.bind("\u001b[3;" + n + "u", Operation.DELETE_CHAR);
        }
        keys.bind("\u001b[5~", Operation.PREVIOUS_HISTORY);
        keys.bind("\u001b[6~", Operation.NEXT_HISTORY);
    }

    /**
     * macOS 报障: fn+delete (Forward Delete, 发 ESC[3~) 在屏幕上显示为 ^[[3~ / $<3 乱码.
     * 根因不是绑定缺失 (KeyMap 里 ESC[3~ -> DELETE_CHAR 已生效), 而是 JLine 选中了
     * UnsupportedTerminal -> ConsoleReader.readLine() 走 readLineSimple(): 逐字节拼进行缓冲,
     * 任何绑定都不生效, ESC[3~ 便以可见乱码泄漏到屏幕.
     *
     * JLine AUTO 在 TERM=dumb (及个别怪异 TERM) 时会选 UnsupportedTerminal. 故非 Windows 下,
     * 只要有真实交互终端 (System.console()!=null) 或 TERM 为 dumb/空, 就显式强制 unix,
     * 确保 readLine 走行编辑分支. 未显式指定 jline.terminal 时才介入 (尊重 ytop -E 的 -D 覆盖).
     */
    static void ensureInteractiveTerminalProperty() {
        String prop = System.getProperty("jline.terminal");
        if (prop != null && !prop.trim().isEmpty()) {
            return;
        }
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        if (os.contains("win")) {
            return;
        }
        String term = System.getenv("TERM");
        boolean termLooksDumb = term == null || term.isEmpty()
                || "dumb".equalsIgnoreCase(term.trim());
        // 有真实控制台即视为交互终端, 无论 TERM 取值, 一律强制真正的 UnixTerminal
        boolean hasConsole = System.console() != null;
        if (hasConsole || termLooksDumb) {
            System.setProperty("jline.terminal", "unix");
        }
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
            // AUTO; TERM=dumb/空 或 有真实控制台时 ensureInteractiveTerminalProperty 强制 unix,
            // 避免 UnsupportedTerminal -> readLineSimple 导致删除/方向键乱码
            LineSource.ensureInteractiveTerminalProperty();
            Terminal terminal = TerminalFactory.get();
            if (!terminal.isSupported()) {
                // 仍落入 UnsupportedTerminal (例如 stdin 非 tty): 行编辑不可用,
                // 删除/方向键会以原始字节回显, 这里给出明确告警而非静默乱码
                System.err.println("WARN: no interactive terminal (TERM="
                        + System.getenv("TERM") + ", " + terminal.getClass().getSimpleName()
                        + "); line editing disabled, Delete/Arrow keys may leak as raw bytes.");
            } else {
                // TERM 过老 (vt52/vt100/vt102) 缺 DCH/ICH 等 xterm 级序列,
                // JLine 行编辑重绘用的 ANSI 会被终端仿真渲染成乱码 (如 SecureCRT VT100 下显示 $<3).
                // 这里只能提示用户切仿真; 代码侧无法改变终端仿真器的渲染模式.
                String t = System.getenv("TERM");
                if (t != null && (t.equalsIgnoreCase("vt52")
                        || t.equalsIgnoreCase("vt100")
                        || t.equalsIgnoreCase("vt102"))) {
                    System.err.println("NOTE: TERM=" + t + " is too limited for line editing "
                            + "(missing DCH/ICH etc.). If Delete/Arrow keys show garbage, switch "
                            + "your terminal emulation to xterm or xterm-256color "
                            + "(SecureCRT: Session Options -> Terminal -> Emulation).");
                }
            }
            cr = new ConsoleReader(System.in, System.out, terminal);
            LineSource.applyCrossPlatformKeyBindings(cr.getKeys());
            // 禁止 bash 风格 !event 历史展开, 否则 !ls / !pwd 在到达 HOST 前被 JLine 吞掉
            cr.setExpandEvents(false);
            // 提示符 Ctrl+C → UserInterruptException; 读行结束后恢复 intr, SQL 执行期可收 SIGINT
            cr.setHandleUserInterrupt(true);
            mh = new MemoryHistory();
            mh.setMaxSize(SessionHistory.DEFAULT_MAX);
            cr.setHistory(mh);
            // 禁止每行自动入史; 仅由 Repl 在完整提交后 syncHistory
            cr.setHistoryEnabled(false);
            syncHistory(hist);
        }

        @Override
        public String readLine(String prompt) throws IOException {
            try {
                return cr.readLine(prompt == null ? "" : prompt);
            } catch (UserInterruptException e) {
                throw new LineInterruptedException();
            }
        }

        @Override
        public String readSecondaryLine() throws IOException {
            try {
                return cr.readLine("");
            } catch (UserInterruptException e) {
                throw new LineInterruptedException();
            }
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
