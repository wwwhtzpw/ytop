package com.yashan.yjdbc.db;

import java.io.PrintStream;
import java.sql.Connection;
import java.sql.SQLException;

/**
 * 斜杠命令 / 业务模块用的薄 JDBC 门面; 不依赖 Repl.
 */
public interface DbFacade {
    Connection connection() throws SQLException;

    void setCurrentSchema(String schema, boolean viaAlter) throws SQLException;

    PrintStream out();

    PrintStream err();
}
