package com.yashan.yjdbc.cmd.sqlmap.support.config;

/**
 * sqlmap 用最小 JDBC 配置 (会话模式: 不读 ini).
 */
public final class JdbcConfig {
    public String jdbcUrl = "";
    public String user = "";
    public String password = "";
    public boolean schemaViaAlter;
    public String currentSchema = "";
}
