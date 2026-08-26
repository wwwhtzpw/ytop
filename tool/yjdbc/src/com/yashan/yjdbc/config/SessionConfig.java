package com.yashan.yjdbc.config;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.PrintStream;
import java.sql.CallableStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * JDBC shell 会话配置: 连接、COL、DEFINE、sqlplus 风格 SET.
 */
public final class SessionConfig {
    /** 无 COL 时单列默认最大显示宽 (超出换行). */
    public static final int DEFAULT_COL_WIDTH = 30;

    private static final String ESC_SENTINEL = "\uE000";

    public String url = "";
    public String user = "";
    public String password = "";
    public int maxRows = 10000;
    public int statementTimeoutSec = 0;
    public boolean serverOutput;
    /** 非交互: 未定义变量报错, 不提示. */
    public boolean batch;
    public String scriptPath = "";
    public String sqlHome = "";

    // ---- sqlplus SET (客户端) ----
    public boolean echo;
    public boolean feedback = true;
    /** FEEDBACK n: 行数 >= 此值才打印 feedback; ON 视为 1. */
    public int feedbackMin = 1;
    public boolean heading = true;
    /** 0 = 不打印表头 (类 sqlplus PAGESIZE 0). */
    public int pagesize = 14;
    public int linesize = 80;
    public boolean timing;
    public boolean verify = true;
    public boolean defineOn = true;
    /** SET DEFINE 替换符, 默认 '&'. */
    public char defineChar = '&';
    /** SET ESCAPE ON|OFF / 字符. */
    public boolean escapeOn;
    public char escapeChar = '\\';
    /**
     * ON: &var / '&var' 改为 JDBC ? 绑定 (默认; 交互与 -E -f 相同).
     * OFF: 字面量替换 (兼容部分依赖文本嵌入的脚本).
     */
    public boolean bindVar = true;
    public String nullText = "";
    public boolean termout = true;
    public boolean autoCommit;
    /**
     * 结果竖排显示 (类 MySQL \\G); 默认表格.
     * 单条语句尾缀 \\G 可临时强制竖排, 不改本开关.
     */
    public boolean displayVertical;
    /** SPOOL 目标; null 表示关闭. */
    public PrintStream spool;
    // ---- P2 SET ----
    /** SET LONG: 长/CLOB 显示最大字符, 默认 80. */
    public int longSize = 80;
    public int longChunkSize = 80;
    /** SET ARRAYSIZE → Statement.setFetchSize, 默认 15. */
    public int arraySize = 15;
    public boolean trimOut = true;
    public boolean trimSpool = true;
    /** 列分隔符, 默认单空格. */
    public String colSep = " ";
    /** 表头下划线字符, 默认 '-'. */
    public String underline = "-";
    /** SET WRAP ON|OFF (全局; 列 TRUNCATED 优先). */
    public boolean wrapOn = true;
    public int numWidth = 10;
    /** 全局数值格式; null 表示仅 NUMWIDTH. */
    public String numFormat;
    // ---- P3 报表 ----
    public String ttitle = "";
    public boolean ttitleOn = true;
    public String btitle = "";
    public boolean btitleOn = true;
    public final List<BreakSpec> breaks = new ArrayList<BreakSpec>();
    public final List<ComputeSpec> computes = new ArrayList<ComputeSpec>();
    // ---- P4 语句缓冲 ----
    public String sqlBuffer = "";
    public String lastSql = "";
    // ---- P5 ----
    /** SET HOST ON|OFF; 默认允许 HOST/!. */
    public boolean hostEnabled = true;

    /** sqlplus COLUMN 格式 (按列名大写). */
    public final Map<String, ColumnFormat> columns = new LinkedHashMap<String, ColumnFormat>();
    public final Map<String, String> defines = new HashMap<String, String>();
    /** sqlplus VARIABLE / :name 客户端绑定 (插入序). */
    public final Map<String, BindVariable> variables = new LinkedHashMap<String, BindVariable>();
    /** REFCURSOR 持有的 CallableStatement 引用计数 (同一 CS 可挂多个变量). */
    private final Map<CallableStatement, Set<BindVariable>> cursorCsHolders =
            new IdentityHashMap<CallableStatement, Set<BindVariable>>();

