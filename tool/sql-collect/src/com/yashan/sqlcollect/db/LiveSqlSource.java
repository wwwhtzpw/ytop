package com.yashan.sqlcollect.db;

import com.yashan.sqlcollect.model.BindValue;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;

/**
 * 从 live gv$/v$ 读取游标与绑定; 委托 {@link SqlLookup} 选 child / 取全文 / 取 bind.
 */
public final class LiveSqlSource implements SqlDataSource {

    public static final LiveSqlSource INSTANCE = new LiveSqlSource();

    private LiveSqlSource() {
    }

    @Override
    public CursorSnapshot pickCursor(Connection c, String sqlId) throws SQLException {
        if (c == null || sqlId == null || sqlId.trim().isEmpty()) {
            return null;
        }
        String id = sqlId.trim();
        // pickBestCapturedChild + by-child 全文已在 loadSqlText 内; 失败时回退 gv$/v$ 排序
        SqlLookup.SqlTextInfo info = SqlLookup.loadSqlText(c, id, null);
        if (info == null || !info.found) {
            return null;
        }
        return CursorSnapshot.fromSqlTextInfo(id, info);
    }

    @Override
    public List<BindValue> loadBinds(Connection c, String sqlId, int child, int instId)
            throws SQLException {
        return SqlLookup.loadBinds(c, sqlId, child, instId, null);
    }

    @Override
    public boolean exists(Connection c, String sqlId) throws SQLException {
        if (c == null || sqlId == null || sqlId.trim().isEmpty()) {
            return false;
        }
        String id = sqlId.trim();
        if (existsInView(c, id, "gv$sql")) {
            return true;
        }
        return existsInView(c, id, "v$sql");
    }

    /** 与 {@link com.yashan.sqlcollect.collect.ReportWriter} existsSqlId 同语义. */
    private static boolean existsInView(Connection c, String sqlId, String view) throws SQLException {
        String v = view == null ? "" : view.trim().toLowerCase();
        if (!"gv$sql".equals(v) && !"v$sql".equals(v)) {
            throw new SQLException("unsupported view: " + view);
        }
        String sql = "SELECT 1 FROM " + v + " WHERE sql_id = ? AND ROWNUM = 1";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setQueryTimeout(30);
            ps.setString(1, sqlId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next();
            }
        } catch (SQLException e) {
            // gv$ 不可用时回退 v$ (exists 由调用方串联)
            if ("gv$sql".equals(v)) {
                return false;
            }
            throw e;
        }
    }
}
