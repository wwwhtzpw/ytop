package com.yashan.yjdbc.cmd.sqlmap.support.log;

import com.yashan.yjdbc.cmd.sqlmap.support.Version;

import java.io.PrintStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * 会话输出日志 (默认不落盘; 对齐 DualLogger 常用方法).
 */
public final class DualLogger implements AutoCloseable {
    private static final int LEVEL_WIDTH = 5;

    private final PrintStream out;
    private final PrintStream err;
    private final boolean debugEnabled;
    private final SimpleDateFormat tsFmt =
            new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US);

    public DualLogger(PrintStream out, PrintStream err, boolean debugEnabled) {
        this.out = out == null ? System.out : out;
        this.err = err == null ? System.err : err;
        this.debugEnabled = debugEnabled;
    }

    public boolean isDebugEnabled() {
        return debugEnabled;
    }

    public void logInfo(String msg) {
        write("INFO", msg, false);
    }

    public void logWarn(String msg) {
        write("WARN", msg, false);
    }

    public void logError(String msg) {
        write("ERROR", msg, true);
    }

    public void logDbg(String msg) {
        if (!debugEnabled) {
            return;
        }
        write("DEBUG", msg, false);
    }

    public void logStep(String step, String detail) {
        if (!debugEnabled) {
            return;
        }
        if (detail == null || detail.isEmpty()) {
            logDbg("=== [STEP] " + step + " ===");
        } else {
            logDbg("=== [STEP] " + step + ": " + detail + " ===");
        }
    }

    public void commandResult(String scope, String cmd, int rc, String output, double durationSec) {
        logDbg("command_result scope=" + scope + " rc=" + rc
                + " duration_sec=" + String.format(Locale.US, "%.3f", durationSec)
                + " cmd=" + (cmd == null ? "" : cmd));
    }

    public void logReplayLine(String line) {
        if (line != null) {
            logInfo(line);
        }
    }

    private void write(String level, String msg, boolean toStderr) {
        String ts = tsFmt.format(new Date());
        String padded = String.format(Locale.US, "%-" + LEVEL_WIDTH + "s", level);
        String ln = ts + "  " + padded + "  " + msg;
        (toStderr ? err : out).println(ln);
    }

    @Override
    public void close() {
        // no files
    }

    public static void printBanner(PrintStream out) {
        out.println("sqlmap via yjdbc (" + Version.VERSION + ")");
    }
}