    /**
     * WHENEVER SQLERROR / OSERROR 策略 (默认 CONTINUE NONE, 与 sqlplus 一致).
     */
    public final WheneverPolicy wheneverSqlError = WheneverPolicy.continueNone();
    public final WheneverPolicy wheneverOsError = WheneverPolicy.continueNone();
    /** 最近一次 SQL 错误码; 成功执行后置 0. */
    public int lastSqlCode;
    /** 最近一次 SQL 是否失败 (供 EXIT SQL.SQLCODE / WHENEVER). */
    public boolean lastSqlFailed;

    public SessionConfig() {
    }

    /** BREAK ON col ... */
    public static final class BreakSpec {
        public String column;
        public int skipLines;
        public boolean skipPage;
    }

    /** COMPUTE func OF col ON break|REPORT */
    public static final class ComputeSpec {
        public String func;
        public String ofColumn;
        public String onBreak;
    }

    /** sqlplus COLUMN 列格式. */
    public static final class ColumnFormat {
        public Integer width;
        public String numFormat;
        public String heading;
        public boolean noprint;
        /** LEFT | CENTER | RIGHT; null=默认 (数右文左近似由打印层处理). */
        public String justify;
        /** TRUNCATED | WRAPPED | WORD_WRAPPED; null=默认 WRAPPED. */
        public String wrap;
        public String newValue;
        public String oldValue;
    }

    /** sqlplus VARIABLE 声明. */
    public static final class BindVariable {
        public enum Kind {
            NUMBER, VARCHAR2, CHAR, REFCURSOR
        }

        public final Kind kind;
        public final int size;
        /** 当前值的文本形式; null 表示未赋值 (标量). */
        public String value;
        /** REFCURSOR 打开后的结果集; 所有权在本对象. */
        public ResultSet cursorRs;
        /** 产生 cursorRs 的 call; 与其它变量可能共享. */
        public CallableStatement holdCs;

        public BindVariable(Kind kind, int size) {
            this.kind = kind;
            this.size = size;
            this.value = null;
            this.cursorRs = null;
            this.holdCs = null;
        }

        public String typeLabel() {
            if (kind == Kind.REFCURSOR) {
                return "REFCURSOR";
            }
            if (kind == Kind.NUMBER) {
                return "NUMBER";
            }
            if (kind == Kind.CHAR) {
                return size > 0 ? ("CHAR(" + size + ")") : "CHAR";
            }
            return size > 0 ? ("VARCHAR2(" + size + ")") : "VARCHAR2";
        }

        public boolean isCursorOpen() {
            return kind == Kind.REFCURSOR && cursorRs != null;
        }
    }

    /**
     * sqlplus WHENEVER 策略.
     * status: SUCCESS | FAILURE | WARNING | SQL.SQLCODE | 数字字符串.
     * txn: NONE | COMMIT | ROLLBACK.
     */
    public static final class WheneverPolicy {
        public boolean exit;
        public String status = "FAILURE";
        public String txn = "NONE";

        public static WheneverPolicy continueNone() {
            WheneverPolicy p = new WheneverPolicy();
            p.exit = false;
            p.status = "FAILURE";
            p.txn = "NONE";
            return p;
        }

        public void copyFrom(WheneverPolicy o) {
            this.exit = o.exit;
            this.status = o.status;
            this.txn = o.txn;
        }
    }

