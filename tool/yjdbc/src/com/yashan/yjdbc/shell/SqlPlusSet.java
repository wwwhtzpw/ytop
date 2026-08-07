package com.yashan.yjdbc.shell;

import com.yashan.yjdbc.config.SessionConfig;
import com.yashan.yjdbc.db.JdbcSession;

import java.io.PrintStream;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;

/**
 * sqlplus 风格 SET / SHOW 子集.
 */
public final class SqlPlusSet {
    private SqlPlusSet() {
    }

    /**
     * 处理 SET ...; 返回 true 表示已消费 (含 unsupported).
     * quiet=true 时不打印成功回显 (脚本内配置命令静默; 错误仍打 stderr).
     */
    public static boolean handleSet(String rest, JdbcSession session,
                                    PrintStream out, PrintStream err) {
        return handleSet(rest, session, out, err, false);
    }

    public static boolean handleSet(String rest, JdbcSession session,
                                    PrintStream out, PrintStream err, boolean quiet) {
        if (rest == null) {
            return true;
        }
        rest = rest.trim();
        if (rest.isEmpty()) {
            err.println("Error: SET requires an option");
            return true;
        }
        String[] parts = rest.split("\\s+", 3);
        String opt = parts[0].toUpperCase(Locale.ROOT);
        String arg1 = parts.length > 1 ? parts[1] : "";
        String arg2 = parts.length > 2 ? parts[2] : "";
        SessionConfig cfg = session.config();

        if ("SERVEROUTPUT".equals(opt)) {
            Boolean on = parseOnOff(arg1);
            if (on == null) {
                err.println("Error: SET SERVEROUTPUT ON|OFF");
                return true;
            }
            cfg.serverOutput = on.booleanValue();
            // SIZE 忽略; ON 时 ENABLE 缓冲, 执行后由 SqlExecutor GET_LINE 拉取
            if (on.booleanValue()) {
                enableDbmsOutput(session, err);
            }
            ack(cfg, out, quiet, "SERVEROUTPUT " + (on.booleanValue() ? "ON" : "OFF"));
            return true;
        }
        if ("ECHO".equals(opt)) {
            return setBool(cfg, out, err, quiet, "ECHO", arg1, new BoolSink() {
                public void set(boolean v) { cfg.echo = v; }
                public boolean get() { return cfg.echo; }
            });
        }
        if ("FEEDBACK".equals(opt) || "FEED".equals(opt)) {
            if (arg1.isEmpty()) {
                err.println("Error: SET FEEDBACK ON|OFF|n");
                return true;
            }
            Boolean on = parseOnOff(arg1);
            if (on != null) {
                cfg.feedback = on.booleanValue();
                cfg.feedbackMin = 1;
                ack(cfg, out, quiet, "FEEDBACK " + (on.booleanValue() ? "ON" : "OFF"));
                return true;
            }
            try {
                int n = Integer.parseInt(arg1);
                if (n < 0) {
                    err.println("Error: FEEDBACK n must be >= 0");
                    return true;
                }
                cfg.feedback = n > 0;
                cfg.feedbackMin = n == 0 ? Integer.MAX_VALUE : n;
                ack(cfg, out, quiet, "FEEDBACK " + n);
            } catch (NumberFormatException e) {
                err.println("Error: SET FEEDBACK ON|OFF|n");
            }
            return true;
        }
        if ("HEADING".equals(opt) || "HEA".equals(opt)) {
            return setBool(cfg, out, err, quiet, "HEADING", arg1, new BoolSink() {
                public void set(boolean v) { cfg.heading = v; }
                public boolean get() { return cfg.heading; }
            });
        }
        if ("PAGESIZE".equals(opt) || "PAGES".equals(opt)) {
            return setInt(cfg, out, err, quiet, "PAGESIZE", arg1, 0, Integer.MAX_VALUE, new IntSink() {
                public void set(int v) { cfg.pagesize = v; }
                public int get() { return cfg.pagesize; }
            });
        }
        if ("LINESIZE".equals(opt) || "LINES".equals(opt)) {
            return setInt(cfg, out, err, quiet, "LINESIZE", arg1, 1, 32767, new IntSink() {
                public void set(int v) { cfg.linesize = v; }
                public int get() { return cfg.linesize; }
            });
        }
        if ("TIMING".equals(opt)) {
            return setBool(cfg, out, err, quiet, "TIMING", arg1, new BoolSink() {
                public void set(boolean v) { cfg.timing = v; }
                public boolean get() { return cfg.timing; }
            });
        }
        if ("VERIFY".equals(opt) || "VER".equals(opt)) {
            return setBool(cfg, out, err, quiet, "VERIFY", arg1, new BoolSink() {
                public void set(boolean v) { cfg.verify = v; }
                public boolean get() { return cfg.verify; }
            });
        }
        if ("DEFINE".equals(opt)) {
            Boolean on = parseOnOff(arg1);
            if (on != null) {
                cfg.defineOn = on.booleanValue();
                if (on.booleanValue()) {
                    cfg.defineChar = '&';
                }
                ack(cfg, out, quiet, "DEFINE " + (on.booleanValue() ? ("ON (" + cfg.defineChar + ")") : "OFF"));
                return true;
            }
            if (!arg1.isEmpty()) {
                String ch = stripQuotes(arg1);
                if (ch.length() != 1) {
                    err.println("Error: SET DEFINE ON|OFF|<char>");
                    return true;
                }
                cfg.defineOn = true;
                cfg.defineChar = ch.charAt(0);
                ack(cfg, out, quiet, "DEFINE \"" + cfg.defineChar + "\"");
                return true;
            }
            err.println("Error: SET DEFINE ON|OFF|<char>");
            return true;
        }
        if ("ESCAPE".equals(opt)) {
            Boolean on = parseOnOff(arg1);
            if (on != null) {
                cfg.escapeOn = on.booleanValue();
                ack(cfg, out, quiet, "ESCAPE " + (on.booleanValue() ? ("ON (" + cfg.escapeChar + ")") : "OFF"));
                return true;
            }
            if (!arg1.isEmpty()) {
                String ch = stripQuotes(arg1);
                if (ch.length() != 1) {
                    err.println("Error: SET ESCAPE ON|OFF|<char>");
                    return true;
                }
                cfg.escapeOn = true;
                cfg.escapeChar = ch.charAt(0);
                ack(cfg, out, quiet, "ESCAPE \"" + cfg.escapeChar + "\"");
                return true;
            }
            err.println("Error: SET ESCAPE ON|OFF|<char>");
            return true;
        }
        if ("LONG".equals(opt)) {
            return setInt(cfg, out, err, quiet, "LONG", arg1, 1, Integer.MAX_VALUE, new IntSink() {
                public void set(int v) { cfg.longSize = v; }
                public int get() { return cfg.longSize; }
            });
        }
        if ("LONGCHUNKSIZE".equals(opt) || "LONGC".equals(opt)) {
            return setInt(cfg, out, err, quiet, "LONGCHUNKSIZE", arg1, 1, Integer.MAX_VALUE, new IntSink() {
                public void set(int v) { cfg.longChunkSize = v; }
                public int get() { return cfg.longChunkSize; }
            });
        }
        if ("ARRAYSIZE".equals(opt) || "ARRAY".equals(opt)) {
            return setInt(cfg, out, err, quiet, "ARRAYSIZE", arg1, 1, 5000, new IntSink() {
                public void set(int v) { cfg.arraySize = v; }
                public int get() { return cfg.arraySize; }
            });
        }
        if ("TRIMOUT".equals(opt)) {
            return setBool(cfg, out, err, quiet, "TRIMOUT", arg1, new BoolSink() {
                public void set(boolean v) { cfg.trimOut = v; }
                public boolean get() { return cfg.trimOut; }
            });
        }
        if ("TRIMSPOOL".equals(opt)) {
            return setBool(cfg, out, err, quiet, "TRIMSPOOL", arg1, new BoolSink() {
                public void set(boolean v) { cfg.trimSpool = v; }
                public boolean get() { return cfg.trimSpool; }
            });
        }
        if ("COLSEP".equals(opt)) {
            String v = arg1;
            if (!arg2.isEmpty()) {
                v = arg1 + " " + arg2;
            }
            cfg.colSep = stripQuotes(v);
            ack(cfg, out, quiet, "COLSEP \"" + cfg.colSep + "\"");
            return true;
        }
        if ("UNDERLINE".equals(opt) || "UND".equals(opt)) {
            Boolean on = parseOnOff(arg1);
            if (on != null) {
                cfg.underline = on.booleanValue() ? "-" : "";
                ack(cfg, out, quiet, "UNDERLINE " + (on.booleanValue() ? "ON" : "OFF"));
                return true;
            }
            if (!arg1.isEmpty()) {
                String ch = stripQuotes(arg1);
                if (ch.isEmpty()) {
                    err.println("Error: SET UNDERLINE ON|OFF|<char>");
                    return true;
                }
                cfg.underline = String.valueOf(ch.charAt(0));
                ack(cfg, out, quiet, "UNDERLINE \"" + cfg.underline + "\"");
                return true;
            }
            err.println("Error: SET UNDERLINE ON|OFF|<char>");
            return true;
        }
        if ("WRAP".equals(opt)) {
            return setBool(cfg, out, err, quiet, "WRAP", arg1, new BoolSink() {
                public void set(boolean v) { cfg.wrapOn = v; }
                public boolean get() { return cfg.wrapOn; }
            });
        }
        if ("NUMWIDTH".equals(opt) || "NUM".equals(opt)) {
            return setInt(cfg, out, err, quiet, "NUMWIDTH", arg1, 1, 128, new IntSink() {
                public void set(int v) { cfg.numWidth = v; }
                public int get() { return cfg.numWidth; }
            });
        }
        if ("NUMFORMAT".equals(opt) || "NUMF".equals(opt)) {
            if (arg1.isEmpty()) {
                cfg.numFormat = null;
                ack(cfg, out, quiet, "NUMFORMAT \"\"");
                return true;
            }
            String v = arg1;
            if (!arg2.isEmpty()) {
                v = arg1 + " " + arg2;
            }
            cfg.numFormat = stripQuotes(v);
            ack(cfg, out, quiet, "NUMFORMAT \"" + cfg.numFormat + "\"");
            return true;
        }
        if ("NULL".equals(opt)) {
            String v = arg1;
            if (!arg2.isEmpty()) {
                v = arg1 + " " + arg2;
            }
            cfg.nullText = stripQuotes(v);
            ack(cfg, out, quiet, "NULL \"" + cfg.nullText + "\"");
            return true;
        }
        if ("TERMOUT".equals(opt) || "TERM".equals(opt)) {
            return setBool(cfg, out, err, quiet, "TERMOUT", arg1, new BoolSink() {
                public void set(boolean v) { cfg.termout = v; }
                public boolean get() { return cfg.termout; }
            });
        }
        if ("AUTOCOMMIT".equals(opt)) {
            Boolean on = parseOnOff(arg1);
            if (on == null) {
                err.println("Error: SET AUTOCOMMIT ON|OFF");
                return true;
            }
            try {
                session.connection().setAutoCommit(on.booleanValue());
                cfg.autoCommit = on.booleanValue();
                ack(cfg, out, quiet, "AUTOCOMMIT " + (on.booleanValue() ? "ON" : "OFF"));
            } catch (SQLException e) {
                err.println("Error: " + e.getMessage());
            }
            return true;
        }
        // 结果竖排 (类 MySQL \\G): SET VERTICAL ON|OFF | SET DISPLAY VERTICAL|TABLE
        if ("VERTICAL".equals(opt)) {
            Boolean on = parseOnOff(arg1);
            if (on == null) {
                err.println("Error: SET VERTICAL ON|OFF");
                return true;
            }
            cfg.displayVertical = on.booleanValue();
            ack(cfg, out, quiet, "VERTICAL " + (on.booleanValue() ? "ON" : "OFF")
                    + " (DISPLAY " + (on.booleanValue() ? "VERTICAL" : "TABLE") + ")");
            return true;
        }
        if ("DISPLAY".equals(opt)) {
            String mode = arg1.toUpperCase(Locale.ROOT);
            if ("VERTICAL".equals(mode) || "G".equals(mode) || "V".equals(mode)) {
                cfg.displayVertical = true;
                ack(cfg, out, quiet, "DISPLAY VERTICAL");
                return true;
            }
            if ("TABLE".equals(mode) || "TABULAR".equals(mode) || "HORIZONTAL".equals(mode)) {
                cfg.displayVertical = false;
                ack(cfg, out, quiet, "DISPLAY TABLE");
                return true;
            }
            err.println("Error: SET DISPLAY VERTICAL|TABLE");
            return true;
        }
        // &var → JDBC ? 绑定 (默认 OFF, 字面量替换)
        if ("BINDVAR".equals(opt) || "BINDVARS".equals(opt)) {
            return setBool(cfg, out, err, quiet, "BINDVAR", arg1, new BoolSink() {
                public void set(boolean v) { cfg.bindVar = v; }
                public boolean get() { return cfg.bindVar; }
            });
        }
        if ("HOST".equals(opt)) {
            return setBool(cfg, out, err, quiet, "HOST", arg1, new BoolSink() {
                public void set(boolean v) { cfg.hostEnabled = v; }
                public boolean get() { return cfg.hostEnabled; }
            });
        }

        err.println("unsupported SET " + rest);
        return true;
    }

