package com.yashan.yjdbc.shell;

import com.yashan.yjdbc.config.SessionConfig;
import com.yashan.yjdbc.db.JdbcSession;
import com.yashan.yjdbc.exec.SqlExecutor;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.sql.DatabaseMetaData;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 客户端命令: @/@@/START / ? (peek) / # (edit-temp-run) / DESC / COL / DEFINE / ACCEPT /
 * SET / SHOW / PROMPT / SPOOL / CLEAR / EXEC / WHENEVER / EXIT.
 */
public final class ClientCommands {
    private static final int MAX_NEST = 32;
    private static final Pattern DESC = Pattern.compile(
            "(?i)^\\s*DESC(?:RIBE)?\\s+([\\w.$#\"]+)\\s*;?\\s*$");
    private static final Pattern SET_ANY = Pattern.compile(
            "(?i)^\\s*SET\\s+(.+)$");
    private static final Pattern SHOW = Pattern.compile(
            "(?i)^\\s*SHO(?:W)?\\s+(\\S+)\\s*;?\\s*$");
    /** group1=@@ 标记; group2=路径; group3=可选参数串. */
    private static final Pattern AT = Pattern.compile(
            "(?i)^\\s*(?:@(@?)|STA(?:RT)?)\\s*(\\S+)(?:\\s+(.*))?\\s*$");
    /** ?path [args] — 查看脚本 (不执行). group1=路径; group2=可选参数(忽略). */
    private static final Pattern PEEK = Pattern.compile(
            "^\\s*\\?\\s*(\\S+)(?:\\s+(.*))?\\s*$");
    /** #path [args] — 编辑临时副本, 有变更则按 @ 执行. */
    private static final Pattern EDIT_RUN = Pattern.compile(
            "^\\s*#\\s*(\\S+)(?:\\s+(.*))?\\s*$");
    private static final Pattern COL_CLEAR = Pattern.compile(
            "(?i)^\\s*COL(?:UMN)?\\s+([\\w.$#\"]+)\\s+CLEAR\\s*;?\\s*$");
    private static final Pattern COL_LIST = Pattern.compile(
            "(?i)^\\s*COL(?:UMN)?\\s*;?\\s*$");
    /** COLUMN name [clauses...]; 或 COLUMN name (查看). */
    private static final Pattern COL_ANY = Pattern.compile(
            "(?i)^\\s*COL(?:UMN)?\\s+([\\w.$#\"]+)(?:\\s+(.+))?\\s*;?\\s*$");
    private static final Pattern DEFINE = Pattern.compile(
            "(?i)^\\s*DEF(?:INE)?\\s+([A-Za-z][A-Za-z0-9_$#]*|[0-9]+)\\s*(?:=\\s*|\\s+)(.*?)\\s*;?\\s*$");
    private static final Pattern DEFINE_LIST = Pattern.compile(
            "(?i)^\\s*DEF(?:INE)?\\s*;?\\s*$");
    private static final Pattern UNDEFINE = Pattern.compile(
            "(?i)^\\s*UNDEF(?:INE)?\\s+(.+?)\\s*;?\\s*$");
    private static final Pattern ACCEPT = Pattern.compile(
            "(?i)^\\s*ACC(?:EPT)?\\s+([A-Za-z][A-Za-z0-9_$#]*|[0-9]+)(.*)$");
    private static final Pattern PROMPT = Pattern.compile(
            "(?i)^\\s*PRO(?:MPT)?(?:\\s+(.*))?$");
    private static final Pattern REM = Pattern.compile(
            "(?i)^\\s*REM(?:ARK)?(?:\\s.*)?$");
    private static final Pattern SPOOL = Pattern.compile(
            "(?i)^\\s*SPO(?:OL)?\\s+(\\S+)(?:\\s+(CRE(?:ATE)?|REP(?:LACE)?|APP(?:END)?))?\\s*;?\\s*$");
    private static final Pattern CLEAR = Pattern.compile(
            "(?i)^\\s*CLE(?:AR)?\\s+(\\S+)\\s*;?\\s*$");
    private static final Pattern EXEC = Pattern.compile(
            "(?i)^\\s*EXEC(?:UTE)?\\s+(.+)$");
    private static final Pattern WHENEVER = Pattern.compile(
            "(?i)^\\s*WHENEVER\\s+(SQLERROR|OSERROR)\\s+(EXIT|CONTINUE)(?:\\s+(.+))?\\s*;?\\s*$");
    private static final Pattern EXIT_CMD = Pattern.compile(
            "(?i)^\\s*(?:EXIT|QUIT)(?:\\s+(.+))?\\s*;?\\s*$");
    private static final Pattern VARIABLE = Pattern.compile(
            "(?i)^\\s*VAR(?:IABLE)?(?:\\s+([A-Za-z][A-Za-z0-9_$#]*)"
                    + "(?:\\s+(.+))?)?\\s*;?\\s*$");
    private static final Pattern PRINT = Pattern.compile(
            "(?i)^\\s*PRI(?:NT)?(?:\\s+(.+))?\\s*;?\\s*$");
    /** EXEC :name := 字面量 — 客户端赋值 (避免 Yashan OUT bind 限制). */
    private static final Pattern EXEC_ASSIGN = Pattern.compile(
            "(?i)^:?([A-Za-z][A-Za-z0-9_$#]*)\\s*:=\\s*(.+)$");
    private static final Pattern TTITLE = Pattern.compile(
            "(?i)^\\s*TTI(?:TLE)?(?:\\s+(.*))?\\s*;?\\s*$");
    private static final Pattern BTITLE = Pattern.compile(
            "(?i)^\\s*BTI(?:TLE)?(?:\\s+(.*))?\\s*;?\\s*$");
    private static final Pattern BREAK = Pattern.compile(
            "(?i)^\\s*BRE(?:AK)?(?:\\s+(.*))?\\s*;?\\s*$");
    private static final Pattern COMPUTE = Pattern.compile(
            "(?i)^\\s*COMP(?:UTE)?(?:\\s+(.*))?\\s*;?\\s*$");
    private static final Pattern PAUSE = Pattern.compile(
            "(?i)^\\s*PAU(?:SE)?(?:\\s+(.*))?\\s*;?\\s*$");
    private static final Pattern HOST = Pattern.compile(
            "(?i)^\\s*(?:HO(?:ST)?|!)\\s*(.*)$");
    private static final Pattern CONNECT = Pattern.compile(
            "(?i)^\\s*CONN(?:ECT)?(?:\\s+(.*))?\\s*;?\\s*$");
    private static final Pattern DISCONNECT = Pattern.compile(
            "(?i)^\\s*DISC(?:ONNECT)?\\s*;?\\s*$");
    private static final Pattern BUF_LIST = Pattern.compile(
            "(?i)^\\s*L(?:IST)?(?:\\s+(\\*|\\d+(?:\\s+\\d+)?))?\\s*;?\\s*$");
    private static final Pattern BUF_RUN = Pattern.compile(
            "(?i)^\\s*R(?:UN)?\\s*;?\\s*$");
    private static final Pattern BUF_DEL = Pattern.compile(
            "(?i)^\\s*DEL(?:ETE)?(?:\\s+(\\*|\\d+(?:\\s+\\d+)?))?\\s*;?\\s*$");
    private static final Pattern BUF_APPEND = Pattern.compile(
            "(?i)^\\s*A(?:PPEND)?\\s+(.*)$");
    private static final Pattern BUF_CHANGE = Pattern.compile(
            "(?i)^\\s*C(?:HANGE)?\\s+/([^/]*)/(.*)$");
    private static final Pattern BUF_GET = Pattern.compile(
            "(?i)^\\s*GET\\s+(\\S+)\\s*;?\\s*$");
    private static final Pattern BUF_SAVE = Pattern.compile(
            "(?i)^\\s*SAVE\\s+(\\S+)\\s*;?\\s*$");
    private static final Pattern BUF_INPUT = Pattern.compile(
            "(?i)^\\s*I(?:NPUT)?(?:\\s+(.*))?$");

    private final JdbcSession session;
    private final SqlExecutor executor;
    private final PrintStream out;
    private final PrintStream err;
    private BufferedReader promptIn;
    /** 非 null 时请求结束 REPL/脚本, 值为进程退出码. */
    private Integer pendingExitCode;

    public ClientCommands(JdbcSession session, SqlExecutor executor,
                          PrintStream out, PrintStream err) {
        this.session = session;
        this.executor = executor;
        this.out = out;
        this.err = err;
    }

    public void setPromptIn(BufferedReader promptIn) {
        this.promptIn = promptIn;
    }

    /** 是否因 WHENEVER/EXIT 请求停止. */
    public boolean isStopRequested() {
        return pendingExitCode != null;
    }

    /** 进程退出码; 未请求退出时为 0. */
    public int exitCodeOrZero() {
        return pendingExitCode == null ? 0 : pendingExitCode.intValue();
    }