    /**
     * 将 EXIT/WHENEVER 状态字解析为进程退出码.
     * SUCCESS=0, FAILURE=1, WARNING=2, SQL.SQLCODE=|lastSqlCode| (0 且曾失败则 1), 数字=原值.
     */
    public int resolveExitStatus(String statusToken) {
        String s = statusToken == null ? "SUCCESS" : statusToken.trim().toUpperCase(Locale.ROOT);
        if (s.isEmpty() || "SUCCESS".equals(s)) {
            return 0;
        }
        if ("FAILURE".equals(s)) {
            return 1;
        }
        if ("WARNING".equals(s)) {
            return 2;
        }
        if ("SQL.SQLCODE".equals(s) || "SQLCODE".equals(s)) {
            int c = lastSqlCode;
            if (c < 0) {
                c = -c;
            }
            if (c == 0 && lastSqlFailed) {
                return 1;
            }
            if (c > 255) {
                return c % 256;
            }
            return c;
        }
        try {
            int n = Integer.parseInt(s);
            if (n < 0) {
                n = -n;
            }
            if (n > 255) {
                return n % 256;
            }
            return n;
        } catch (NumberFormatException e) {
            return 1;
        }
    }

    /** expandForExec 结果: SQL 文本 + 可选 JDBC 绑定值 (按 ? 顺序). */
    public static final class ExpandResult {
        public final String sql;
        public final List<String> binds;

        public ExpandResult(String sql, List<String> binds) {
            this.sql = sql;
            this.binds = binds == null
                    ? Collections.<String>emptyList()
                    : Collections.unmodifiableList(new ArrayList<String>(binds));
        }

        public boolean hasBinds() {
            return binds != null && !binds.isEmpty();
        }
    }

    private Pattern substPattern() {
        String d = Pattern.quote(String.valueOf(defineChar));
        return Pattern.compile(d + "(" + d + ")?([A-Za-z][A-Za-z0-9_$#]*|[0-9]+)(\\.)?");
    }

    private Pattern exactVarPattern() {
        String d = Pattern.quote(String.valueOf(defineChar));
        return Pattern.compile(d + "(" + d + ")?([A-Za-z][A-Za-z0-9_$#]*|[0-9]+)(\\.)?");
    }

    private String protectEscapedDefines(String text) {
        if (!escapeOn || text == null) {
            return text;
        }
        String esc = String.valueOf(escapeChar) + defineChar;
        return text.replace(esc, ESC_SENTINEL);
    }

    private String restoreEscapedDefines(String text) {
        if (text == null) {
            return null;
        }
        return text.replace(ESC_SENTINEL, String.valueOf(defineChar));
    }

    private static String rtrimLine(String line) {
        if (line == null || line.isEmpty()) {
            return line;
        }
        int end = line.length();
        while (end > 0 && line.charAt(end - 1) == ' ') {
            end--;
        }
        return line.substring(0, end);
    }

    /** 同时写终端 (若 TERMOUT) 与 SPOOL; 尊重 TRIMOUT/TRIMSPOOL. */
    public void println(PrintStream term, String line) {
        if (termout && term != null) {
            term.println(trimOut ? rtrimLine(line) : line);
        }
        if (spool != null) {
            spool.println(trimSpool ? rtrimLine(line) : line);
        }
    }

    public void print(PrintStream term, String text) {
        if (termout && term != null) {
            term.print(text);
        }
        if (spool != null) {
            spool.print(text);
        }
    }

    public ColumnFormat ensureColumn(String name) {
        if (name == null || name.trim().isEmpty()) {
            return null;
        }
        String key = name.trim().toUpperCase(Locale.ROOT);
        ColumnFormat cf = columns.get(key);
        if (cf == null) {
            cf = new ColumnFormat();
            columns.put(key, cf);
        }
        return cf;
    }

    public ColumnFormat getColumn(String name) {
        if (name == null) {
            return null;
        }
        return columns.get(name.trim().toUpperCase(Locale.ROOT));
    }

    public void setColWidth(String name, int width) {
        if (name == null || name.trim().isEmpty() || width < 1) {
            return;
        }
        ColumnFormat cf = ensureColumn(name);
        cf.width = Integer.valueOf(width);
        cf.numFormat = null;
    }