    private static void ack(SessionConfig cfg, PrintStream out, boolean quiet, String msg) {
        if (quiet) {
            return;
        }
        cfg.println(out, msg);
    }

    public static void showAll(SessionConfig cfg, PrintStream out) {
        cfg.println(out, "echo " + onOff(cfg.echo));
        cfg.println(out, "feedback " + (cfg.feedback ? String.valueOf(cfg.feedbackMin) : "OFF"));
        cfg.println(out, "heading " + onOff(cfg.heading));
        cfg.println(out, "pagesize " + cfg.pagesize);
        cfg.println(out, "linesize " + cfg.linesize);
        cfg.println(out, "timing " + onOff(cfg.timing));
        cfg.println(out, "verify " + onOff(cfg.verify));
        cfg.println(out, "define " + (cfg.defineOn ? ("\"" + cfg.defineChar + "\"") : "OFF"));
        cfg.println(out, "escape " + (cfg.escapeOn ? ("\"" + cfg.escapeChar + "\"") : "OFF"));
        cfg.println(out, "null \"" + cfg.nullText + "\"");
        cfg.println(out, "termout " + onOff(cfg.termout));
        cfg.println(out, "autocommit " + onOff(cfg.autoCommit));
        cfg.println(out, "serveroutput " + onOff(cfg.serverOutput));
        cfg.println(out, "vertical " + onOff(cfg.displayVertical));
        cfg.println(out, "display " + (cfg.displayVertical ? "VERTICAL" : "TABLE"));
        cfg.println(out, "bindvar " + onOff(cfg.bindVar));
        cfg.println(out, "long " + cfg.longSize);
        cfg.println(out, "longchunksize " + cfg.longChunkSize);
        cfg.println(out, "arraysize " + cfg.arraySize);
        cfg.println(out, "trimout " + onOff(cfg.trimOut));
        cfg.println(out, "trimspool " + onOff(cfg.trimSpool));
        cfg.println(out, "colsep \"" + cfg.colSep + "\"");
        cfg.println(out, "underline \"" + cfg.underline + "\"");
        cfg.println(out, "wrap " + onOff(cfg.wrapOn));
        cfg.println(out, "numwidth " + cfg.numWidth);
        cfg.println(out, "numformat \"" + (cfg.numFormat == null ? "" : cfg.numFormat) + "\"");
        cfg.println(out, "host " + onOff(cfg.hostEnabled));
        cfg.println(out, "spool " + (cfg.spool != null ? "ON" : "OFF"));
    }

