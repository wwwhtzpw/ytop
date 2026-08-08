package com.yashan.yjdbc;

import com.yashan.yjdbc.cli.Args;
import com.yashan.yjdbc.config.SessionConfig;
import com.yashan.yjdbc.db.JdbcSession;
import com.yashan.yjdbc.shell.Repl;

import java.util.Arrays;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * yjdbc 入口: shell 子命令.
 */
public final class Main {
    private Main() {
    }

    public static void main(String[] args) {
        quietYashanJdbcJul();
        if (args.length == 0 || "help".equals(args[0]) || "-h".equals(args[0])
                || "--help".equals(args[0])) {
            usage();
            return;
        }
        if ("shell".equals(args[0])) {
            String[] rest = Arrays.copyOfRange(args, 1, args.length);
            runShell(rest);
            return;
        }
        System.err.println("Unknown command: " + args[0]);
        usage();
        System.exit(2);
    }

    private static void runShell(String[] args) {
        SessionConfig cfg = Args.parseShell(args);
        JdbcSession session = null;
        try {
            session = JdbcSession.open(cfg);
        } catch (Exception e) {
            System.err.println("Connection failed: " + e.getMessage());
            System.exit(1);
            return;
        }
        try {
            int code = new Repl(session, System.out, System.err).run();
            System.exit(code);
        } finally {
            session.close();
        }
    }

    private static void usage() {
        System.out.println("Usage: yjdbc <command> [options]");
        System.out.println();
        Args.usage();
        System.out.println();
        System.out.println("Client: @/@@/START ?path #path COLUMN DEFINE ACCEPT DESC PROMPT SPOOL");
        System.out.println("        SHOW CLEAR EXEC WHENEVER EXIT/QUIT VARIABLE PRINT TTITLE BTITLE");
        System.out.println("        BREAK COMPUTE LIST RUN CHANGE DEL APPEND INPUT GET SAVE PAUSE");
        System.out.println("        HOST CONNECT");
        System.out.println("?path = view script; #path = edit temp copy then run if changed");
        System.out.println("COLUMN: FORMAT An|999 NOPRINT JUSTIFY TRUNCATED|WRAPPED NEW_VALUE OLD_VALUE");
        System.out.println("SET: ECHO FEEDBACK HEADING PAGESIZE LINESIZE TIMING VERIFY DEFINE ESCAPE");
        System.out.println("     NULL TERMOUT AUTOCOMMIT SERVEROUTPUT VERTICAL DISPLAY BINDVAR HOST");
        System.out.println("     LONG LONGCHUNKSIZE ARRAYSIZE TRIMOUT TRIMSPOOL COLSEP UNDERLINE");
        System.out.println("     WRAP NUMWIDTH NUMFORMAT");
        System.out.println("SPOOL file [CREATE|REPLACE|APPEND]  (default REPLACE)");
        System.out.println("End SQL with ; or \\G (vertical rows like MySQL); empty / re-runs last SQL");
        System.out.println("Substitution: &var  &&var  &1  DEFINE name=value");
        System.out.println("@script.sql arg1 arg2  ->  &1 &2 (quoted args ok)");
        System.out.println("SET BINDVAR ON: &var -> JDBC ? binds (default OFF = literal)");
        System.out.println("WHENEVER SQLERROR|OSERROR EXIT|CONTINUE [status] [COMMIT|ROLLBACK|NONE]");
        System.out.println("EXIT [SUCCESS|FAILURE|WARNING|SQL.SQLCODE|n] [COMMIT|ROLLBACK|NONE]");
    }

    /** 压制 YashanDB JDBC 驱动 JUL INFO 噪音; WARNING 及以上仍可见. */
    static void quietYashanJdbcJul() {
        try {
            Logger.getLogger("com.yashandb").setLevel(Level.WARNING);
            Logger.getLogger("com.yashandb.log").setLevel(Level.WARNING);
            Logger.getLogger("com.yashandb.jdbc").setLevel(Level.WARNING);
        } catch (Exception ignored) {
            // JUL 不可用时忽略
        }
    }
}
