package com.yashan.yjdbc.slash;

import com.yashan.yjdbc.db.DbFacade;
import com.yashan.yjdbc.db.JdbcSession;
import com.yashan.yjdbc.db.SessionDbFacade;
import com.yashan.yjdbc.exec.SqlExecutor;

import java.io.File;
import java.io.PrintStream;

/**
 * 斜杠命令运行上下文.
 */
public final class SlashContext {
    private final JdbcSession session;
    private final SqlExecutor executor;
    private final PrintStream out;
    private final PrintStream err;
    private final File cwd;
    private final DbFacade db;
    private final SlashRegistry registry;

    public SlashContext(JdbcSession session, SqlExecutor executor,
                        PrintStream out, PrintStream err, SlashRegistry registry) {
        this.session = session;
        this.executor = executor;
        this.out = out;
        this.err = err;
        this.cwd = new File(System.getProperty("user.dir"));
        this.db = new SessionDbFacade(session, out, err);
        this.registry = registry;
    }

    public JdbcSession session() {
        return session;
    }

    public SqlExecutor executor() {
        return executor;
    }

    public PrintStream out() {
        return out;
    }

    public PrintStream err() {
        return err;
    }

    public File cwd() {
        return cwd;
    }

    public DbFacade db() {
        return db;
    }

    public SlashRegistry registry() {
        return registry;
    }
}
