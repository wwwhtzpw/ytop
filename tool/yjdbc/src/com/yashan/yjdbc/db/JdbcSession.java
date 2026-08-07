package com.yashan.yjdbc.db;

import com.yashan.yjdbc.config.SessionConfig;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;

/**
 * JDBC 连接会话; 默认 autocommit=false.
 */
public final class JdbcSession implements AutoCloseable {
    private Connection conn;
    private final SessionConfig cfg;

    private JdbcSession(Connection conn, SessionConfig cfg) {
        this.conn = conn;
        this.cfg = cfg;
    }

    public static JdbcSession open(SessionConfig cfg) throws SQLException {
        Connection c = DriverManager.getConnection(cfg.url, cfg.user, cfg.password);
        c.setAutoCommit(cfg.autoCommit);
        return new JdbcSession(c, cfg);
    }

    public Connection connection() {
        return conn;
    }

    public SessionConfig config() {
        return cfg;
    }

    /** CONNECT: 关闭旧连接并按 cfg 中 URL/用户/口令重连. */
    public void reconnect() throws SQLException {
        Connection old = conn;
        Connection c = DriverManager.getConnection(cfg.url, cfg.user, cfg.password);
        c.setAutoCommit(cfg.autoCommit);
        conn = c;
        if (old != null) {
            try {
                old.close();
            } catch (SQLException ignored) {
                // ignore
            }
        }
    }

    @Override
    public void close() {
        if (conn != null) {
            try {
                conn.close();
            } catch (SQLException ignored) {
                // ignore
            }
            conn = null;
        }
    }
}
