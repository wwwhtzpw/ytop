package com.yashan.yjdbc.db;

import java.io.PrintStream;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * 基于当前 JdbcSession 的 DbFacade.
 */
public final class SessionDbFacade implements DbFacade {
    private final JdbcSession session;
    private final PrintStream out;
    private final PrintStream err;

    public SessionDbFacade(JdbcSession session, PrintStream out, PrintStream err) {
        this.session = session;
        this.out = out;
        this.err = err;
    }

    @Override
    public Connection connection() throws SQLException {
        return session.connection();
    }

    @Override
    public void setCurrentSchema(String schema, boolean viaAlter) throws SQLException {
        if (schema == null || schema.trim().isEmpty()) {
            return;
        }
        String sch = schema.trim();
        if (!viaAlter) {
            // 无独立 map 连接时统一 ALTER SESSION
            viaAlter = true;
        }
        if (viaAlter) {
            Statement st = null;
            try {
                st = connection().createStatement();
                st.execute("ALTER SESSION SET CURRENT_SCHEMA = " + quoteIdent(sch));
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
    }

    private static String quoteIdent(String ident) {
        String u = ident.replace("\"", "\"\"");
        return "\"" + u + "\"";
    }

    @Override
    public PrintStream out() {
        return out;
    }

    @Override
    public PrintStream err() {
        return err;
    }
}