    /**
     * 若为客户端命令则处理并返回 true; 否则返回 false 交由 SQL 执行.
     */
    public boolean tryHandle(String statement, File scriptDir, int depth) {
        if (statement == null) {
            return false;
        }
        String s = statement.trim();
        if (s.isEmpty()) {
            return true;
        }
        // 脚本 / 批处理: SET/COL/DEFINE/SPOOL 等配置命令静默 (PROMPT/SHOW/DESC 仍输出)
        boolean quiet = depth > 0 || session.config().batch || scriptDir != null;

        if (REM.matcher(s).matches()) {
            return true;
        }
        Matcher whenever = WHENEVER.matcher(s);
        if (whenever.matches()) {
            handleWhenever(whenever.group(1), whenever.group(2), whenever.group(3), quiet);
            return true;
        }
        Matcher exitCmd = EXIT_CMD.matcher(s);
        if (exitCmd.matches()) {
            handleExit(exitCmd.group(1));
            return true;
        }
        Matcher variable = VARIABLE.matcher(s);
        if (variable.matches()) {
            handleVariable(variable.group(1), variable.group(2), quiet);
            return true;
        }
        Matcher print = PRINT.matcher(s);
        if (print.matches()) {
            handlePrint(print.group(1));
            return true;
        }
        Matcher ttitle = TTITLE.matcher(s);
        if (ttitle.matches()) {
            handleTitle(true, ttitle.group(1), quiet);
            return true;
        }
        Matcher btitle = BTITLE.matcher(s);
        if (btitle.matches()) {
            handleTitle(false, btitle.group(1), quiet);
            return true;
        }
        Matcher brk = BREAK.matcher(s);
        if (brk.matches()) {
            handleBreak(brk.group(1), quiet);
            return true;
        }
        Matcher comp = COMPUTE.matcher(s);
        if (comp.matches()) {
            handleCompute(comp.group(1), quiet);
            return true;
        }
        Matcher pause = PAUSE.matcher(s);
        if (pause.matches()) {
            handlePause(pause.group(1));
            return true;
        }
        Matcher host = HOST.matcher(s);
        if (host.matches()) {
            handleHost(host.group(1));
            return true;
        }
        Matcher conn = CONNECT.matcher(s);
        if (conn.matches()) {
            handleConnect(conn.group(1));
            return true;
        }
        if (DISCONNECT.matcher(s).matches()) {
            handleDisconnect();
            return true;
        }
        if (handleBufferCmd(s)) {
            return true;
        }
        Matcher prompt = PROMPT.matcher(s);
        if (prompt.matches()) {
            String msg = prompt.group(1);
            if (msg == null) {
                msg = "";
            }
            // sqlplus: PROMPT 内 &var 亦替换
            String expanded = session.config().substitute(msg, promptIn, out, err);
            if (expanded != null) {
                msg = expanded;
            }
            session.config().println(out, msg);
            return true;
        }

        Matcher peek = PEEK.matcher(s);
        if (peek.matches()) {
            peekScript(peek.group(1), false, scriptDir);
            return true;
        }
        Matcher editRun = EDIT_RUN.matcher(s);
        if (editRun.matches()) {
            String[] scriptArgs = parseScriptArgs(editRun.group(2));
            editAndMaybeRun(editRun.group(1), scriptArgs, false, scriptDir, depth);
            return true;
        }

        Matcher at = AT.matcher(s);
        if (at.matches()) {
            // group1: "@" for @@, null for @ or START
            boolean relativeToScript = "@".equals(at.group(1));
            String path = at.group(2);
            String[] scriptArgs = parseScriptArgs(at.group(3));
            runScript(path, relativeToScript, scriptDir, depth, scriptArgs);
            return true;
        }

        Matcher exec = EXEC.matcher(s);
        if (exec.matches()) {
            String body = exec.group(1).trim();
            if (body.endsWith(";")) {
                body = body.substring(0, body.length() - 1).trim();
            }
            if (tryExecAssign(body)) {
                return true;
            }
            // EXEC proc → BEGIN proc; END;  简化: 原样当 SQL/匿名块
            if (!body.toUpperCase(Locale.ROOT).startsWith("BEGIN")
                    && !body.toUpperCase(Locale.ROOT).startsWith("DECLARE")
                    && !body.toUpperCase(Locale.ROOT).startsWith("CALL")) {
                body = "BEGIN " + body + "; END;";
            }
            dispatchSql(body);
            return true;
        }

        Matcher spool = SPOOL.matcher(s);
        if (spool.matches()) {
            handleSpool(spool.group(1), spool.group(2), quiet);
            return true;
        }
        Matcher clear = CLEAR.matcher(s);
        if (clear.matches()) {
            handleClear(clear.group(1), quiet);
            return true;
        }
        Matcher show = SHOW.matcher(s);
        if (show.matches()) {
            String what = show.group(1);
            if ("WHENEVER".equalsIgnoreCase(what)) {
                showWhenever();
                return true;
            }
            if ("USER".equalsIgnoreCase(what)) {
                session.config().println(out, "USER is \"" + session.config().user + "\"");
                return true;
            }
            SqlPlusSet.showOne(what, session.config(), out, err);
            return true;
        }

        Matcher desc = DESC.matcher(s);
        if (desc.matches()) {
            describe(desc.group(1));
            return true;
        }

        if (COL_LIST.matcher(s).matches()) {
            listColFormats();
            return true;
        }
        Matcher colClear = COL_CLEAR.matcher(s);
        if (colClear.matches()) {
            String name = colClear.group(1).replace("\"", "");
            session.config().clearColWidth(name);
            return true;
        }
        Matcher colAny = COL_ANY.matcher(s);
        if (colAny.matches()) {
            handleColumn(colAny.group(1).replace("\"", ""), colAny.group(2));
            return true;
        }

        if (DEFINE_LIST.matcher(s).matches()) {
            listDefines();
            return true;
        }
        Matcher def = DEFINE.matcher(s);
        if (def.matches()) {
            String name = def.group(1);
            String val = stripQuotes(def.group(2).trim());
            session.config().define(name, val);
            if (!quiet) {
                out.println("DEFINE " + name.toUpperCase(Locale.ROOT) + " = \"" + val + "\"");
            }
            return true;
        }
        Matcher undef = UNDEFINE.matcher(s);
        if (undef.matches()) {
            String[] names = undef.group(1).trim().split("\\s+");
            for (String n : names) {
                session.config().undefine(n);
            }
            return true;
        }
        Matcher acc = ACCEPT.matcher(s);
        if (acc.matches()) {
            acceptVar(acc.group(1), acc.group(2));
            return true;
        }

        Matcher set = SET_ANY.matcher(s);
        if (set.matches()) {
            return SqlPlusSet.handleSet(set.group(1), session, out, err, quiet);
        }

        return false;
    }

    private void handleSpool(String target, String modeTok, boolean quiet) {
        SessionConfig cfg = session.config();
        if ("OFF".equalsIgnoreCase(target)) {
            if (cfg.spool != null) {
                cfg.spool.close();
                cfg.spool = null;
            }
            if (!quiet) {
                cfg.println(out, "SPOOL OFF");
            }
            return;
        }
        // 默认 REPLACE (对齐 sqlplus; 旧版 yjdbc 恒 APPEND, 见手册)
        String mode = "REPLACE";
        if (modeTok != null && !modeTok.isEmpty()) {
            String u = modeTok.toUpperCase(Locale.ROOT);
            if (u.startsWith("CRE")) {
                mode = "CREATE";
            } else if (u.startsWith("APP")) {
                mode = "APPEND";
            } else {
                mode = "REPLACE";
            }
        }
        try {
            if (cfg.spool != null) {
                cfg.spool.close();
                cfg.spool = null;
            }
            File f = new File(target);
            if ("CREATE".equals(mode) && f.exists()) {
                err.println("Error: SPOOL CREATE file exists: " + f.getPath());
                onOsError();
                return;
            }
            boolean append = "APPEND".equals(mode);
            cfg.spool = new PrintStream(new FileOutputStream(f, append), true, "UTF-8");
            if (!quiet) {
                cfg.println(out, "SPOOL " + f.getPath() + " " + mode);
            }
        } catch (IOException e) {
            err.println("Error: SPOOL failed: " + e.getMessage());
            onOsError();
        }
    }

    private void handleClear(String what, boolean quiet) {
        String w = what.toUpperCase(Locale.ROOT);
        if ("COL".equals(w) || "COLUMNS".equals(w) || "COLUMN".equals(w)) {
            session.config().clearAllColumns();
            if (!quiet) {
                session.config().println(out, "columns cleared");
            }
            return;
        }
        if ("BRE".equals(w) || "BREAK".equals(w) || "BREAKS".equals(w)) {
            session.config().breaks.clear();
            if (!quiet) {
                session.config().println(out, "breaks cleared");
            }
            return;
        }
        if ("COMP".equals(w) || "COMPUTE".equals(w) || "COMPUTES".equals(w)) {
            session.config().computes.clear();
            if (!quiet) {
                session.config().println(out, "computes cleared");
            }
            return;
        }
        if ("BUF".equals(w) || "BUFFER".equals(w)) {
            session.config().sqlBuffer = "";
            if (!quiet) {
                session.config().println(out, "buffer cleared");
            }
            return;
        }
        if ("SCR".equals(w) || "SCREEN".equals(w)) {
            for (int i = 0; i < 50; i++) {
                session.config().println(out, "");
            }
            return;
        }
        err.println("unsupported CLEAR " + what);
    }

    private void dispatchSql(String stmt) {
        if (isStopRequested()) {
            return;
        }
        SqlExecutor.StmtSpec spec = SqlExecutor.parseStmt(stmt);
        SessionConfig.ExpandResult expanded =
                session.config().expandForExec(spec.sql, promptIn, out, err);
        if (expanded == null) {
            return;
        }
        boolean ok = executor.execute(expanded.sql, expanded.binds, spec.verticalOnce);
        if (!ok) {
            if (!executor.consumeCancelFailure()) {
                onSqlError();
            }
        } else {
            rememberSql(expanded.sql);
        }
    }

    /** SQL 失败后按 WHENEVER SQLERROR 处理. */
    public void onSqlError() {
        applyWhenever(session.config().wheneverSqlError, "SQLERROR");
    }

    /** OS/客户端失败后按 WHENEVER OSERROR 处理. */
    public void onOsError() {
        applyWhenever(session.config().wheneverOsError, "OSERROR");
    }

