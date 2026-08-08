package com.yashan.yjdbc.shell;

import com.yashan.yjdbc.config.SessionConfig;
import com.yashan.yjdbc.db.JdbcSession;
import com.yashan.yjdbc.exec.SqlExecutor;

import java.io.BufferedReader;
import java.io.File;
import java.io.PrintStream;

/**
 * 交互 REPL: 提示符 YJDBC>, 以 ; 或 \\G 或单独一行 / 执行.
 * tty 下经 JLine 行编辑 + 会话历史; -f/batch/非交互回退普通读入.
 */
public final class Repl {
    private final JdbcSession session;
    private final PrintStream out;
    private final PrintStream err;

    public Repl(JdbcSession session, PrintStream out, PrintStream err) {
        this.session = session;
        this.out = out;
        this.err = err;
    }

    public int run() {
        SqlExecutor executor = new SqlExecutor(session, out, err);
        executor.attachAsInterruptTarget();
        SqlExecutor.installInterruptHandler(err);
        ClientCommands client = new ClientCommands(session, executor, out, err);

        String script = session.config().scriptPath;
        boolean scripted = script != null && !script.trim().isEmpty();
        // batch 或 --script: 不用 JLine; 否则尝试 (console 可为 null 仍试一次)
        boolean wantJLine = !scripted && !session.config().batch;
        if (wantJLine && System.console() == null) {
            // 包装启动时常 console==null; 仍尝试, 失败由 LineSource.open 回退
            wantJLine = true;
        }

        LineSource.SessionHistory hist = new LineSource.SessionHistory();
        LineSource lineSource = LineSource.open(wantJLine, hist, err);
        BufferedReader secondary = LineSource.asSecondaryBufferedReader(lineSource);
        client.setPromptIn(secondary);

        try {
            if (scripted) {
                client.runScriptFile(new File(script.trim()), 0);
                return client.exitCodeOrZero();
            }

            StringBuilder buf = new StringBuilder();
            while (true) {
                if (client.isStopRequested()) {
                    break;
                }
                String prompt = buf.length() == 0 ? "YJDBC> " : "     > ";
                String line;
                try {
                    line = lineSource.readLine(prompt);
                } catch (LineSource.LineInterruptedException interrupted) {
                    // 提示符 Ctrl+C: 丢弃未提交缓冲, 回到 YJDBC>
                    buf.setLength(0);
                    continue;
                }
                if (line == null) {
                    out.println();
                    break;
                }
                String trimmed = line.trim();
                if ("/".equals(trimmed)) {
                    if (buf.length() == 0) {
                        client.tryHandle("RUN", null, 0);
                        recordRunOrRemembered(hist, lineSource, client);
                    } else {
                        String raw = buf.toString();
                        buf.setLength(0);
                        flushRaw(raw, client, executor, secondary);
                        record(hist, lineSource, LineSource.SessionHistory.stripSqlTerminator(raw));
                    }
                    continue;
                }
                if (buf.length() == 0) {
                    String cand = SqlExecutor.parseStmt(trimmed).sql;
                    if (!cand.isEmpty() && client.tryHandle(cand, null, 0)) {
                        if (client.isStopRequested()) {
                            break;
                        }
                        recordClientOrRun(hist, lineSource, client, trimmed);
                        continue;
                    }
                }
                if (buf.length() > 0) {
                    buf.append('\n');
                }
                buf.append(line);
                String bt = buf.toString().trim();
                if (SqlExecutor.looksLikePlsql(bt)) {
                    continue;
                }
                if (SqlExecutor.endsWithVerticalTerminator(bt) || bt.endsWith(";")) {
                    String raw = buf.toString();
                    buf.setLength(0);
                    SqlExecutor.StmtSpec spec = SqlExecutor.parseStmt(raw);
                    dispatch(spec, client, executor, secondary);
                    record(hist, lineSource, LineSource.SessionHistory.stripSqlTerminator(raw));
                }
            }
            return client.exitCodeOrZero();
        } catch (Exception e) {
            err.println("REPL error: " + e.getMessage());
            return 1;
        } finally {
            client.closeSpool();
            lineSource.close();
        }
    }

    private static void record(LineSource.SessionHistory hist, LineSource ls, String text) {
        hist.add(text);
        ls.syncHistory(hist);
    }

    /** 客户端命令: RUN 记 rememberSql; 其它记原文 trim. */
    private static void recordClientOrRun(LineSource.SessionHistory hist, LineSource ls,
                                          ClientCommands client, String trimmedLine) {
        if (isRunCommand(trimmedLine)) {
            recordRunOrRemembered(hist, ls, client);
            return;
        }
        record(hist, ls, trimmedLine);
    }

    private static void recordRunOrRemembered(LineSource.SessionHistory hist, LineSource ls,
                                              ClientCommands client) {
        String sql = client.peekRememberedSql();
        if (sql != null && !sql.trim().isEmpty()) {
            record(hist, ls, sql.trim());
        }
    }

    private static boolean isRunCommand(String trimmed) {
        if (trimmed == null) {
            return false;
        }
        String u = trimmed.trim();
        if (u.isEmpty()) {
            return false;
        }
        if ("/".equals(u)) {
            return true;
        }
        // RUN or R (buffer run)
        return u.equalsIgnoreCase("RUN") || u.equalsIgnoreCase("R");
    }

    private void flushRaw(String raw, ClientCommands client, SqlExecutor executor,
                          BufferedReader secondary) {
        if (raw == null || raw.trim().isEmpty()) {
            return;
        }
        dispatch(SqlExecutor.parseStmt(raw), client, executor, secondary);
    }

    private void dispatch(SqlExecutor.StmtSpec spec, ClientCommands client, SqlExecutor executor,
                          BufferedReader secondary) {
        if (spec == null || spec.sql == null || spec.sql.isEmpty() || client.isStopRequested()) {
            return;
        }
        if (client.tryHandle(spec.sql, null, 0)) {
            return;
        }
        SessionConfig.ExpandResult expanded =
                session.config().expandForExec(spec.sql, secondary, out, err);
        if (expanded == null) {
            return;
        }
        boolean ok = executor.execute(expanded.sql, expanded.binds, spec.verticalOnce);
        if (!ok) {
            if (!executor.consumeCancelFailure()) {
                client.onSqlError();
            }
        } else {
            client.rememberSql(expanded.sql);
        }
    }
}
