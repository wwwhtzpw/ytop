package com.yashan.yjdbc.cmd.sqlmap.support.db;

import com.yashan.yjdbc.cmd.sqlmap.support.config.JdbcConfig;
import com.yashan.yjdbc.cmd.sqlmap.support.log.DualLogger;

import java.io.Reader;
import java.sql.Clob;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * 基于会话连接的 JDBC 包装; close 不断开底层连接.
 */
public class JdbcSession implements AutoCloseable {

    private final Connection connection;
    private final DualLogger log;
    private final JdbcPool pool;

    public JdbcSession(JdbcConfig cfg, DualLogger log, JdbcPool pool) throws SQLException {
        this.log = log;
        this.pool = pool;
        if (pool == null) {
            throw new SQLException("session-pinned JdbcPool required");
        }
        String url = cfg == null ? "" : cfg.jdbcUrl;
        String user = cfg == null ? "" : cfg.user;
        String pass = cfg == null ? "" : cfg.password;
        this.connection = pool.borrow(url, user, pass);
        if (cfg != null && cfg.schemaViaAlter
                && cfg.currentSchema != null && !cfg.currentSchema.trim().isEmpty()) {
            setCurrentSchema(cfg.currentSchema.trim());
        }
    }

    public Connection getConnection() {
        return connection;
    }

    public JdbcPool getPool() {
        return pool;
    }

    public void setCurrentSchema(String schema) throws SQLException {
        if (schema == null || schema.isEmpty()) {
            return;
        }
        String q = schema.replace("\"", "\"\"");
        String sql = "ALTER SESSION SET CURRENT_SCHEMA = \"" + q + "\"";
        if (log != null) {
            log.logStep("alter_session", "CURRENT_SCHEMA=" + schema);
        }
        Statement st = connection.createStatement();
        try {
            st.execute(sql);
        } finally {
            st.close();
        }
    }

    public static String readClob(Clob c) throws SQLException {
        if (c == null) {
            return "";
        }
        Reader r = c.getCharacterStream();
        StringBuilder sb = new StringBuilder();
        char[] buf = new char[8192];
        try {
            int n;
            while ((n = r.read(buf)) >= 0) {
                sb.append(buf, 0, n);
            }
            r.close();
        } catch (java.io.IOException e) {
            throw new SQLException("read clob failed", e);
        }
        return sb.toString();
    }

    public void execute(String sql) throws SQLException {
        Statement st = connection.createStatement();
        try {
            st.execute(sql);
        } finally {
            st.close();
        }
    }

    @Override
    public void close() {
        // 代理 close 为空操作; 不关闭池
    }
}