    private void applyWhenever(SessionConfig.WheneverPolicy policy, String kind) {
        if (policy == null) {
            return;
        }
        applyTxn(policy.txn);
        if (policy.exit) {
            int code = session.config().resolveExitStatus(policy.status);
            pendingExitCode = Integer.valueOf(code);
            err.println("WHENEVER " + kind + " EXIT " + policy.status
                    + " (exit code " + code + ")");
        }
    }

    private void applyTxn(String txn) {
        if (txn == null) {
            return;
        }
        String t = txn.trim().toUpperCase(Locale.ROOT);
        try {
            if ("COMMIT".equals(t)) {
                session.connection().commit();
            } else if ("ROLLBACK".equals(t)) {
                session.connection().rollback();
            }
        } catch (SQLException e) {
            err.println("Error: " + t + " failed: " + e.getMessage());
        }
    }

    private void handleWhenever(String kind, String action, String rest, boolean quiet) {
        SessionConfig.WheneverPolicy parsed = parseWheneverTail(action, rest);
        if (parsed == null) {
            err.println("Error: WHENEVER " + kind + " EXIT|CONTINUE "
                    + "[SUCCESS|FAILURE|WARNING|SQL.SQLCODE|n] [COMMIT|ROLLBACK|NONE]");
            return;
        }
        if ("OSERROR".equalsIgnoreCase(kind)) {
            session.config().wheneverOsError.copyFrom(parsed);
        } else {
            session.config().wheneverSqlError.copyFrom(parsed);
        }
        if (!quiet) {
            session.config().println(out, formatWhenever(kind.toUpperCase(Locale.ROOT), parsed));
        }
    }

    /**
     * 解析 EXIT/CONTINUE 后半段.
     * EXIT 默认 status=FAILURE、txn=COMMIT; CONTINUE 默认 txn=NONE.
     */
    private SessionConfig.WheneverPolicy parseWheneverTail(String action, String rest) {
        SessionConfig.WheneverPolicy p = new SessionConfig.WheneverPolicy();
        String act = action == null ? "" : action.trim().toUpperCase(Locale.ROOT);
        if ("EXIT".equals(act)) {
            p.exit = true;
            p.status = "FAILURE";
            p.txn = "COMMIT";
        } else if ("CONTINUE".equals(act)) {
            p.exit = false;
            p.status = "FAILURE";
            p.txn = "NONE";
        } else {
            return null;
        }
        if (rest == null || rest.trim().isEmpty()) {
            return p;
        }
        String[] toks = rest.trim().split("\\s+");
        for (String tok : toks) {
            String u = tok.toUpperCase(Locale.ROOT);
            if ("COMMIT".equals(u) || "ROLLBACK".equals(u) || "NONE".equals(u)) {
                p.txn = u;
                continue;
            }
            if ("SUCCESS".equals(u) || "FAILURE".equals(u) || "WARNING".equals(u)
                    || "SQL.SQLCODE".equals(u) || "SQLCODE".equals(u)) {
                p.status = u;
                continue;
            }
            try {
                Integer.parseInt(u);
                p.status = u;
            } catch (NumberFormatException e) {
                return null;
            }
        }
        return p;
    }

    private void handleExit(String rest) {
        // 裸 EXIT/QUIT: 退出码 0, 不自动提交 (保持 yjdbc 安全默认)
        String status = "SUCCESS";
        String txn = "NONE";
        if (rest != null && !rest.trim().isEmpty()) {
            // 有参数时对齐 sqlplus: 未写 COMMIT/ROLLBACK 则默认 COMMIT
            status = "SUCCESS";
            txn = "COMMIT";
            String[] toks = rest.trim().split("\\s+");
            boolean sawStatus = false;
            for (String tok : toks) {
                String u = tok.toUpperCase(Locale.ROOT);
                if ("COMMIT".equals(u) || "ROLLBACK".equals(u) || "NONE".equals(u)) {
                    txn = u;
                    continue;
                }
                if ("SUCCESS".equals(u) || "FAILURE".equals(u) || "WARNING".equals(u)
                        || "SQL.SQLCODE".equals(u) || "SQLCODE".equals(u)) {
                    status = u;
                    sawStatus = true;
                    continue;
                }
                try {
                    Integer.parseInt(u);
                    status = u;
                    sawStatus = true;
                } catch (NumberFormatException e) {
                    err.println("Error: EXIT [SUCCESS|FAILURE|WARNING|SQL.SQLCODE|n] "
                            + "[COMMIT|ROLLBACK|NONE]");
                    return;
                }
            }
            if (!sawStatus && ("COMMIT".equals(txn) || "ROLLBACK".equals(txn) || "NONE".equals(txn))) {
                status = "SUCCESS";
            }
        }
        applyTxn(txn);
        pendingExitCode = Integer.valueOf(session.config().resolveExitStatus(status));
    }

    private void showWhenever() {
        SessionConfig cfg = session.config();
        cfg.println(out, formatWhenever("SQLERROR", cfg.wheneverSqlError));
        cfg.println(out, formatWhenever("OSERROR", cfg.wheneverOsError));
    }

    private void handleVariable(String name, String typeSpec, boolean quiet) {
        SessionConfig cfg = session.config();
        if (name == null || name.isEmpty()) {
            if (cfg.variables.isEmpty()) {
                cfg.println(out, "no variables defined");
                return;
            }
            for (Map.Entry<String, SessionConfig.BindVariable> e : cfg.variables.entrySet()) {
                cfg.println(out, "variable  " + e.getKey());
                cfg.println(out, "datatype  " + e.getValue().typeLabel());
            }
            return;
        }
        String key = name.toUpperCase(Locale.ROOT);
        if (typeSpec == null || typeSpec.trim().isEmpty()) {
            SessionConfig.BindVariable bv = cfg.getVariable(key);
            if (bv == null) {
                err.println("Error: variable " + key + " not defined");
                return;
            }
            cfg.println(out, "variable  " + key);
            cfg.println(out, "datatype  " + bv.typeLabel());
            return;
        }
        String ts = typeSpec.trim();
        String u = ts.toUpperCase(Locale.ROOT);
        if (u.startsWith("REFCURSOR") || u.startsWith("REF CURSOR")) {
            SessionConfig.BindVariable prev = cfg.getVariable(key);
            SessionConfig.BindVariable nv = new SessionConfig.BindVariable(
                    SessionConfig.BindVariable.Kind.REFCURSOR, 0);
            cfg.putVariable(key, nv);
            if (!quiet) {
                cfg.println(out, "variable " + key + " " + nv.typeLabel());
            }
            return;
        }
        SessionConfig.BindVariable.Kind kind;
        int size = 0;
        if (u.startsWith("NUMBER") || u.startsWith("BINARY_INTEGER")
                || u.startsWith("PLS_INTEGER")) {
            kind = SessionConfig.BindVariable.Kind.NUMBER;
        } else if (u.startsWith("CHAR")) {
            kind = SessionConfig.BindVariable.Kind.CHAR;
            size = parseTypeSize(ts, 1);
        } else if (u.startsWith("VARCHAR2") || u.startsWith("VARCHAR")
                || u.startsWith("STRING")) {
            kind = SessionConfig.BindVariable.Kind.VARCHAR2;
            size = parseTypeSize(ts, 4000);
        } else {
            err.println("Error: VARIABLE type must be NUMBER|VARCHAR2[(n)]|CHAR[(n)]|REFCURSOR");
            return;
        }
        SessionConfig.BindVariable prev = cfg.getVariable(key);
        SessionConfig.BindVariable nv = new SessionConfig.BindVariable(kind, size);
        if (prev != null) {
            nv.value = prev.value;
        }
        cfg.putVariable(key, nv);
        if (!quiet) {
            cfg.println(out, "variable " + key + " " + nv.typeLabel());
        }
    }

    private static int parseTypeSize(String typeSpec, int defaultSize) {
        int a = typeSpec.indexOf('(');
        int b = typeSpec.indexOf(')');
        if (a >= 0 && b > a) {
            try {
                int n = Integer.parseInt(typeSpec.substring(a + 1, b).trim());
                return n > 0 ? n : defaultSize;
            } catch (NumberFormatException e) {
                return defaultSize;
            }
        }
        return defaultSize;
    }

    /**
     * EXEC :name := 42 | 'text' — 直接写入 VARIABLE, 不走 JDBC OUT.
     * @return true 已处理
     */
    private boolean tryExecAssign(String body) {
        Matcher m = EXEC_ASSIGN.matcher(body.trim());
        if (!m.matches()) {
            return false;
        }
        String name = m.group(1).toUpperCase(Locale.ROOT);
        String rhs = m.group(2).trim();
        SessionConfig.BindVariable bv = session.config().getVariable(name);
        if (bv == null) {
            return false;
        }
        if (bv.kind == SessionConfig.BindVariable.Kind.REFCURSOR) {
            err.println("Error: cannot assign literal to REFCURSOR");
            return true;
        }
        ParsedLiteral lit = parseAssignLiteral(rhs);
        if (lit == null) {
            return false;
        }
        if (!lit.isNull && bv.kind == SessionConfig.BindVariable.Kind.NUMBER) {
            try {
                new java.math.BigDecimal(lit.value.trim());
            } catch (NumberFormatException e) {
                err.println("Error: NUMBER variable " + name + " got non-numeric: " + lit.value);
                return true;
            }
        }
        bv.value = lit.isNull ? null : lit.value;
        return true;
    }

    private static final class ParsedLiteral {
        final boolean isNull;
        final String value;

        ParsedLiteral(boolean isNull, String value) {
            this.isNull = isNull;
            this.value = value;
        }
    }

