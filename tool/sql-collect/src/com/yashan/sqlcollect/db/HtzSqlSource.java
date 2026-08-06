package com.yashan.sqlcollect.db;

import com.yashan.sqlcollect.model.BindValue;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;

/**
 * 仅从登录用户 HTZ_GV_* 备份表读游标与绑定; 禁止查询 gv$/v$sql*.
 */
public final class HtzSqlSource implements SqlDataSource {

    private final String owner;
    private final String tSql;
    private final String tBind;

    public HtzSqlSource(String jdbcUser) {
        this.owner = HtzTables.normalizeOwner(jdbcUser);
        this.tSql = HtzTables.qname(owner, HtzTables.GV_SQL);
        this.tBind = HtzTables.qname(owner, HtzTables.GV_BIND);
    }

    /** 单测: exists 查询文本. */
    String existsSql() {
        return "SELECT 1 FROM " + tSql + " WHERE sql_id = ? AND ROWNUM = 1";
    }

    /**
     * 单测: bind 表按 last_captured 选 child.
     * 仅排除未 capture (last_captured 空 / WAS_CAPTURED=NO); 不做 value_string 长度判断.
     */
    String pickChildBindLastCapturedSql() {
        return "SELECT child_number, NVL(inst_id,1), last_captured"
                + " FROM " + tBind
                + " WHERE sql_id = ? AND " + SqlLookup.PRED_CAPTURED
                + " ORDER BY last_captured DESC NULLS LAST, child_number";
    }

    /** 单测: bind 表无 last_captured 列时按 collect_time 选 child (旧表回退). */
    String pickChildBindCollectTimeSql() {
        return "SELECT child_number, NVL(inst_id,1), collect_time"
                + " FROM " + tBind
                + " WHERE sql_id = ?"
                + " ORDER BY collect_time DESC NULLS LAST, child_number";
    }

    /** 单测: HTZ_GV_SQL 按 collect_time 回退选游标. */
    String pickChildFromSqlFallbackSql() {
        return "SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext, hash_value FROM ("
                + " SELECT parsing_schema_name, child_number, inst_id, sql_fulltext, hash_value"
                + "   FROM " + tSql
                + "  WHERE sql_id = ?"
                + "  ORDER BY collect_time DESC NULLS LAST, child_number"
                + ") WHERE ROWNUM = 1";
    }

    /** 单测: 已知 child/inst 取游标文本. */
    String loadCursorByChildSql() {
        return "SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext, hash_value"
                + " FROM " + tSql
                + " WHERE sql_id = ? AND child_number = ? AND NVL(inst_id,1) = ?"
                + " AND ROWNUM = 1";
    }

    /** 单测: 按 sql_id+child+inst 加载绑定. */
    String loadBindsSql() {
        return "SELECT position, name, datatype_string, value_string FROM " + tBind
                + " WHERE sql_id = ? AND child_number = ? AND NVL(inst_id,1) = ?"
                + " AND " + SqlLookup.PRED_CAPTURED
                + " ORDER BY " + SqlLookup.ORDER_BIND_ROWS;
    }

    @Override
    public CursorSnapshot pickCursor(Connection c, String sqlId) throws SQLException {
        if (c == null || sqlId == null || sqlId.trim().isEmpty()) {
            return null;
        }
        String id = sqlId.trim();
        CapturedChild prefer = pickBestChildFromBind(c, id);
        if (prefer != null) {
            CursorSnapshot snap = loadCursorByChild(c, id, prefer.childNumber, prefer.instId);
            if (snap != null && snap.sqlText != null && !snap.sqlText.isEmpty()) {
                snap.sqlId = id;
                return snap;
            }
        }
        return loadCursorFallback(c, id);
    }

    @Override
    public List<BindValue> loadBinds(Connection c, String sqlId, int child, int instId)
            throws SQLException {
        if (c == null || sqlId == null) {
            return new ArrayList<BindValue>();
        }
        List<BindValue> raw = queryBinds(c, loadBindsSql(), sqlId, child, instId);
        if (raw.isEmpty()) {
            raw = queryBinds(c, bindCollectTimeSql(), sqlId, child, instId);
        }
        return dedupeByPosition(raw);
    }