    public void clearColWidth(String name) {
        if (name == null) {
            return;
        }
        columns.remove(name.trim().toUpperCase(Locale.ROOT));
    }

    /** 未设置 COL 时返回 null (由打印层用默认宽). */
    public Integer getColWidth(String name) {
        ColumnFormat cf = getColumn(name);
        if (cf == null) {
            return null;
        }
        if (cf.width != null && cf.width.intValue() > 0) {
            return cf.width;
        }
        if (cf.numFormat != null) {
            int w = numFormatWidth(cf.numFormat);
            return w > 0 ? Integer.valueOf(w) : null;
        }
        return null;
    }

    public void setColHeading(String name, String heading) {
        if (name == null || name.trim().isEmpty()) {
            return;
        }
        ensureColumn(name).heading = heading == null ? "" : heading;
    }

    public void clearAllColumns() {
        columns.clear();
    }

    public String getColHeading(String name) {
        ColumnFormat cf = getColumn(name);
        return cf == null ? null : cf.heading;
    }

    /** 数值 FORMAT 掩码显示宽 (含逗号等字面字符). */
    public static int numFormatWidth(String mask) {
        if (mask == null) {
            return 0;
        }
        int n = 0;
        for (int i = 0; i < mask.length(); i++) {
            char c = mask.charAt(i);
            if (c == '9' || c == '0' || c == '#' || c == ',' || c == '.' || c == '$'
                    || c == 'B' || c == 'b' || c == 'M' || c == 'm' || c == 'S' || c == 's'
                    || c == 'P' || c == 'p' || c == 'G' || c == 'g' || c == 'D' || c == 'd'
                    || c == ' ' || c == 'P' || c == '-') {
                n++;
            }
        }
        return n > 0 ? n : mask.length();
    }

    public void define(String name, String value) {
        if (name == null || name.trim().isEmpty()) {
            return;
        }
        defines.put(name.trim().toUpperCase(Locale.ROOT), value == null ? "" : value);
    }

    /**
     * 脚本/--batch 下仍可对 &/&&/ACCEPT 提问的条件: stdin 为交互终端.
     * 非 TTY (管道/CI/</dev/null) 禁止提问, 须 DEFINE / --define.
     * 不用单靠 System.console(): 部分 JDK 在 stdin 重定向后仍非 null.
     */
    public boolean canPromptForDefine() {
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        if (os.indexOf("win") >= 0) {
            return System.console() != null;
        }
        try {
            ProcessBuilder pb = new ProcessBuilder("sh", "-c", "test -t 0");
            pb.redirectInput(ProcessBuilder.Redirect.INHERIT);
            File devNull = new File("/dev/null");
            pb.redirectOutput(ProcessBuilder.Redirect.to(devNull));
            pb.redirectError(ProcessBuilder.Redirect.to(devNull));
            Process p = pb.start();
            if (!p.waitFor(2L, TimeUnit.SECONDS)) {
                p.destroyForcibly();
                return System.console() != null;
            }
            return p.exitValue() == 0;
        } catch (Exception e) {
            return System.console() != null;
        }
    }

    public void undefine(String name) {
        if (name == null) {
            return;
        }
        defines.remove(name.trim().toUpperCase(Locale.ROOT));
    }

    public String getDefine(String name) {
        if (name == null) {
            return null;
        }
        return defines.get(name.trim().toUpperCase(Locale.ROOT));
    }

    public BindVariable getVariable(String name) {
        if (name == null) {
            return null;
        }
        return variables.get(name.trim().toUpperCase(Locale.ROOT));
    }

    public void putVariable(String name, BindVariable var) {
        if (name == null || name.trim().isEmpty() || var == null) {
            return;
        }
        String key = name.trim().toUpperCase(Locale.ROOT);
        BindVariable prev = variables.get(key);
        if (prev != null && prev != var) {
            closeVariableCursor(prev);
        }
        variables.put(key, var);
    }