    /** 解析赋值右值字面量; 非字面量返回 null. */
    private static ParsedLiteral parseAssignLiteral(String rhs) {
        if (rhs == null) {
            return null;
        }
        String s = rhs.trim();
        if (s.endsWith(";")) {
            s = s.substring(0, s.length() - 1).trim();
        }
        if (s.matches("(?i)null")) {
            return new ParsedLiteral(true, null);
        }
        if (s.length() >= 2) {
            char a = s.charAt(0);
            char b = s.charAt(s.length() - 1);
            if (a == '\'' && b == '\'') {
                return new ParsedLiteral(false, s.substring(1, s.length() - 1).replace("''", "'"));
            }
            if (a == '"' && b == '"') {
                return new ParsedLiteral(false, s.substring(1, s.length() - 1));
            }
        }
        if (s.matches("-?\\d+(\\.\\d+)?")) {
            return new ParsedLiteral(false, s);
        }
        return null;
    }

    private void handlePrint(String rest) {
        SessionConfig cfg = session.config();
        List<String> names = new ArrayList<String>();
        if (rest == null || rest.trim().isEmpty()) {
            names.addAll(cfg.variables.keySet());
        } else {
            for (String tok : rest.trim().split("\\s+")) {
                names.add(tok.replace(":", "").toUpperCase(Locale.ROOT));
            }
        }
        if (names.isEmpty()) {
            cfg.println(out, "no variables defined");
            return;
        }
        for (String name : names) {
            SessionConfig.BindVariable bv = cfg.getVariable(name);
            if (bv == null) {
                err.println("Error: variable " + name + " not defined");
                continue;
            }
            cfg.println(out, name);
            cfg.println(out, "--------------------------------");
            if (bv.kind == SessionConfig.BindVariable.Kind.REFCURSOR) {
                if (!bv.isCursorOpen()) {
                    cfg.println(out, "variable " + name + " is not open");
                    cfg.println(out, "");
                    continue;
                }
                try {
                    executor.printCursorResult(bv.cursorRs, cfg);
                } catch (SQLException e) {
                    err.println("Error: PRINT " + name + ": " + e.getMessage());
                }
                cfg.println(out, "");
                continue;
            }
            cfg.println(out, bv.value == null ? cfg.nullText : bv.value);
            cfg.println(out, "");
        }
    }

    private static String formatWhenever(String kind, SessionConfig.WheneverPolicy p) {
        StringBuilder sb = new StringBuilder();
        sb.append("whenever ").append(kind.toLowerCase(Locale.ROOT)).append(' ');
        if (p.exit) {
            sb.append("EXIT ").append(p.status);
        } else {
            sb.append("CONTINUE");
        }
        sb.append(' ').append(p.txn);
        return sb.toString();
    }

    /** 关闭 SPOOL (进程退出时调用). */
    public void closeSpool() {
        SessionConfig cfg = session.config();
        if (cfg.spool != null) {
            cfg.spool.close();
            cfg.spool = null;
        }
        cfg.closeAllCursors();
    }

    /** 执行本地脚本文件 (供 @ 与 --script / ytop -E -f). */
    public void runScriptFile(File file, int depth) {
        runScriptFile(file, depth, new String[0]);
    }

    public void runScriptFile(File file, int depth, String[] scriptArgs) {
        if (file == null || !file.isFile()) {
            err.println("Error: script not found: " + (file == null ? "" : file.getPath()));
            onOsError();
            return;
        }
        Map<String, String> saved = session.config().beginScriptArgs(scriptArgs);
        try {
            runScriptReader(file, file.getParentFile(), depth);
        } finally {
            session.config().endScriptArgs(saved);
        }
    }

    public void runScript(String path, boolean relativeToScript, File scriptDir, int depth,
                          String[] scriptArgs) {
        if (depth >= MAX_NEST) {
            err.println("Error: @ nesting depth exceeded (" + MAX_NEST + ")");
            onOsError();
            return;
        }
        File f = resolveScriptFile(path, relativeToScript, scriptDir);
        if (f == null || !f.isFile()) {
            err.println("Error: script not found: " + path
                    + " (tried: absolute, sql-home/embed, cwd"
                    + (relativeToScript ? ", caller dir" : "") + ")");
            onOsError();
            return;
        }
        runScriptFile(f, depth, scriptArgs == null ? new String[0] : scriptArgs);
    }

    /**
     * 解析 @script 后的参数: 空白分隔; 支持 '...' / "..." .
     */
    static String[] parseScriptArgs(String rest) {
        if (rest == null) {
            return new String[0];
        }
        String s = rest.trim();
        if (s.isEmpty()) {
            return new String[0];
        }
        List<String> out = new ArrayList<String>();
        int i = 0;
        int n = s.length();
        while (i < n) {
            while (i < n && Character.isWhitespace(s.charAt(i))) {
                i++;
            }
            if (i >= n) {
                break;
            }
            char c = s.charAt(i);
            if (c == '\'' || c == '"') {
                char q = c;
                i++;
                StringBuilder sb = new StringBuilder();
                while (i < n) {
                    char d = s.charAt(i);
                    if (d == q) {
                        i++;
                        break;
                    }
                    sb.append(d);
                    i++;
                }
                out.add(sb.toString());
            } else {
                int start = i;
                while (i < n && !Character.isWhitespace(s.charAt(i))) {
                    i++;
                }
                out.add(s.substring(start, i));
            }
        }
        return out.toArray(new String[out.size()]);
    }

    /** ?path: 只读打印脚本内容 (不执行、不展开 &). */
    private void peekScript(String path, boolean relativeToScript, File scriptDir) {
        File f = resolveScriptFile(path, relativeToScript, scriptDir);
        if (f == null) {
            err.println("Error: cannot open " + path
                    + " (tried: absolute, sql-home/embed, cwd"
                    + (relativeToScript ? ", script-dir" : "") + ")");
            onOsError();
            return;
        }
        SessionConfig cfg = session.config();
        cfg.println(out, "Script: " + f.getAbsolutePath());
        BufferedReader br = null;
        try {
            br = new BufferedReader(new InputStreamReader(
                    new FileInputStream(f), StandardCharsets.UTF_8));
            String line;
            while ((line = br.readLine()) != null) {
                cfg.println(out, line);
            }
        } catch (IOException e) {
            err.println("Error: cannot read " + f.getAbsolutePath() + ": " + e.getMessage());
            onOsError();
        } finally {
            if (br != null) {
                try {
                    br.close();
                } catch (IOException ignored) {
                    // ignore
                }
            }
        }
    }