    public static boolean showOne(String name, SessionConfig cfg, PrintStream out, PrintStream err) {
        String n = name.toUpperCase(Locale.ROOT);
        if ("ALL".equals(n)) {
            showAll(cfg, out);
            return true;
        }
        if ("ECHO".equals(n)) {
            cfg.println(out, "echo " + onOff(cfg.echo));
            return true;
        }
        if ("FEEDBACK".equals(n) || "FEED".equals(n)) {
            cfg.println(out, "feedback " + (cfg.feedback ? String.valueOf(cfg.feedbackMin) : "OFF"));
            return true;
        }
        if ("HEADING".equals(n) || "HEA".equals(n)) {
            cfg.println(out, "heading " + onOff(cfg.heading));
            return true;
        }
        if ("PAGESIZE".equals(n) || "PAGES".equals(n)) {
            cfg.println(out, "pagesize " + cfg.pagesize);
            return true;
        }
        if ("LINESIZE".equals(n) || "LINES".equals(n)) {
            cfg.println(out, "linesize " + cfg.linesize);
            return true;
        }
        if ("TIMING".equals(n)) {
            cfg.println(out, "timing " + onOff(cfg.timing));
            return true;
        }
        if ("VERIFY".equals(n) || "VER".equals(n)) {
            cfg.println(out, "verify " + onOff(cfg.verify));
            return true;
        }
        if ("DEFINE".equals(n)) {
            cfg.println(out, "define " + (cfg.defineOn ? ("\"" + cfg.defineChar + "\"") : "OFF"));
            return true;
        }
        if ("ESCAPE".equals(n)) {
            cfg.println(out, "escape " + (cfg.escapeOn ? ("\"" + cfg.escapeChar + "\"") : "OFF"));
            return true;
        }
        if ("LONG".equals(n)) {
            cfg.println(out, "long " + cfg.longSize);
            return true;
        }
        if ("LONGCHUNKSIZE".equals(n) || "LONGC".equals(n)) {
            cfg.println(out, "longchunksize " + cfg.longChunkSize);
            return true;
        }
        if ("ARRAYSIZE".equals(n) || "ARRAY".equals(n)) {
            cfg.println(out, "arraysize " + cfg.arraySize);
            return true;
        }
        if ("TRIMOUT".equals(n)) {
            cfg.println(out, "trimout " + onOff(cfg.trimOut));
            return true;
        }
        if ("TRIMSPOOL".equals(n)) {
            cfg.println(out, "trimspool " + onOff(cfg.trimSpool));
            return true;
        }
        if ("COLSEP".equals(n)) {
            cfg.println(out, "colsep \"" + cfg.colSep + "\"");
            return true;
        }
        if ("UNDERLINE".equals(n) || "UND".equals(n)) {
            cfg.println(out, "underline \"" + cfg.underline + "\"");
            return true;
        }
        if ("WRAP".equals(n)) {
            cfg.println(out, "wrap " + onOff(cfg.wrapOn));
            return true;
        }
        if ("NUMWIDTH".equals(n) || "NUM".equals(n)) {
            cfg.println(out, "numwidth " + cfg.numWidth);
            return true;
        }
        if ("NUMFORMAT".equals(n) || "NUMF".equals(n)) {
            cfg.println(out, "numformat \"" + (cfg.numFormat == null ? "" : cfg.numFormat) + "\"");
            return true;
        }
        if ("HOST".equals(n)) {
            cfg.println(out, "host " + onOff(cfg.hostEnabled));
            return true;
        }
        if ("NULL".equals(n)) {
            cfg.println(out, "null \"" + cfg.nullText + "\"");
            return true;
        }
        if ("TERMOUT".equals(n) || "TERM".equals(n)) {
            cfg.println(out, "termout " + onOff(cfg.termout));
            return true;
        }
        if ("AUTOCOMMIT".equals(n)) {
            cfg.println(out, "autocommit " + onOff(cfg.autoCommit));
            return true;
        }
        if ("SERVEROUTPUT".equals(n)) {
            cfg.println(out, "serveroutput " + onOff(cfg.serverOutput));
            return true;
        }
        if ("VERTICAL".equals(n) || "DISPLAY".equals(n)) {
            cfg.println(out, "vertical " + onOff(cfg.displayVertical));
            cfg.println(out, "display " + (cfg.displayVertical ? "VERTICAL" : "TABLE"));
            return true;
        }
        if ("SPOOL".equals(n)) {
            cfg.println(out, "spool " + (cfg.spool != null ? "ON" : "OFF"));
            return true;
        }
        if ("BINDVAR".equals(n) || "BINDVARS".equals(n)) {
            cfg.println(out, "bindvar " + onOff(cfg.bindVar));
            return true;
        }
        err.println("unsupported SHOW " + name);
        return true;
    }