    /**
     * 将 OUT 游标挂到变量; 只关闭旧 ResultSet, CS 按引用集管理.
     */
    public void setVariableCursor(BindVariable bv, ResultSet rs, CallableStatement cs) {
        if (bv == null || bv.kind != BindVariable.Kind.REFCURSOR) {
            return;
        }
        closeResultSetQuiet(bv.cursorRs);
        bv.cursorRs = rs;
        if (bv.holdCs != null && bv.holdCs != cs) {
            detachFromCs(bv, bv.holdCs);
        }
        bv.holdCs = cs;
        if (cs != null) {
            Set<BindVariable> set = cursorCsHolders.get(cs);
            if (set == null) {
                set = new HashSet<BindVariable>();
                cursorCsHolders.put(cs, set);
            }
            set.add(bv);
        }
    }

    public void closeVariableCursor(BindVariable bv) {
        if (bv == null) {
            return;
        }
        closeResultSetQuiet(bv.cursorRs);
        bv.cursorRs = null;
        CallableStatement cs = bv.holdCs;
        bv.holdCs = null;
        if (cs != null) {
            detachFromCs(bv, cs);
        }
    }

    public void closeAllCursors() {
        List<BindVariable> copy = new ArrayList<BindVariable>(variables.values());
        for (BindVariable bv : copy) {
            if (bv.kind == BindVariable.Kind.REFCURSOR) {
                closeVariableCursor(bv);
            }
        }
    }