    @Override
    public boolean exists(Connection c, String sqlId) throws SQLException {
        if (c == null || sqlId == null || sqlId.trim().isEmpty()) {
            return false;
        }
        try (PreparedStatement ps = c.prepareStatement(existsSql())) {
            ps.setQueryTimeout(30);
            ps.setString(1, sqlId.trim());
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next();
            }
        }
    }

    /** bind 表无 last_captured 列时的 loadBinds 回退 SQL (旧表). */
    private String bindCollectTimeSql() {
        return "SELECT position, name, datatype_string, value_string FROM " + tBind
                + " WHERE sql_id = ? AND child_number = ? AND NVL(inst_id,1) = ?"
                + " ORDER BY collect_time DESC NULLS LAST,"
                + " CASE WHEN name IS NOT NULL AND TRIM(name) <> '?' THEN 0 ELSE 1 END,"
                + " position";
    }

    private static final class CapturedChild {
        int childNumber;
        int instId = 1;
        long capturedMs;
    }

    private CapturedChild pickBestChildFromBind(Connection c, String sqlId) throws SQLException {
        CapturedChild ch = scanLatestChild(c, pickChildBindLastCapturedSql(), sqlId, true);
        if (ch != null) {
            return ch;
        }
        return scanLatestChild(c, pickChildBindCollectTimeSql(), sqlId, false);
    }

    private CapturedChild scanLatestChild(Connection c, String sql, String sqlId, boolean lastCaptured)
            throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, sqlId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    return null;
                }
                CapturedChild ch = new CapturedChild();
                ch.childNumber = rs.getInt(1);
                ch.instId = rs.getInt(2);
                Timestamp ts = rs.getTimestamp(3);
                ch.capturedMs = ts == null ? 1L : ts.getTime();
                return ch;
            }
        } catch (SQLException e) {
            if (lastCaptured) {
                return null;
            }
            throw e;
        }
    }

    private CursorSnapshot loadCursorByChild(Connection c, String sqlId, int child, int instId)
            throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(loadCursorByChildSql())) {
            ps.setString(1, sqlId);
            ps.setInt(2, child);
            ps.setInt(3, instId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    return null;
                }
                return fillSnapshot(sqlId, rs);
            }
        }
    }

    private CursorSnapshot loadCursorFallback(Connection c, String sqlId) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(pickChildFromSqlFallbackSql())) {
            ps.setString(1, sqlId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    return null;
                }
                CursorSnapshot snap = fillSnapshot(sqlId, rs);
                if (snap.sqlText == null || snap.sqlText.isEmpty()) {
                    return null;
                }
                return snap;
            }
        }
    }

    private CursorSnapshot fillSnapshot(String sqlId, ResultSet rs) throws SQLException {
        CursorSnapshot snap = new CursorSnapshot();
        snap.sqlId = sqlId == null ? "" : sqlId.trim();
        snap.schema = rs.getString(1);
        if (snap.schema == null) {
            snap.schema = "";
        }
        snap.childNumber = rs.getInt(2);
        snap.instId = rs.getInt(3);
        snap.sqlText = JdbcSession.readClob(rs.getClob(4));
        if (snap.sqlText == null) {
            snap.sqlText = "";
        }
        long hv = rs.getLong(5);
        if (!rs.wasNull()) {
            snap.hashValue = hv;
        }
        snap.sqlLen = snap.sqlText.length();
        return snap;
    }

    private List<BindValue> queryBinds(Connection c, String sql, String sqlId, int child, int instId)
            throws SQLException {
        List<BindValue> binds = new ArrayList<BindValue>();
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, sqlId);
            ps.setInt(2, child);
            ps.setInt(3, instId);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    binds.add(bindRow(rs));
                }
            }
        } catch (SQLException e) {
            if (sql.contains("last_captured")) {
                return binds;
            }
            throw e;
        }
        return binds;
    }

    private static BindValue bindRow(ResultSet rs) throws SQLException {
        BindValue b = new BindValue();
        b.position = rs.getInt(1);
        String name = rs.getString(2);
        b.name = name == null ? "" : name;
        String dt = rs.getString(3);
        b.datatype = dt == null ? "" : dt;
        String val = rs.getString(4);
        b.value = val == null ? "" : val;
        return b;
    }

    /** 同 position 只留第一条 (调用方须已按 last_captured/collect_time 排序). */
    private static List<BindValue> dedupeByPosition(List<BindValue> raw) {
        List<BindValue> out = new ArrayList<BindValue>();
        if (raw == null || raw.isEmpty()) {
            return out;
        }
        HashSet<Integer> seen = new HashSet<Integer>();
        for (BindValue b : raw) {
            if (seen.add(Integer.valueOf(b.position))) {
                out.add(b);
            }
        }
        Collections.sort(out, new Comparator<BindValue>() {
            public int compare(BindValue a, BindValue b) {
                return Integer.compare(a.position, b.position);
            }
        });
        return out;
    }
}