    /**
     * #path: 拷贝到临时文件 → EDITOR 编辑 → 有变更则 runScriptFile(temp);
     * 永不写回原文件.
     */
    private void editAndMaybeRun(String path, String[] scriptArgs,
                                 boolean relativeToScript, File scriptDir, int depth) {
        SessionConfig cfg = session.config();
        if (cfg.batch) {
            err.println("Error: # requires an interactive terminal");
            onOsError();
            return;
        }
        File src = resolveScriptFile(path, relativeToScript, scriptDir);
        if (src == null) {
            err.println("Error: cannot open " + path
                    + " (tried: absolute, sql-home/embed, cwd"
                    + (relativeToScript ? ", script-dir" : "") + ")");
            onOsError();
            return;
        }
        File tmp = null;
        try {
            tmp = File.createTempFile("ytop-yjdbc-edit-", ".sql");
            Files.copy(src.toPath(), tmp.toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            String editor = resolveEditor();
            ProcessBuilder pb = new ProcessBuilder(
                    "/bin/sh", "-c", editor + " \"$1\"", "sh", tmp.getAbsolutePath());
            pb.inheritIO();
            int code = pb.start().waitFor();
            if (code != 0) {
                err.println("Edit cancelled.");
                return;
            }
            if (sameFileBytes(src, tmp)) {
                err.println("No changes; not executed.");
                return;
            }
            runScriptFile(tmp, depth, scriptArgs == null ? new String[0] : scriptArgs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            err.println("Edit cancelled.");
        } catch (IOException e) {
            err.println("Error: # edit failed: " + e.getMessage());
            onOsError();
        } finally {
            if (tmp != null && tmp.exists() && !tmp.delete()) {
                tmp.deleteOnExit();
            }
        }
    }

    private static String resolveEditor() {
        String e = System.getenv("EDITOR");
        if (e != null && !e.trim().isEmpty()) {
            return e.trim();
        }
        e = System.getenv("VISUAL");
        if (e != null && !e.trim().isEmpty()) {
            return e.trim();
        }
        return "vi";
    }

    private static boolean sameFileBytes(File a, File b) throws IOException {
        if (a.length() != b.length()) {
            return false;
        }
        FileInputStream inA = null;
        FileInputStream inB = null;
        try {
            inA = new FileInputStream(a);
            inB = new FileInputStream(b);
            byte[] bufA = new byte[8192];
            byte[] bufB = new byte[8192];
            while (true) {
                int na = inA.read(bufA);
                int nb = inB.read(bufB);
                if (na != nb) {
                    return false;
                }
                if (na < 0) {
                    return true;
                }
                for (int i = 0; i < na; i++) {
                    if (bufA[i] != bufB[i]) {
                        return false;
                    }
                }
            }
        } finally {
            if (inA != null) {
                try {
                    inA.close();
                } catch (IOException ignored) {
                    // ignore
                }
            }
            if (inB != null) {
                try {
                    inB.close();
                } catch (IOException ignored) {
                    // ignore
                }
            }
        }
    }

    /**
     * @ 脚本路径解析:
     * 1) 绝对路径 (存在则用)
     * 2) @@ 时优先调用方脚本目录
     * 3) sql-home (ytop 抽出的内嵌 SQL)
     * 4) 当前工作目录 cwd
     */
    File resolveScriptFile(String path, boolean relativeToScript, File scriptDir) {
        if (path == null || path.trim().isEmpty()) {
            return null;
        }
        path = path.trim();
        File abs = new File(path);
        if (abs.isAbsolute()) {
            return abs.isFile() ? abs : null;
        }
        // @@file: 相对调用脚本目录优先 (Oracle 语义)
        if (relativeToScript && scriptDir != null) {
            File beside = new File(scriptDir, path);
            if (beside.isFile()) {
                return beside;
            }
        }
        // 内嵌 / sql-home
        String home = session.config().sqlHome;
        if (home != null && !home.trim().isEmpty()) {
            File embedded = new File(home.trim(), path);
            if (embedded.isFile()) {
                return embedded;
            }
            // 仅文件名 (去掉子路径) 再试一次, 兼容 @subdir/x.sql 扁平抽出
            File byBase = new File(home.trim(), new File(path).getName());
            if (byBase.isFile()) {
                return byBase;
            }
        }
        // 当前目录
        File cwd = new File(System.getProperty("user.dir"), path);
        if (cwd.isFile()) {
            return cwd;
        }
        return null;
    }

    private void runScriptReader(File f, File parent, int depth) {
        BufferedReader br = null;
        try {
            br = new BufferedReader(new InputStreamReader(
                    new FileInputStream(f), StandardCharsets.UTF_8));
            StringBuilder buf = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) {
                if (isStopRequested()) {
                    break;
                }
                String t = line.trim();
                if (t.isEmpty() || t.startsWith("--") || REM.matcher(t).matches()) {
                    continue;
                }
                if ("/".equals(t)) {
                    flushBuffer(buf, parent, depth + 1);
                    continue;
                }
                // EXIT/QUIT (含参数) 走 tryHandle, 可带退出码
                if (buf.length() == 0) {
                    String cand = SqlExecutor.parseStmt(t).sql;
                    if (!cand.isEmpty() && EXIT_CMD.matcher(cand).matches()) {
                        tryHandle(cand, parent, depth + 1);
                        break;
                    }
                    if (!cand.isEmpty() && tryHandle(cand, parent, depth + 1)) {
                        if (isStopRequested()) {
                            break;
                        }
                        continue;
                    }
                }
                if (buf.length() > 0) {
                    buf.append('\n');
                }
                buf.append(line);
                String bt = buf.toString().trim();
                // PL/SQL 匿名块仅由 / 提交, 避免内部 ; 提前断句
                if (SqlExecutor.looksLikePlsql(bt)) {
                    continue;
                }
                if (SqlExecutor.endsWithVerticalTerminator(bt) || bt.endsWith(";")) {
                    SqlExecutor.StmtSpec spec = SqlExecutor.parseStmt(bt);
                    buf.setLength(0);
                    dispatch(spec.sql + (spec.verticalOnce ? "\\G" : ""), parent, depth + 1);
                    if (isStopRequested()) {
                        break;
                    }
                }
            }
            if (!isStopRequested()) {
                flushBuffer(buf, parent, depth + 1);
            }
        } catch (IOException e) {
            err.println("Error reading script: " + e.getMessage());
        } finally {
            if (br != null) {
                try {
                    br.close();
                } catch (IOException ignored) {
                    // ignore
                }
            }
        }
    }

    private void flushBuffer(StringBuilder buf, File scriptDir, int depth) {
        if (buf.length() == 0) {
            return;
        }
        SqlExecutor.StmtSpec spec = SqlExecutor.parseStmt(buf.toString());
        buf.setLength(0);
        dispatch(spec.sql + (spec.verticalOnce ? "\\G" : ""), scriptDir, depth);
    }

    private void dispatch(String stmt, File scriptDir, int depth) {
        if (stmt == null || stmt.isEmpty() || isStopRequested()) {
            return;
        }
        if (tryHandle(stmt, scriptDir, depth)) {
            return;
        }
        dispatchSql(stmt);
    }

    private void acceptVar(String name, String rest) {
        String prompt = null;
        String defVal = null;
        boolean hide = false;
        boolean number = false;
        String r = rest == null ? "" : rest.trim();
        if (r.endsWith(";")) {
            r = r.substring(0, r.length() - 1).trim();
        }
        // 简易扫描: PROMPT '...' | DEFAULT val | HIDE | NUMBER | CHAR
        while (!r.isEmpty()) {
            String u = r.toUpperCase(Locale.ROOT);
            if (u.startsWith("PROMPT")) {
                r = r.substring(6).trim();
                if (r.isEmpty()) {
                    break;
                }
                if (r.charAt(0) == '\'' || r.charAt(0) == '"') {
                    char q = r.charAt(0);
                    int i = 1;
                    StringBuilder sb = new StringBuilder();
                    while (i < r.length() && r.charAt(i) != q) {
                        sb.append(r.charAt(i++));
                    }
                    prompt = sb.toString();
                    r = i < r.length() ? r.substring(i + 1).trim() : "";
                } else {
                    String[] p = splitFirstToken(r);
                    prompt = p[0];
                    r = p[1];
                }
                continue;
            }
            if (u.startsWith("DEFAULT") || u.startsWith("DEF ")) {
                int skip = u.startsWith("DEFAULT") ? 7 : 3;
                r = r.substring(skip).trim();
                String[] p = splitFirstToken(r);
                defVal = stripQuotes(p[0]);
                r = p[1];
                continue;
            }
            if (u.startsWith("HIDE")) {
                hide = true;
                r = r.substring(4).trim();
                continue;
            }
            if (u.startsWith("NUMBER") || u.startsWith("NUM")) {
                number = true;
                r = u.startsWith("NUMBER") ? r.substring(6).trim() : r.substring(3).trim();
                continue;
            }
            if (u.startsWith("CHAR")) {
                r = r.substring(4).trim();
                continue;
            }
            break;
        }
        String p = prompt == null || prompt.isEmpty() ? ("Enter value for " + name + ": ") : prompt;
        if (!p.endsWith(" ") && !p.endsWith(":")) {
            p = p + " ";
        }
        if (session.config().batch) {
            if (defVal != null) {
                session.config().define(name, defVal);
                return;
            }
            err.println("Error: ACCEPT not allowed in batch mode (use DEFINE / --define)");
            return;
        }
        out.print(p);
        out.flush();
        try {
            if (promptIn == null) {
                err.println("Error: no input for ACCEPT");
                return;
            }
            String line;
            if (hide) {
                // 无控制台 echo 关闭时退化为普通读入
                line = promptIn.readLine();
            } else {
                line = promptIn.readLine();
            }
            if (line == null || line.isEmpty()) {
                line = defVal == null ? "" : defVal;
            }
            if (number && !line.isEmpty()) {
                try {
                    new java.math.BigDecimal(line.trim());
                } catch (NumberFormatException e) {
                    err.println("Error: ACCEPT NUMBER invalid: " + line);
                    return;
                }
            }
            session.config().define(name, line);
        } catch (IOException e) {
            err.println("Error: " + e.getMessage());
        }
    }

    private void listDefines() {
        if (session.config().defines.isEmpty()) {
            out.println("no DEFINEs");
            return;
        }
        for (Map.Entry<String, String> e : session.config().defines.entrySet()) {
            out.println("DEFINE " + e.getKey() + " = \"" + e.getValue() + "\"");
        }
    }

    private void listColFormats() {
        SessionConfig cfg = session.config();
        if (cfg.columns.isEmpty()) {
            out.println("no COLUMN formats defined");
            return;
        }
        for (Map.Entry<String, SessionConfig.ColumnFormat> e : cfg.columns.entrySet()) {
            out.println(formatColumnLine(e.getKey(), e.getValue()));
        }
    }

    private void handleColumn(String name, String clauses) {
        SessionConfig cfg = session.config();
        if (clauses == null || clauses.trim().isEmpty()) {
            SessionConfig.ColumnFormat cf = cfg.getColumn(name);
            if (cf == null) {
                out.println("COLUMN " + name.toUpperCase(Locale.ROOT) + " not defined");
                return;
            }
            out.println(formatColumnLine(name.toUpperCase(Locale.ROOT), cf));
            return;
        }
        SessionConfig.ColumnFormat cf = cfg.ensureColumn(name);
        applyColumnClauses(cf, clauses.trim());
    }

    private void applyColumnClauses(SessionConfig.ColumnFormat cf, String clauses) {
        String s = clauses;
        while (!s.isEmpty()) {
            String u = s.toUpperCase(Locale.ROOT);
            if (u.startsWith("FORMAT") || u.startsWith("FOR ")) {
                int skip = u.startsWith("FORMAT") ? 6 : 3;
                s = s.substring(skip).trim();
                if (s.toUpperCase(Locale.ROOT).startsWith("MAT")) {
                    // FOR MAT -> already handled as FORMAT via "FOR "
                    s = s.substring(3).trim();
                }
                String[] parts = splitFirstToken(s);
                String fmt = parts[0];
                s = parts[1];
                applyColumnFormat(cf, fmt);
                continue;
            }
            if (u.startsWith("HEADING") || u.startsWith("HEA ")) {
                int skip = u.startsWith("HEADING") ? 7 : 3;
                s = s.substring(skip).trim();
                if (s.toUpperCase(Locale.ROOT).startsWith("DING")) {
                    s = s.substring(4).trim();
                }
                String[] parts = splitHeadingValue(s);
                cf.heading = stripQuotes(parts[0]);
                s = parts[1];
                continue;
            }
            if (u.startsWith("NOPRINT")) {
                cf.noprint = true;
                s = s.substring(7).trim();
                continue;
            }
            if (u.startsWith("PRINT") && !u.startsWith("PRINTS")) {
                // PRINT (cancel NOPRINT); avoid matching nothing else
                if (u.equals("PRINT") || u.startsWith("PRINT ") || u.startsWith("PRINT\t")) {
                    cf.noprint = false;
                    s = s.substring(5).trim();
                    continue;
                }
            }
            if (u.startsWith("JUSTIFY") || u.startsWith("JUS ")) {
                int skip = u.startsWith("JUSTIFY") ? 7 : 3;
                s = s.substring(skip).trim();
                if (s.toUpperCase(Locale.ROOT).startsWith("TIFY")) {
                    s = s.substring(4).trim();
                }
                String[] parts = splitFirstToken(s);
                String j = parts[0].toUpperCase(Locale.ROOT);
                if ("L".equals(j) || "LEFT".equals(j)) {
                    cf.justify = "LEFT";
                } else if ("C".equals(j) || "CENTER".equals(j) || "CENTRE".equals(j)) {
                    cf.justify = "CENTER";
                } else if ("R".equals(j) || "RIGHT".equals(j)) {
                    cf.justify = "RIGHT";
                } else {
                    err.println("unsupported COLUMN JUSTIFY " + parts[0]);
                }
                s = parts[1];
                continue;
            }
            if (u.startsWith("TRUNCATED") || u.equals("TRU") || u.startsWith("TRU ")) {
                cf.wrap = "TRUNCATED";
                if (u.startsWith("TRUNCATED")) {
                    s = s.substring(9).trim();
                } else {
                    s = s.substring(3).trim();
                }
                continue;
            }
            if (u.startsWith("WORD_WRAPPED") || u.startsWith("WOR")) {
                cf.wrap = "WORD_WRAPPED";
                if (u.startsWith("WORD_WRAPPED")) {
                    s = s.substring(12).trim();
                } else {
                    s = s.substring(3).trim();
                }
                continue;
            }
            if (u.startsWith("WRAPPED") || (u.startsWith("WRA") && !u.startsWith("WRAPX"))) {
                cf.wrap = "WRAPPED";
                if (u.startsWith("WRAPPED")) {
                    s = s.substring(7).trim();
                } else {
                    s = s.substring(3).trim();
                }
                continue;
            }
            if (u.startsWith("NEW_VALUE") || u.startsWith("NEW ")) {
                int skip = u.startsWith("NEW_VALUE") ? 9 : 3;
                s = s.substring(skip).trim();
                if (s.toUpperCase(Locale.ROOT).startsWith("_VALUE")) {
                    s = s.substring(6).trim();
                } else if (s.toUpperCase(Locale.ROOT).startsWith("VALUE")) {
                    s = s.substring(5).trim();
                }
                String[] parts = splitFirstToken(s);
                cf.newValue = parts[0].replace(":", "");
                s = parts[1];
                continue;
            }
            if (u.startsWith("OLD_VALUE") || u.startsWith("OLD ")) {
                int skip = u.startsWith("OLD_VALUE") ? 9 : 3;
                s = s.substring(skip).trim();
                if (s.toUpperCase(Locale.ROOT).startsWith("_VALUE")) {
                    s = s.substring(6).trim();
                } else if (s.toUpperCase(Locale.ROOT).startsWith("VALUE")) {
                    s = s.substring(5).trim();
                }
                String[] parts = splitFirstToken(s);
                cf.oldValue = parts[0].replace(":", "");
                s = parts[1];
                continue;
            }
            String[] parts = splitFirstToken(s);
            err.println("unsupported COLUMN " + parts[0]);
            s = parts[1];
        }
    }

    private void applyColumnFormat(SessionConfig.ColumnFormat cf, String fmt) {
        if (fmt == null || fmt.isEmpty()) {
            err.println("Error: COLUMN FORMAT requires a format");
            return;
        }
        if (fmt.length() >= 2 && (fmt.charAt(0) == 'A' || fmt.charAt(0) == 'a')
                && Character.isDigit(fmt.charAt(1))) {
            try {
                int w = Integer.parseInt(fmt.substring(1));
                if (w < 1) {
                    err.println("Error: COLUMN width must be >= 1");
                    return;
                }
                cf.width = Integer.valueOf(w);
                cf.numFormat = null;
            } catch (NumberFormatException e) {
                err.println("Error: COLUMN FORMAT " + fmt);
            }
            return;
        }
        // 数值掩码: 含 9/0/# 等
        if (fmt.matches("(?i).*[90#].*")) {
            cf.numFormat = fmt;
            cf.width = Integer.valueOf(SessionConfig.numFormatWidth(fmt));
            return;
        }
        err.println("unsupported COLUMN FORMAT " + fmt);
    }

    private static String[] splitFirstToken(String s) {
        s = s.trim();
        if (s.isEmpty()) {
            return new String[] {"", ""};
        }
        int i = 0;
        while (i < s.length() && !Character.isWhitespace(s.charAt(i))) {
            i++;
        }
        return new String[] {s.substring(0, i), s.substring(i).trim()};
    }

    /** HEADING 值: 引号串或直到下一关键字. */
    private static String[] splitHeadingValue(String s) {
        s = s.trim();
        if (s.isEmpty()) {
            return new String[] {"", ""};
        }
        if (s.charAt(0) == '\'' || s.charAt(0) == '"') {
            char q = s.charAt(0);
            int i = 1;
            StringBuilder sb = new StringBuilder();
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c == q) {
                    i++;
                    break;
                }
                sb.append(c);
                i++;
            }
            return new String[] {sb.toString(), s.substring(i).trim()};
        }
        // 无引号: 取到下一已知子句关键字或结尾
        String[] known = new String[] {
                "FORMAT", "FOR", "HEADING", "HEA", "NOPRINT", "PRINT", "JUSTIFY", "JUS",
                "TRUNCATED", "TRU", "WRAPPED", "WRA", "WORD_WRAPPED", "WOR",
                "NEW_VALUE", "NEW", "OLD_VALUE", "OLD"
        };
        String u = s.toUpperCase(Locale.ROOT);
        int cut = s.length();
        for (String k : known) {
            int idx = u.indexOf(" " + k);
            if (idx > 0 && idx < cut) {
                cut = idx;
            }
        }
        return new String[] {s.substring(0, cut).trim(), s.substring(cut).trim()};
    }

    private static String formatColumnLine(String name, SessionConfig.ColumnFormat cf) {
        StringBuilder sb = new StringBuilder();
        sb.append("COLUMN ").append(name);
        if (cf.numFormat != null) {
            sb.append(" FORMAT ").append(cf.numFormat);
        } else if (cf.width != null) {
            sb.append(" FORMAT A").append(cf.width);
        }
        if (cf.heading != null) {
            sb.append(" HEADING ").append(cf.heading);
        }
        if (cf.noprint) {
            sb.append(" NOPRINT");
        }
        if (cf.justify != null) {
            sb.append(" JUSTIFY ").append(cf.justify);
        }
        if (cf.wrap != null) {
            sb.append(' ').append(cf.wrap);
        }
        if (cf.newValue != null) {
            sb.append(" NEW_VALUE ").append(cf.newValue);
        }
        if (cf.oldValue != null) {
            sb.append(" OLD_VALUE ").append(cf.oldValue);
        }
        return sb.toString();
    }

    private void handleTitle(boolean top, String rest, boolean quiet) {
        SessionConfig cfg = session.config();
        if (rest == null || rest.trim().isEmpty()) {
            String t = top ? cfg.ttitle : cfg.btitle;
            boolean on = top ? cfg.ttitleOn : cfg.btitleOn;
            cfg.println(out, (top ? "ttitle" : "btitle") + " "
                    + (on ? ("ON \"" + t + "\"") : "OFF"));
            return;
        }
        String u = rest.trim().toUpperCase(Locale.ROOT);
        if ("OFF".equals(u)) {
            if (top) {
                cfg.ttitleOn = false;
            } else {
                cfg.btitleOn = false;
            }
            if (!quiet) {
                cfg.println(out, (top ? "ttitle" : "btitle") + " OFF");
            }
            return;
        }
        if ("ON".equals(u)) {
            if (top) {
                cfg.ttitleOn = true;
            } else {
                cfg.btitleOn = true;
            }
            if (!quiet) {
                cfg.println(out, (top ? "ttitle" : "btitle") + " ON");
            }
            return;
        }
        String text = stripQuotes(rest.trim());
        if (top) {
            cfg.ttitle = text;
            cfg.ttitleOn = true;
        } else {
            cfg.btitle = text;
            cfg.btitleOn = true;
        }
        if (!quiet) {
            cfg.println(out, (top ? "ttitle" : "btitle") + " ON \"" + text + "\"");
        }
    }

    private void handleBreak(String rest, boolean quiet) {
        SessionConfig cfg = session.config();
        if (rest == null || rest.trim().isEmpty()) {
            if (cfg.breaks.isEmpty()) {
                cfg.println(out, "no breaks defined");
                return;
            }
            for (SessionConfig.BreakSpec b : cfg.breaks) {
                cfg.println(out, "break on " + b.column
                        + (b.skipPage ? " skip page"
                        : (b.skipLines > 0 ? (" skip " + b.skipLines) : "")));
            }
            return;
        }
        String u = rest.trim().toUpperCase(Locale.ROOT);
        if (!u.startsWith("ON ")) {
            err.println("Error: BREAK ON column [SKIP n|PAGE]");
            return;
        }
        String[] toks = rest.trim().substring(3).trim().split("\\s+");
        if (toks.length < 1) {
            err.println("Error: BREAK ON column [SKIP n|PAGE]");
            return;
        }
        SessionConfig.BreakSpec b = new SessionConfig.BreakSpec();
        b.column = toks[0].replace("\"", "").toUpperCase(Locale.ROOT);
        for (int i = 1; i < toks.length; i++) {
            String t = toks[i].toUpperCase(Locale.ROOT);
            if ("SKIP".equals(t) && i + 1 < toks.length) {
                String n = toks[++i].toUpperCase(Locale.ROOT);
                if ("PAGE".equals(n)) {
                    b.skipPage = true;
                } else {
                    try {
                        b.skipLines = Integer.parseInt(n);
                    } catch (NumberFormatException e) {
                        err.println("Error: BREAK SKIP n|PAGE");
                        return;
                    }
                }
            } else if ("PAGE".equals(t)) {
                b.skipPage = true;
            }
        }
        // 同列替换
        for (int i = 0; i < cfg.breaks.size(); i++) {
            if (cfg.breaks.get(i).column.equals(b.column)) {
                cfg.breaks.set(i, b);
                if (!quiet) {
                    cfg.println(out, "break on " + b.column);
                }
                return;
            }
        }
        cfg.breaks.add(b);
        if (!quiet) {
            cfg.println(out, "break on " + b.column);
        }
    }

    private void handleCompute(String rest, boolean quiet) {
        SessionConfig cfg = session.config();
        if (rest == null || rest.trim().isEmpty()) {
            if (cfg.computes.isEmpty()) {
                cfg.println(out, "no computes defined");
                return;
            }
            for (SessionConfig.ComputeSpec c : cfg.computes) {
                cfg.println(out, "COMPUTE " + c.func + " OF " + c.ofColumn + " ON " + c.onBreak);
            }
            return;
        }
        // COMPUTE SUM OF sal ON dept
        Matcher m = Pattern.compile(
                "(?i)^\\s*(SUM|COUNT|AVG|MIN|MAX)\\s+OF\\s+([\\w.$#\"]+)\\s+ON\\s+([\\w.$#\"]+|REPORT)\\s*$")
                .matcher(rest.trim());
        if (!m.matches()) {
            err.println("Error: COMPUTE SUM|COUNT|AVG|MIN|MAX OF col ON break|REPORT");
            return;
        }
        SessionConfig.ComputeSpec c = new SessionConfig.ComputeSpec();
        c.func = m.group(1).toUpperCase(Locale.ROOT);
        c.ofColumn = m.group(2).replace("\"", "").toUpperCase(Locale.ROOT);
        c.onBreak = m.group(3).replace("\"", "").toUpperCase(Locale.ROOT);
        cfg.computes.add(c);
        if (!quiet) {
            cfg.println(out, "COMPUTE " + c.func + " OF " + c.ofColumn + " ON " + c.onBreak);
        }
    }

    private void handlePause(String text) {
        SessionConfig cfg = session.config();
        if (cfg.batch) {
            return;
        }
        String msg = text == null ? "" : text;
        if (!msg.isEmpty()) {
            cfg.println(out, msg);
        }
        out.print("Hit ENTER to continue...");
        out.flush();
        try {
            if (promptIn != null) {
                promptIn.readLine();
            }
        } catch (IOException e) {
            err.println("Error: " + e.getMessage());
        }
    }

    private void handleHost(String cmd) {
        SessionConfig cfg = session.config();
        if (!cfg.hostEnabled) {
            err.println("Error: HOST disabled (SET HOST ON to enable)");
            return;
        }
        String c = cmd == null ? "" : cmd.trim();
        if (c.isEmpty()) {
            err.println("Error: HOST requires a command");
            return;
        }
        try {
            ProcessBuilder pb = new ProcessBuilder("/bin/sh", "-c", c);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
            String line;
            while ((line = br.readLine()) != null) {
                cfg.println(out, line);
            }
            int code = p.waitFor();
            if (code != 0) {
                err.println("HOST exit code " + code);
                onOsError();
            }
        } catch (Exception e) {
            err.println("Error: HOST failed: " + e.getMessage());
            onOsError();
        }
    }

    private void handleConnect(String rest) {
        // user/pass@host:port/db 或 user/pass 或 / as sysdba 简化: user/password@url-tail
        if (rest == null || rest.trim().isEmpty()) {
            err.println("Error: CONNECT user/password@host:port/db");
            return;
        }
        String s = rest.trim();
        try {
            String user;
            String pass;
            String hostPart = null;
            int at = s.lastIndexOf('@');
            String cred = at >= 0 ? s.substring(0, at) : s;
            if (at >= 0) {
                hostPart = s.substring(at + 1);
            }
            int slash = cred.indexOf('/');
            if (slash < 0) {
                err.println("Error: CONNECT user/password[@host:port/db]");
                return;
            }
            user = cred.substring(0, slash);
            pass = cred.substring(slash + 1);
            SessionConfig cfg = session.config();
            cfg.user = user;
            cfg.password = pass;
            if (hostPart != null && !hostPart.isEmpty()) {
                // host:port/db → jdbc:yasdb://host:port/db
                if (!hostPart.regionMatches(true, 0, "jdbc:", 0, 5)) {
                    cfg.url = "jdbc:yasdb://" + hostPart;
                } else {
                    cfg.url = hostPart;
                }
            }
            session.reconnect();
            cfg.println(out, "Connected.");
        } catch (SQLException e) {
            err.println("Error: CONNECT failed: " + e.getMessage());
            onOsError();
        }
    }

    private void handleDisconnect() {
        session.close();
        session.config().println(out, "Disconnected.");
    }

    private boolean handleBufferCmd(String s) {
        SessionConfig cfg = session.config();
        Matcher m = BUF_LIST.matcher(s);
        if (m.matches()) {
            listBuffer(m.group(1));
            return true;
        }
        if (BUF_RUN.matcher(s).matches()) {
            runBuffer();
            return true;
        }
        m = BUF_DEL.matcher(s);
        if (m.matches()) {
            deleteBuffer(m.group(1));
            return true;
        }
        m = BUF_APPEND.matcher(s);
        if (m.matches()) {
            String add = m.group(1);
            if (cfg.sqlBuffer.isEmpty()) {
                cfg.sqlBuffer = add;
            } else {
                cfg.sqlBuffer = cfg.sqlBuffer + " " + add;
            }
            return true;
        }
        m = BUF_CHANGE.matcher(s);
        if (m.matches()) {
            String from = m.group(1);
            String to = m.group(2);
            if (to.endsWith("/")) {
                to = to.substring(0, to.length() - 1);
            }
            if (cfg.sqlBuffer.isEmpty()) {
                err.println("Error: buffer empty");
                return true;
            }
            int idx = cfg.sqlBuffer.indexOf(from);
            if (idx < 0) {
                err.println("Error: string not found in buffer");
                return true;
            }
            cfg.sqlBuffer = cfg.sqlBuffer.substring(0, idx) + to
                    + cfg.sqlBuffer.substring(idx + from.length());
            listBuffer(null);
            return true;
        }
        m = BUF_GET.matcher(s);
        if (m.matches()) {
            File f = new File(m.group(1));
            try {
                BufferedReader br = new BufferedReader(new InputStreamReader(
                        new FileInputStream(f), StandardCharsets.UTF_8));
                try {
                    StringBuilder sb = new StringBuilder();
                    String line;
                    while ((line = br.readLine()) != null) {
                        if (sb.length() > 0) {
                            sb.append('\n');
                        }
                        sb.append(line);
                    }
                    cfg.sqlBuffer = sb.toString();
                    listBuffer(null);
                } finally {
                    br.close();
                }
            } catch (IOException e) {
                err.println("Error: GET failed: " + e.getMessage());
                onOsError();
            }
            return true;
        }
        m = BUF_SAVE.matcher(s);
        if (m.matches()) {
            try {
                PrintStream ps = new PrintStream(
                        new FileOutputStream(m.group(1)), false, "UTF-8");
                try {
                    ps.print(cfg.sqlBuffer);
                    if (!cfg.sqlBuffer.endsWith("\n")) {
                        ps.println();
                    }
                } finally {
                    ps.close();
                }
                cfg.println(out, "Wrote " + m.group(1));
            } catch (IOException e) {
                err.println("Error: SAVE failed: " + e.getMessage());
                onOsError();
            }
            return true;
        }
        m = BUF_INPUT.matcher(s);
        if (m.matches()) {
            String line = m.group(1);
            if (line != null && !line.isEmpty()) {
                if (cfg.sqlBuffer.isEmpty()) {
                    cfg.sqlBuffer = line;
                } else {
                    cfg.sqlBuffer = cfg.sqlBuffer + "\n" + line;
                }
            }
            return true;
        }
        return false;
    }

    private void listBuffer(String range) {
        SessionConfig cfg = session.config();
        if (cfg.sqlBuffer == null || cfg.sqlBuffer.isEmpty()) {
            cfg.println(out, "No lines in SQL buffer.");
            return;
        }
        String[] lines = cfg.sqlBuffer.split("\n", -1);
        int from = 1;
        int to = lines.length;
        if (range != null && !"*".equals(range)) {
            String[] p = range.trim().split("\\s+");
            try {
                from = Integer.parseInt(p[0]);
                to = p.length > 1 ? Integer.parseInt(p[1]) : from;
            } catch (NumberFormatException e) {
                // list all
            }
        }
        for (int i = 1; i <= lines.length; i++) {
            if (i < from || i > to) {
                continue;
            }
            cfg.println(out, String.format(Locale.ROOT, "%3d* %s", i, lines[i - 1]));
        }
    }

    private void deleteBuffer(String range) {
        SessionConfig cfg = session.config();
        if (range == null || "*".equals(range)) {
            cfg.sqlBuffer = "";
            return;
        }
        String[] lines = cfg.sqlBuffer.split("\n", -1);
        int from = 1;
        int to = lines.length;
        String[] p = range.trim().split("\\s+");
        try {
            from = Integer.parseInt(p[0]);
            to = p.length > 1 ? Integer.parseInt(p[1]) : from;
        } catch (NumberFormatException e) {
            err.println("Error: DEL [n|n m|*]");
            return;
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 1; i <= lines.length; i++) {
            if (i >= from && i <= to) {
                continue;
            }
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(lines[i - 1]);
        }
        cfg.sqlBuffer = sb.toString();
    }

    private void runBuffer() {
        SessionConfig cfg = session.config();
        String sql = cfg.sqlBuffer;
        if (sql == null || sql.trim().isEmpty()) {
            sql = cfg.lastSql;
        }
        if (sql == null || sql.trim().isEmpty()) {
            err.println("Error: buffer empty");
            return;
        }
        dispatchSql(sql);
        if (!cfg.lastSqlFailed) {
            cfg.lastSql = sql;
            cfg.sqlBuffer = sql;
        }
    }

    /** 供 Repl: 成功执行后更新缓冲. */
    public void rememberSql(String sql) {
        if (sql == null || sql.trim().isEmpty()) {
            return;
        }
        session.config().lastSql = sql;
        session.config().sqlBuffer = sql;
    }

    /** 供 Repl 入史: 上一成功 SQL (可能为空). */
    public String peekRememberedSql() {
        String s = session.config().lastSql;
        return s == null ? "" : s;
    }

    private void describe(String name) {
        String raw = name.replace("\"", "");
        String schema = null;
        String table = raw;
        int dot = raw.indexOf('.');
        if (dot > 0) {
            schema = raw.substring(0, dot);
            table = raw.substring(dot + 1);
        }
        try {
            // JDBC metadata 对同义词/V$ 视图常为空, 再走数据字典并解析同义词
            if (describeViaJdbc(schema, table)) {
                return;
            }
            if (describeViaDict(schema, table)) {
                return;
            }
            err.println("Object " + raw + " does not exist.");
        } catch (SQLException e) {
            err.println("DESC error: " + e.getMessage());
        }
    }

    private boolean describeViaJdbc(String schema, String table) throws SQLException {
        DatabaseMetaData md = session.connection().getMetaData();
        String[] schemas;
        if (schema == null || schema.isEmpty()) {
            schemas = new String[]{null};
        } else {
            String up = schema.toUpperCase(Locale.ROOT);
            schemas = schema.equals(up) ? new String[]{schema} : new String[]{schema, up};
        }
        String upTable = table.toUpperCase(Locale.ROOT);
        String[] tables = table.equals(upTable) ? new String[]{table} : new String[]{table, upTable};
        for (String sch : schemas) {
            for (String tab : tables) {
                ResultSet rs = null;
                try {
                    rs = md.getColumns(null, sch, tab, null);
                    if (printJdbcColumns(rs)) {
                        return true;
                    }
                } finally {
                    if (rs != null) {
                        try {
                            rs.close();
                        } catch (SQLException ignored) {
                            // ignore
                        }
                    }
                }
            }
        }
        return false;
    }

    private boolean printJdbcColumns(ResultSet rs) throws SQLException {
        boolean any = false;
        while (rs.next()) {
            if (!any) {
                printDescribeHeader();
                any = true;
            }
            String col = rs.getString("COLUMN_NAME");
            String isNull = rs.getString("IS_NULLABLE");
            String nullable = "NO".equalsIgnoreCase(isNull) ? "NOT NULL" : "";
            String type = rs.getString("TYPE_NAME");
            int size = rs.getInt("COLUMN_SIZE");
            printDescribeRow(col, nullable, formatType(type, size, null, null));
        }
        return any;
    }

    /**
     * 经 ALL_SYNONYMS / V$→V_$ 解析后查 ALL_TAB_COLUMNS, 按 sqlplus DESC 格式打印.
     */
    private boolean describeViaDict(String schema, String table) throws SQLException {
        ObjRef ref = resolveDictObject(schema, table);
        String sql;
        if (ref.owner != null) {
            sql = "SELECT COLUMN_NAME, NULLABLE, DATA_TYPE, DATA_LENGTH, DATA_PRECISION, DATA_SCALE "
                    + "FROM ALL_TAB_COLUMNS WHERE OWNER = ? AND TABLE_NAME = ? ORDER BY COLUMN_ID";
        } else {
            sql = "SELECT COLUMN_NAME, NULLABLE, DATA_TYPE, DATA_LENGTH, DATA_PRECISION, DATA_SCALE "
                    + "FROM USER_TAB_COLUMNS WHERE TABLE_NAME = ? ORDER BY COLUMN_ID";
        }
        PreparedStatement ps = null;
        ResultSet rs = null;
        try {
            ps = session.connection().prepareStatement(sql);
            if (ref.owner != null) {
                ps.setString(1, ref.owner);
                ps.setString(2, ref.table);
            } else {
                ps.setString(1, ref.table);
            }
            rs = ps.executeQuery();
            boolean any = false;
            while (rs.next()) {
                if (!any) {
                    printDescribeHeader();
                    any = true;
                }
                String col = rs.getString(1);
                String nullFlag = rs.getString(2);
                String nullable = isNotNullFlag(nullFlag) ? "NOT NULL" : "";
                String dataType = rs.getString(3);
                int length = rs.getInt(4);
                Integer precision = getNullableInt(rs, 5);
                Integer scale = getNullableInt(rs, 6);
                printDescribeRow(col, nullable, formatType(dataType, length, precision, scale));
            }
            return any;
        } finally {
            if (rs != null) {
                try {
                    rs.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
            if (ps != null) {
                try {
                    ps.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
        }
    }

    private ObjRef resolveDictObject(String schema, String table) throws SQLException {
        String tab = table.toUpperCase(Locale.ROOT);
        if (schema != null && !schema.isEmpty()) {
            return new ObjRef(schema.toUpperCase(Locale.ROOT), tab);
        }
        // PUBLIC/私有同义词: V$SQL → SYS.V_$SQL
        PreparedStatement ps = null;
        ResultSet rs = null;
        try {
            ps = session.connection().prepareStatement(
                    "SELECT * FROM ("
                            + "SELECT TABLE_OWNER, TABLE_NAME FROM ALL_SYNONYMS WHERE SYNONYM_NAME = ? "
                            + "ORDER BY CASE WHEN OWNER = USER THEN 0 WHEN OWNER = 'PUBLIC' THEN 1 ELSE 2 END"
                            + ") WHERE ROWNUM = 1");
            ps.setString(1, tab);
            rs = ps.executeQuery();
            if (rs.next()) {
                String owner = rs.getString(1);
                String tname = rs.getString(2);
                if (owner != null && tname != null) {
                    return new ObjRef(owner, tname);
                }
            }
        } finally {
            if (rs != null) {
                try {
                    rs.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
            if (ps != null) {
                try {
                    ps.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
        }
        // 无同义词时: V$FOO / GV$FOO → SYS.V_$FOO / SYS.GV_$FOO
        if (tab.startsWith("GV$") && tab.length() > 3) {
            return new ObjRef("SYS", "GV_$" + tab.substring(3));
        }
        if (tab.startsWith("V$") && tab.length() > 2) {
            return new ObjRef("SYS", "V_$" + tab.substring(2));
        }
        // 当前用户对象
        String user = currentUser();
        if (user != null && !user.isEmpty()) {
            return new ObjRef(user, tab);
        }
        return new ObjRef(null, tab);
    }

    private String currentUser() throws SQLException {
        Statement st = null;
        ResultSet rs = null;
        try {
            st = session.connection().createStatement();
            rs = st.executeQuery("SELECT USER FROM DUAL");
            if (rs.next()) {
                return rs.getString(1);
            }
            return null;
        } finally {
            if (rs != null) {
                try {
                    rs.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
            if (st != null) {
                try {
                    st.close();
                } catch (SQLException ignored) {
                    // ignore
                }
            }
        }
    }

    private void printDescribeHeader() {
        out.println("Name                           Null?    Type");
        out.println("------------------------------ -------- ----------------------------");
    }

    private void printDescribeRow(String col, String nullable, String type) {
        out.printf("%-30s %-8s %s%n",
                col == null ? "?" : col,
                nullable == null ? "" : nullable,
                type == null ? "?" : type);
    }

    private static boolean isNotNullFlag(String nullFlag) {
        if (nullFlag == null) {
            return false;
        }
        String u = nullFlag.trim().toUpperCase(Locale.ROOT);
        return "N".equals(u) || "NO".equals(u);
    }

    private static Integer getNullableInt(ResultSet rs, int idx) throws SQLException {
        int v = rs.getInt(idx);
        if (rs.wasNull()) {
            return null;
        }
        return v;
    }

    private static String formatType(String dataType, int length, Integer precision, Integer scale) {
        if (dataType == null || dataType.isEmpty()) {
            return "?";
        }
        String u = dataType.toUpperCase(Locale.ROOT);
        if (u.contains("CHAR") || "RAW".equals(u) || "VARCHAR".equals(u) || "VARCHAR2".equals(u)
                || "NCHAR".equals(u) || "NVARCHAR".equals(u) || "NVARCHAR2".equals(u)) {
            if (length > 0) {
                return dataType + "(" + length + ")";
            }
            return dataType;
        }
        if (u.contains("NUMBER") || "FLOAT".equals(u) || "BINARY_INTEGER".equals(u)
                || "BINARY_FLOAT".equals(u) || "BINARY_DOUBLE".equals(u)) {
            if (precision != null && precision > 0) {
                if (scale != null && scale > 0) {
                    return dataType + "(" + precision + "," + scale + ")";
                }
                // BINARY_INTEGER 等精度占位(如 38)不强制加括号, 保持与常见 DESC 接近
                if (!"BINARY_INTEGER".equals(u) && !"BINARY_FLOAT".equals(u)
                        && !"BINARY_DOUBLE".equals(u)) {
                    return dataType + "(" + precision + ")";
                }
            }
            return dataType;
        }
        return dataType;
    }

    private static final class ObjRef {
        final String owner;
        final String table;

        ObjRef(String owner, String table) {
            this.owner = owner;
            this.table = table;
        }
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

    private static String firstNonNull(String a, String b) {
        if (a != null) {
            return a;
        }
        return b;
    }
}
