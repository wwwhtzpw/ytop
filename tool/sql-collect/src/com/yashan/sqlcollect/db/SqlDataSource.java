package com.yashan.sqlcollect.db;

import com.yashan.sqlcollect.model.BindValue;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.List;

/**
 * SQL 游标与绑定数据来源 (live gv$/v$ 或 HTZ 备份, 由实现类决定).
 */
public interface SqlDataSource {

    /**
     * 按 sql_id 选取最佳 child 游标; 不在库中或无文本时返回 null.
     */
    CursorSnapshot pickCursor(Connection c, String sqlId) throws SQLException;

    /** 按 sql_id + child + inst 加载绑定 (gv$/v$/HTZ 择优). */
    List<BindValue> loadBinds(Connection c, String sqlId, int child, int instId) throws SQLException;

    /** sql_id 是否存在于 gv$/v$sql. */
    boolean exists(Connection c, String sqlId) throws SQLException;
}