    private void detachFromCs(BindVariable bv, CallableStatement cs) {
        Set<BindVariable> set = cursorCsHolders.get(cs);
        if (set != null) {
            set.remove(bv);
            if (set.isEmpty()) {
                cursorCsHolders.remove(cs);
                try {
                    cs.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
        }
    }

    private static void closeResultSetQuiet(ResultSet rs) {
        if (rs == null) {
            return;
        }
        try {
            rs.close();
        } catch (SQLException ignored) {
            // ignore
        }
    }

    /**
     * 执行前展开: BINDVAR ON 时 &var → ? (DQL/DML);
     * PL/SQL 匿名块 (DECLARE/BEGIN) 仍字面量替换 (库端对块内 ? 支持不完整).
     * 失败返回 null (已向 err 输出原因).
     */
    public ExpandResult expandForExec(String text, BufferedReader promptIn,
                                      PrintStream out, PrintStream err) {
        if (text == null) {
            return null;
        }
        String work = protectEscapedDefines(text);
        if (!defineOn || work.indexOf(defineChar) < 0) {
            return new ExpandResult(restoreEscapedDefines(work), Collections.<String>emptyList());
        }
        ExpandResult r;
        // PL/SQL 块内 ? 会导致编译失败 (如 CONSTANT := ?); 强制字面量
        boolean useBinds = bindVar && !looksLikePlsqlAnonymousBlock(work);
        if (useBinds) {
            r = expandAsBinds(work, promptIn, out, err);
        } else {
            String expanded = expandAsLiterals(work, promptIn, out, err);
            if (expanded == null) {
                return null;
            }
            r = new ExpandResult(expanded, Collections.<String>emptyList());
        }
        if (r == null) {
            return null;
        }
        return new ExpandResult(restoreEscapedDefines(r.sql), r.binds);
    }

    /** DECLARE/BEGIN 开头的匿名块 (忽略前导空白与简单注释行). */
    static boolean looksLikePlsqlAnonymousBlock(String sql) {
        if (sql == null) {
            return false;
        }
        String s = sql.trim();
        while (s.startsWith("--")) {
            int nl = s.indexOf('\n');
            if (nl < 0) {
                return false;
            }
            s = s.substring(nl + 1).trim();
        }
        if (s.length() < 5) {
            return false;
        }
        String u = s.substring(0, Math.min(7, s.length())).toUpperCase(Locale.ROOT);
        return u.startsWith("DECLARE") || u.startsWith("BEGIN");
    }

    /**
     * 替换 &var / &&var 为字面量 (PROMPT 等客户端展示; 不走 BINDVAR/?).
     * VERIFY ON 时在 out 打印 old/new.
     * SQL 执行请用 {@link #expandForExec}.
     */
    public String substitute(String text, BufferedReader promptIn,
                             PrintStream out, PrintStream err) {
        if (text == null) {
            return null;
        }
        String work = protectEscapedDefines(text);
        if (!defineOn || work.indexOf(defineChar) < 0) {
            return restoreEscapedDefines(work);
        }
        String expanded = expandAsLiterals(work, promptIn, out, err);
        if (expanded == null) {
            return null;
        }
        return restoreEscapedDefines(expanded);
    }

    private String expandAsLiterals(String text, BufferedReader promptIn,
                                    PrintStream out, PrintStream err) {
        String original = text;
        Matcher m = substPattern().matcher(text);
        StringBuffer sb = new StringBuffer();
        while (m.find()) {
            boolean permanent = m.group(1) != null;
            String name = m.group(2);
            String val = resolveVar(name, permanent, promptIn, out, err);
            if (val == null) {
                return null;
            }
            m.appendReplacement(sb, Matcher.quoteReplacement(val));
        }
        m.appendTail(sb);
        String expanded = sb.toString();
        if (verify && !original.equals(expanded)) {
            println(out, "old: " + restoreEscapedDefines(original));
            println(out, "new: " + restoreEscapedDefines(expanded));
        }
        return expanded;
    }

    /**
     * BINDVAR ON: 完整 '&name' / 裸 &name → ?; 引号内部分替换仍字面量.
     */
    private ExpandResult expandAsBinds(String text, BufferedReader promptIn,
                                       PrintStream out, PrintStream err) {
        String original = text;
        StringBuilder sb = new StringBuilder(text.length());
        List<String> binds = new ArrayList<String>();
        int i = 0;
        int n = text.length();
        while (i < n) {
            char c = text.charAt(i);
            if (c == '\'' || c == '"') {
                char q = c;
                int j = i + 1;
                StringBuilder inner = new StringBuilder();
                while (j < n) {
                    char d = text.charAt(j);
                    if (d == q) {
                        if (q == '\'' && j + 1 < n && text.charAt(j + 1) == '\'') {
                            inner.append('\'');
                            j += 2;
                            continue;
                        }
                        break;
                    }
                    inner.append(d);
                    j++;
                }
                if (j >= n) {
                    sb.append(text.substring(i));
                    break;
                }
                String content = inner.toString();
                Matcher exact = exactVarPattern().matcher(content);
                if (exact.matches()) {
                    boolean permanent = exact.group(1) != null;
                    String name = exact.group(2);
                    String val = resolveVar(name, permanent, promptIn, out, err);
                    if (val == null) {
                        return null;
                    }
                    sb.append('?');
                    binds.add(val);
                } else if (content.indexOf(defineChar) >= 0) {
                    String lit = expandFragmentLiterals(content, promptIn, out, err);
                    if (lit == null) {
                        return null;
                    }
                    sb.append(q).append(lit).append(q);
                } else {
                    sb.append(q).append(content).append(q);
                }
                i = j + 1;
                continue;
            }
            if (c == defineChar && (i == 0 || !isIdentChar(text.charAt(i - 1)))) {
                int k = i + 1;
                boolean permanent = false;
                if (k < n && text.charAt(k) == defineChar) {
                    permanent = true;
                    k++;
                }
                if (k < n && (isIdentStart(text.charAt(k)) || isDigit(text.charAt(k)))) {
                    int startName = k;
                    if (isDigit(text.charAt(k))) {
                        while (k < n && isDigit(text.charAt(k))) {
                            k++;
                        }
                    } else {
                        k++;
                        while (k < n && isIdentChar(text.charAt(k))) {
                            k++;
                        }
                    }
                    String name = text.substring(startName, k);
                    // sqlplus: &name.xxx 中的 '.' 仅终结变量名, 不输出
                    if (k < n && text.charAt(k) == '.') {
                        k++;
                    }
                    String val = resolveVar(name, permanent, promptIn, out, err);
                    if (val == null) {
                        return null;
                    }
                    sb.append('?');
                    binds.add(val);
                    i = k;
                    continue;
                }
            }
            sb.append(c);
            i++;
        }
        String sql = sb.toString();
        if (verify && (!original.equals(sql) || !binds.isEmpty())) {
            println(out, "old: " + original);
            println(out, "new: " + sql);
            if (!binds.isEmpty()) {
                StringBuilder b = new StringBuilder("binds:");
                for (int bi = 0; bi < binds.size(); bi++) {
                    b.append(" [").append(bi + 1).append("]=").append(binds.get(bi));
                }
                println(out, b.toString());
            }
        }
        return new ExpandResult(sql, binds);
    }

    /** 片段内字面量替换 (无 VERIFY). */
    private String expandFragmentLiterals(String text, BufferedReader promptIn,
                                          PrintStream out, PrintStream err) {
        Matcher m = substPattern().matcher(text);
        StringBuffer sb = new StringBuffer();
        while (m.find()) {
            boolean permanent = m.group(1) != null;
            String name = m.group(2);
            String val = resolveVar(name, permanent, promptIn, out, err);
            if (val == null) {
                return null;
            }
            m.appendReplacement(sb, Matcher.quoteReplacement(val));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    /**
     * 解析变量值; 失败返回 null.
     * permanent=true (&&) 时写入 DEFINE.
     */
    private String resolveVar(String name, boolean permanent,
                              BufferedReader promptIn, PrintStream out, PrintStream err) {
        String key = name.toUpperCase(Locale.ROOT);
        String val = defines.get(key);
        if (val != null) {
            return val;
        }
        if (!canPromptForDefine()) {
            err.println("Error: undefined variable " + name
                    + " (non-interactive; use DEFINE or --define)");
            return null;
        }
        print(out, "Enter value for " + name + ": ");
        if (termout && out != null) {
            out.flush();
        }
        try {
            if (promptIn == null) {
                err.println("Error: undefined variable " + name);
                return null;
            }
            String line = promptIn.readLine();
            if (line == null) {
                err.println("Error: undefined variable " + name);
                return null;
            }
            val = line;
        } catch (IOException e) {
            err.println("Error reading variable " + name + ": " + e.getMessage());
            return null;
        }
        if (permanent) {
            defines.put(key, val);
        }
        return val;
    }

    private static boolean isIdentStart(char c) {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
    }

    private static boolean isDigit(char c) {
        return c >= '0' && c <= '9';
    }

    private static boolean isIdentChar(char c) {
        return isIdentStart(c)
                || isDigit(c)
                || c == '_' || c == '$' || c == '#';
    }

    /**
     * 为 @script 位置参数设置 DEFINE 1..n; 返回需在 finally 中 restore 的快照
     * (value=null 表示原先不存在).
     */
    public Map<String, String> beginScriptArgs(String[] args) {
        Map<String, String> saved = new HashMap<String, String>();
        int max = 20;
        if (args != null && args.length > max) {
            max = args.length;
        }
        for (int i = 1; i <= max; i++) {
            String k = String.valueOf(i);
            if (defines.containsKey(k)) {
                saved.put(k, defines.get(k));
            } else {
                saved.put(k, null);
            }
            defines.remove(k);
        }
        if (args != null) {
            for (int i = 0; i < args.length; i++) {
                defines.put(String.valueOf(i + 1), args[i] == null ? "" : args[i]);
            }
        }
        return saved;
    }

    /** 恢复 beginScriptArgs 保存的位置参数. */
    public void endScriptArgs(Map<String, String> saved) {
        if (saved == null) {
            return;
        }
        for (Map.Entry<String, String> e : saved.entrySet()) {
            if (e.getValue() == null) {
                defines.remove(e.getKey());
            } else {
                defines.put(e.getKey(), e.getValue());
            }
        }
    }
}
