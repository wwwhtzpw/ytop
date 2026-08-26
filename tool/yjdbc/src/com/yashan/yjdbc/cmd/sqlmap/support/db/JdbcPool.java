package com.yashan.yjdbc.cmd.sqlmap.support.db;

import com.yashan.yjdbc.cmd.sqlmap.support.log.DualLogger;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.SQLException;

/**
 * 钉住当前会话连接: borrow 始终返回同一连接代理, close 不真正断开.
 */
public final class JdbcPool implements AutoCloseable {
    public static final int DEFAULT_MAX_IDLE_PER_USER = 4;

    private final Connection raw;
    private final DualLogger log;
    private final Connection proxy;

    public JdbcPool(Connection connection, DualLogger log) {
        this.raw = connection;
        this.log = log;
        this.proxy = wrap(connection);
    }

    public Connection borrow(String jdbcUrl, String user, String password) throws SQLException {
        if (raw == null || raw.isClosed()) {
            throw new SQLException("session connection unavailable");
        }
        return proxy;
    }

    private static Connection wrap(final Connection c) {
        return (Connection) Proxy.newProxyInstance(
                Connection.class.getClassLoader(),
                new Class<?>[]{Connection.class},
                new InvocationHandler() {
                    @Override
                    public Object invoke(Object proxy, Method method, Object[] args)
                            throws Throwable {
                        if ("close".equals(method.getName())) {
                            return null;
                        }
                        if ("isClosed".equals(method.getName())) {
                            return Boolean.valueOf(c.isClosed());
                        }
                        return method.invoke(c, args);
                    }
                });
    }

    @Override
    public void close() {
        // 不关闭会话连接
        if (log != null) {
            log.logDbg("jdbc pool close skipped (session-pinned)");
        }
    }
}