    private interface BoolSink {
        void set(boolean v);

        boolean get();
    }

    private interface IntSink {
        void set(int v);

        int get();
    }

    private static boolean setBool(SessionConfig cfg, PrintStream out, PrintStream err,
                                   boolean quiet, String name, String arg, BoolSink sink) {
        Boolean on = parseOnOff(arg);
        if (on == null) {
            err.println("Error: SET " + name + " ON|OFF");
            return true;
        }
        sink.set(on.booleanValue());
        ack(cfg, out, quiet, name + " " + (on.booleanValue() ? "ON" : "OFF"));
        return true;
    }

    private static boolean setInt(SessionConfig cfg, PrintStream out, PrintStream err,
                                  boolean quiet, String name, String arg, int min, int max,
                                  IntSink sink) {
        try {
            int n = Integer.parseInt(arg.trim());
            if (n < min || n > max) {
                err.println("Error: SET " + name + " out of range");
                return true;
            }
            sink.set(n);
            ack(cfg, out, quiet, name + " " + n);
        } catch (Exception e) {
            err.println("Error: SET " + name + " <n>");
        }
        return true;
    }

    private static void enableDbmsOutput(JdbcSession session, PrintStream err) {
        Statement st = null;
        try {
            st = session.connection().createStatement();
            st.execute("BEGIN DBMS_OUTPUT.ENABLE(1000000); END;");
        } catch (SQLException e) {
            err.println("WARN: DBMS_OUTPUT.ENABLE failed: " + e.getMessage());
        } finally {
            if (st != null) {
                try {
                    st.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
        }
    }

    private static Boolean parseOnOff(String s) {
        if (s == null) {
            return null;
        }
        String u = s.trim().toUpperCase(Locale.ROOT);
        if ("ON".equals(u) || "TRUE".equals(u)) {
            return Boolean.TRUE;
        }
        if ("OFF".equals(u) || "FALSE".equals(u)) {
            return Boolean.FALSE;
        }
        return null;
    }

    private static String onOff(boolean v) {
        return v ? "ON" : "OFF";
    }

    private static String stripQuotes(String s) {
        if (s == null) {
            return "";
        }
        s = s.trim();
        if (s.length() >= 2) {
            char a = s.charAt(0);
            char b = s.charAt(s.length() - 1);
            if ((a == '\'' && b == '\'') || (a == '"' && b == '"')) {
                return s.substring(1, s.length() - 1);
            }
        }
        return s;
    }
}
