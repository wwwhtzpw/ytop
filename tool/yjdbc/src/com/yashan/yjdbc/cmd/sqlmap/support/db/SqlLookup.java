package com.yashan.yjdbc.cmd.sqlmap.support.db;

import com.yashan.yjdbc.cmd.sqlmap.support.model.BindValue;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/**
 * 从 gv$/v$sql 取 sql_fulltext / hash / schema; 绑定取自内存 capture 与 HTZ 备份表.
 * 对齐 sql.sql: 只认 last_captured IS NOT NULL; 选最新 last_captured 所在 child;
 * 同 child 多 ADDRESS 按 position 去重 (ORDER BY last_captured DESC 后取第一次).
 */
public final class SqlLookup {

    /** 绑定来源: AUTO=视图+备份混选; VIEW=仅 gv$/v$sql_bind_capture; BACKUP=仅 HTZ_GV_SQL_BIND_CAPTURE. */
    public enum BindSource {
        AUTO,
        VIEW,
        BACKUP
    }

    /**
     * 已真正捕获: 与 sql.sql 一致, 仅 last_captured 非空 (排除从未 capture 的占位行).
     */
    public static final String PRED_CAPTURED = "last_captured IS NOT NULL";

    /** 表别名 b. 上的真正捕获谓词. */
    public static final String PRED_B_CAPTURED = "b.last_captured IS NOT NULL";

    /** 计 filled: 与已捕获同义 (仅 last_captured; 不做 value_string 长度判断). */
    public static final String PRED_B_FILLED = PRED_B_CAPTURED;

    /**
     * 绑游标排序: 与 sql.sql 一致 — 最新捕获优先, 命名占位优先于 ?, 再按 position.
     * 去重时保留第一条 (= 最新).
     */
    public static final String ORDER_BIND_ROWS =
            "last_captured DESC NULLS LAST,"
                    + " CASE WHEN name IS NOT NULL AND TRIM(name) <> '?' THEN 0 ELSE 1 END,"
                    + " position";

    /**
     * gv$/v$sql 回退排序 (无相关子查询 COUNT, 避免性能问题).
     * 主路径已用 pickBestCapturedChild (last_captured); 此处仅 last_active.
     * 子查询内表别名须为 s.
     */
    public static final String ORDER_GV_PREFER_CAPTURED =
            "s.last_active_time DESC NULLS LAST,"
                    + " s.executions DESC NULLS LAST, s.child_number";

    /** v$sql 选 child 排序 (无 inst_id). 子查询内表别名须为 s. */
    public static final String ORDER_V_PREFER_CAPTURED =
            "s.last_active_time DESC NULLS LAST,"
                    + " s.executions DESC NULLS LAST, s.child_number";

    /** bind_capture 上 last_captured 最新的 child (先 gv$ 再 v$ 再 HTZ). filled 仅作日志. */
    public static final class CapturedChild {
        public int childNumber;
        public int instId = 1;
        /** 兼容旧日志字段: 选中时置 1 (表示有捕获). */
        public int filled;
        public String source = "";
        /** last_captured / collect_time 毫秒; 越大越新. */
        public long lastCapturedMs;
    }

    /**
     * 从内存 bind_capture (gv$/v$) 与备份表 HTZ_GV_SQL_BIND_CAPTURE 选 last_captured 最新的 child.
     * 对齐 sql.sql: 无相关子查询 / 无 filled 聚合.
     */
    public static CapturedChild pickBestCapturedChild(Connection c, String sqlId) {
        return pickBestCapturedChild(c, sqlId, BindSource.AUTO, null);
    }

    public static CapturedChild pickBestCapturedChild(Connection c, String sqlId, WarnOut warn) {
        return pickBestCapturedChild(c, sqlId, BindSource.AUTO, warn);
    }

    public static CapturedChild pickBestCapturedChild(Connection c, String sqlId, BindSource source,
                                                     WarnOut warn) {
        CapturedChild best = null;
        if (c == null || sqlId == null || sqlId.trim().isEmpty()) {
            return null;
        }
        BindSource src = source == null ? BindSource.AUTO : source;
        String id = sqlId.trim();
        if (src == BindSource.AUTO || src == BindSource.VIEW) {
            best = betterByTime(best, scanLatestCaptured(c,
                    "SELECT child_number, NVL(inst_id,1), last_captured"
                            + " FROM gv$sql_bind_capture"
                            + " WHERE sql_id = ? AND last_captured IS NOT NULL"
                            + " ORDER BY last_captured DESC NULLS LAST, child_number",
                    id, "gv$sql_bind_capture", warn));
            best = betterByTime(best, scanLatestCaptured(c,
                    "SELECT child_number, 1, last_captured"
                            + " FROM v$sql_bind_capture"
                            + " WHERE sql_id = ? AND last_captured IS NOT NULL"
                            + " ORDER BY last_captured DESC NULLS LAST, child_number",
                    id, "v$sql_bind_capture", warn));
        }
        if (src == BindSource.AUTO || src == BindSource.BACKUP) {
            for (String htz : htzBindTableCandidates(c)) {
                CapturedChild fromH = scanLatestCaptured(c,
                        "SELECT child_number, NVL(inst_id,1), last_captured"
                                + " FROM " + htz
                                + " WHERE sql_id = ? AND last_captured IS NOT NULL"
                                + " ORDER BY last_captured DESC NULLS LAST, child_number",
                        id, htz, null);
                if (fromH == null) {
                    // 旧备份表可能无 last_captured 列, 退回 collect_time (不按 value 长度过滤)
                    fromH = scanLatestCaptured(c,
                            "SELECT child_number, NVL(inst_id,1), collect_time"
                                    + " FROM " + htz
                                    + " WHERE sql_id = ?"
                                    + " ORDER BY collect_time DESC NULLS LAST, child_number",
                            id, htz + "(collect_time)", warn);
                }
                best = betterByTime(best, fromH);
            }
        }
        if (best == null || best.filled <= 0) {
            return null;
        }
        return best;
    }

    private static CapturedChild betterByTime(CapturedChild cur, CapturedChild cand) {
        if (cand == null || cand.filled <= 0) {
            return cur;
        }
        if (cur == null) {
            return cand;
        }
        if (cand.lastCapturedMs > cur.lastCapturedMs) {
            return cand;
        }
        if (cand.lastCapturedMs == cur.lastCapturedMs
                && cand.childNumber < cur.childNumber) {
            return cand;
        }
        return cur;
    }

    /**
     * 取 ORDER BY 后第一条 (最新 last_captured 所在 child).
     */
    private static CapturedChild scanLatestCaptured(Connection c, String sql, String sqlId,
                                                    String source, WarnOut warn) {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, sqlId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    return null;
                }
                CapturedChild ch = new CapturedChild();
                ch.childNumber = rs.getInt(1);
                ch.instId = rs.getInt(2);
                ch.filled = 1;
                ch.source = source;
                Timestamp ts = rs.getTimestamp(3);
                if (ts != null) {
                    ch.lastCapturedMs = ts.getTime();
                } else {
                    ch.lastCapturedMs = 1L; // 有行但无时间戳: 仍视为有效, 弱于有真实时间的
                }
                return ch;
            }
        } catch (SQLException e) {
            if (warn != null) {
                warn.warn(source + " pick-child: " + e.getMessage());
            }
            return null;
        }
    }

    /** 登录用户 schema 优先, 兼容历史 SYS.HTZ_*. */
    private static List<String> htzBindTableCandidates(Connection c) {
        List<String> out = new ArrayList<String>();
        try {
            String user = HtzTables.currentUser(c);
            if (user != null && !user.isEmpty()) {
                String q = HtzTables.qname(user, HtzTables.GV_BIND);
                if (HtzTables.tableExists(c, user, HtzTables.GV_BIND)) {
                    out.add(q);
                }
            }
        } catch (SQLException e) {
            // ignore
        }
        try {
            if (HtzTables.tableExists(c, "SYS", HtzTables.GV_BIND)) {
                String q = HtzTables.qname("SYS", HtzTables.GV_BIND);
                if (!out.contains(q)) {
                    out.add(q);
                }
            }
        } catch (SQLException e) {
            // ignore
        }
        return out;
    }

    public static final class SqlTextInfo {
        public String sqlText = "";
        public String schema = "";
        public int childNumber;
        public int instId = 1;
        public Long hashValue;
        public boolean found;
    }

    public interface WarnOut {
        void warn(String msg);
    }

    private SqlLookup() {
    }

    public static SqlTextInfo loadSqlText(Connection c, String sqlId, WarnOut warn) {
        SqlTextInfo info = new SqlTextInfo();
        if (c == null || sqlId == null || sqlId.trim().isEmpty()) {
            return info;
        }
        String id = sqlId.trim();
        // 主路径: 与 sql.sql 一致 — 先按 last_captured 选 child, 再取该 child 文本
        CapturedChild prefer = pickBestCapturedChild(c, id, warn);
        if (prefer != null) {
            SqlTextInfo byChild = loadSqlTextByChild(c, id, prefer.childNumber, prefer.instId, warn);
            if (byChild.found) {
                return byChild;
            }
        }
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext, hash_value FROM ("
                        + " SELECT s.parsing_schema_name, s.child_number, s.inst_id, s.sql_fulltext, s.hash_value"
                        + "   FROM gv$sql s WHERE s.sql_id = ?"
                        + "  ORDER BY DBMS_LOB.GETLENGTH(s.sql_fulltext) DESC NULLS LAST,"
                        + ORDER_GV_PREFER_CAPTURED
                        + ") WHERE ROWNUM = 1")) {
            ps.setString(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    fill(info, rs, true);
                    return info;
                }
            }
        } catch (SQLException e) {
            if (warn != null) {
                warn.warn("gv$sql " + e.getMessage());
            }
        }
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT parsing_schema_name, child_number, sql_fulltext, hash_value FROM ("
                        + " SELECT s.parsing_schema_name, s.child_number, s.sql_fulltext, s.hash_value"
                        + "   FROM v$sql s WHERE s.sql_id = ?"
                        + "  ORDER BY DBMS_LOB.GETLENGTH(s.sql_fulltext) DESC NULLS LAST,"
                        + ORDER_V_PREFER_CAPTURED
                        + ") WHERE ROWNUM = 1")) {
            ps.setString(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    fill(info, rs, false);
                }
            }
        } catch (SQLException e) {
            if (warn != null) {
                warn.warn("v$sql " + e.getMessage());
            }
        }
        return info;
    }

    private static SqlTextInfo loadSqlTextByChild(Connection c, String sqlId, int child, int instId,
                                                  WarnOut warn) {
        SqlTextInfo info = new SqlTextInfo();
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext, hash_value"
                        + " FROM gv$sql WHERE sql_id = ? AND child_number = ?"
                        + " AND NVL(inst_id,1) = ? AND ROWNUM = 1")) {
            ps.setString(1, sqlId);
            ps.setInt(2, child);
            ps.setInt(3, instId);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    fill(info, rs, true);
                    return info;
                }
            }
        } catch (SQLException e) {
            if (warn != null) {
                warn.warn("gv$sql by child: " + e.getMessage());
            }
        }
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT parsing_schema_name, child_number, sql_fulltext, hash_value"
                        + " FROM v$sql WHERE sql_id = ? AND child_number = ? AND ROWNUM = 1")) {
            ps.setString(1, sqlId);
            ps.setInt(2, child);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    fill(info, rs, false);
                    return info;
                }
            }
        } catch (SQLException e) {
            if (warn != null) {
                warn.warn("v$sql by child: " + e.getMessage());
            }
        }
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT parsing_schema_name, child_number, NVL(inst_id,1), sql_fulltext, hash_value"
                        + " FROM gv$sql WHERE sql_id = ? AND child_number = ? AND ROWNUM = 1")) {
            ps.setString(1, sqlId);
            ps.setInt(2, child);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    fill(info, rs, true);
                }
            }
        } catch (SQLException e) {
            if (warn != null) {
                warn.warn("gv$sql by child loose: " + e.getMessage());
            }
        }
        return info;
    }

    private static void fill(SqlTextInfo info, ResultSet rs, boolean withInst) throws SQLException {
        info.schema = rs.getString(1);
        info.childNumber = rs.getInt(2);
        int idx = 3;
        if (withInst) {
            info.instId = rs.getInt(idx++);
        } else {
            info.instId = 1;
        }
        info.sqlText = JdbcSession.readClob(rs.getClob(idx++));
        long hv = rs.getLong(idx);
        if (!rs.wasNull()) {
            info.hashValue = Long.valueOf(hv);
        }
        info.found = info.sqlText != null && !info.sqlText.isEmpty();
        if (info.sqlText == null) {
            info.sqlText = "";
        }
    }

    /**
     * 按 sql_id+child+inst 取绑定: gv$ / v$ / HTZ 都查, 返回 filled 最多的一侧.
     * 同一 child 多 ADDRESS: ORDER BY last_captured DESC 后按 position 去重 (只留最新).
     */
    public static List<BindValue> loadBinds(Connection c, String sqlId, int child, int instId,
                                            WarnOut warn) {
        return loadBinds(c, sqlId, child, instId, BindSource.AUTO, warn);
    }

    public static List<BindValue> loadBinds(Connection c, String sqlId, int child, int instId,
                                            BindSource source, WarnOut warn) {
        List<BindValue> best = new ArrayList<BindValue>();
        int bestFilled = -1;
        if (c == null || sqlId == null) {
            return best;
        }
        BindSource src = source == null ? BindSource.AUTO : source;
        if (src == BindSource.AUTO || src == BindSource.VIEW) {
            List<BindValue> fromGv = dedupeByPosition(loadBindsView(c,
                    "SELECT position, name, datatype_string, value_string FROM gv$sql_bind_capture"
                            + " WHERE sql_id = ? AND child_number = ? AND inst_id = ?"
                            + " AND " + PRED_CAPTURED
                            + " ORDER BY " + ORDER_BIND_ROWS,
                    sqlId, child, Integer.valueOf(instId), warn, "gv$sql_bind_capture"));
            // inst 对不上时放宽
            if (countFilled(fromGv) == 0) {
                fromGv = dedupeByPosition(loadBindsView(c,
                        "SELECT position, name, datatype_string, value_string FROM gv$sql_bind_capture"
                                + " WHERE sql_id = ? AND child_number = ?"
                                + " AND " + PRED_CAPTURED
                                + " ORDER BY " + ORDER_BIND_ROWS,
                        sqlId, child, null, warn, "gv$sql_bind_capture(loose)"));
            }
            List<BindValue> fromV = dedupeByPosition(loadBindsView(c,
                    "SELECT position, name, datatype_string, value_string FROM v$sql_bind_capture"
                            + " WHERE sql_id = ? AND child_number = ? AND " + PRED_CAPTURED
                            + " ORDER BY " + ORDER_BIND_ROWS,
                    sqlId, child, null, warn, "v$sql_bind_capture"));
            best = preferFilled(best, bestFilled, fromGv);
            bestFilled = countFilled(best);
            best = preferFilled(best, bestFilled, fromV);
            bestFilled = countFilled(best);
        }

        if (src == BindSource.AUTO || src == BindSource.BACKUP) {
            for (String htz : htzBindTableCandidates(c)) {
                List<BindValue> fromH = loadBindsHtzDedup(c, htz, sqlId, child, instId, warn);
                List<BindValue> pickH = preferFilled(best, bestFilled, fromH);
                if (pickH != best) {
                    best = pickH;
                    bestFilled = countFilled(best);
                }
            }
        }
        return best;
    }

    private static List<BindValue> preferFilled(List<BindValue> cur, int curFilled,
                                                List<BindValue> cand) {
        int f = countFilled(cand);
        if (f > curFilled) {
            return cand;
        }
        // 两侧 filled 都为 0 时不要用「空槽列表」挡住后续来源
        if (f == 0) {
            return cur;
        }
        if (cur.isEmpty() && !cand.isEmpty()) {
            return cand;
        }
        return cur;
    }

    /**
     * 同 position 只留第一条 (调用方须已按 last_captured DESC / 命名优先排序).
     * 对齐 sql.sql v_pos_seen; 去重后按 position 升序便于 ? 顺序改写.
     */
    private static List<BindValue> dedupeByPosition(List<BindValue> raw) {
        List<BindValue> out = new ArrayList<BindValue>();
        if (raw == null || raw.isEmpty()) {
            return out;
        }
        java.util.HashSet<Integer> seen = new java.util.HashSet<Integer>();
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

    private static List<BindValue> loadBindsView(Connection c, String sql, String sqlId, int child,
                                                 Integer instId, WarnOut warn, String label) {
        List<BindValue> binds = new ArrayList<BindValue>();
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, sqlId);
            ps.setInt(2, child);
            if (instId != null) {
                ps.setInt(3, instId.intValue());
            }
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    binds.add(row(rs));
                }
            }
        } catch (SQLException e) {
            if (warn != null) {
                warn.warn(label + " " + e.getMessage());
            }
        }
        return binds;
    }

    private static List<BindValue> loadBindsHtzDedup(Connection c, String htzTable, String sqlId,
                                                     int child, int instId, WarnOut warn) {
        List<BindValue> raw = new ArrayList<BindValue>();
        String q = "SELECT position, name, datatype_string, value_string, collect_time FROM "
                + htzTable
                + " WHERE sql_id = ? AND child_number = ? AND NVL(inst_id,1) = ?"
                + " AND " + PRED_CAPTURED
                + " ORDER BY last_captured DESC NULLS LAST,"
                + " CASE WHEN name IS NOT NULL AND TRIM(name) <> '?' THEN 0 ELSE 1 END,"
                + " position";
        try (PreparedStatement ps = c.prepareStatement(q)) {
            ps.setString(1, sqlId);
            ps.setInt(2, child);
            ps.setInt(3, instId);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    raw.add(row(rs));
                }
            }
        } catch (SQLException e) {
            // 无 last_captured 列的旧表: 退回 collect_time (不做 value 长度判断)
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT position, name, datatype_string, value_string FROM " + htzTable
                            + " WHERE sql_id = ? AND child_number = ? AND NVL(inst_id,1) = ?"
                            + " ORDER BY collect_time DESC NULLS LAST,"
                            + " CASE WHEN name IS NOT NULL AND TRIM(name) <> '?' THEN 0 ELSE 1 END,"
                            + " position")) {
                ps.setString(1, sqlId);
                ps.setInt(2, child);
                ps.setInt(3, instId);
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        raw.add(row(rs));
                    }
                }
            } catch (SQLException e2) {
                if (warn != null) {
                    warn.warn(htzTable + " " + e2.getMessage());
                }
                return dedupeByPosition(raw);
            }
        }
        return dedupeByPosition(raw);
    }

    private static int countFilled(List<BindValue> binds) {
        int n = 0;
        if (binds == null) {
            return 0;
        }
        for (BindValue b : binds) {
            if (b.value != null && !b.value.isEmpty() && !"\\N".equals(b.value)) {
                n++;
            }
        }
        return n;
    }

    /** 仅按 sql_id: last_captured 最新的 child, 再取该 child 绑定; 全空则返回空列表. */
    public static List<BindValue> loadBindsBySqlId(Connection c, String sqlId, WarnOut warn) {
        return loadBindsBySqlId(c, sqlId, BindSource.AUTO, warn);
    }

    public static List<BindValue> loadBindsBySqlId(Connection c, String sqlId, BindSource source,
                                                   WarnOut warn) {
        BindSource src = source == null ? BindSource.AUTO : source;
        CapturedChild prefer = pickBestCapturedChild(c, sqlId, src, warn);
        if (prefer != null) {
            if (warn != null) {
                warn.warn("bind pick child=" + prefer.childNumber + " inst_id=" + prefer.instId
                        + " filled=" + prefer.filled + " src=" + prefer.source
                        + " last_captured_ms=" + prefer.lastCapturedMs
                        + " bind_source=" + src.name().toLowerCase(Locale.ROOT));
            }
            List<BindValue> binds = loadBinds(c, sqlId, prefer.childNumber, prefer.instId, src, warn);
            if (countFilled(binds) > 0 || !binds.isEmpty()) {
                return binds;
            }
        }
        // 回退: VIEW/AUTO 扫 v$sql_bind_capture; BACKUP 扫 HTZ 表 child 列表
        if (src == BindSource.AUTO || src == BindSource.VIEW) {
            try (PreparedStatement ps = c.prepareStatement(
                    // DISTINCT+ORDER BY child_number + bind 在部分 JDBC 上触发 YAS-04458; 用 GROUP BY
                    "SELECT child_number FROM v$sql_bind_capture WHERE sql_id = ?"
                            + " AND " + PRED_CAPTURED
                            + " GROUP BY child_number ORDER BY child_number")) {
                ps.setString(1, sqlId);
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        int ch = rs.getInt(1);
                        List<BindValue> binds = loadBinds(c, sqlId, ch, 1, src, warn);
                        if (countFilled(binds) > 0) {
                            if (warn != null) {
                                warn.warn("bind fallback child=" + ch
                                        + " filled=" + countFilled(binds)
                                        + " bind_source=" + src.name().toLowerCase(Locale.ROOT));
                            }
                            return binds;
                        }
                    }
                }
            } catch (SQLException e) {
                if (warn != null) {
                    String m = e.getMessage();
                    if (m == null || m.isEmpty()) {
                        m = String.valueOf(e);
                    }
                    warn.warn("bind fallback scan: " + m);
                }
            }
        }
        if (src == BindSource.BACKUP) {
            for (String htz : htzBindTableCandidates(c)) {
                try (PreparedStatement ps = c.prepareStatement(
                        "SELECT child_number FROM " + htz + " WHERE sql_id = ?"
                                + " AND " + PRED_CAPTURED
                                + " GROUP BY child_number ORDER BY child_number")) {
                    ps.setString(1, sqlId);
                    try (ResultSet rs = ps.executeQuery()) {
                        while (rs.next()) {
                            int ch = rs.getInt(1);
                            List<BindValue> binds = loadBinds(c, sqlId, ch, 1, src, warn);
                            if (countFilled(binds) > 0) {
                                if (warn != null) {
                                    warn.warn("bind backup fallback " + htz + " child=" + ch
                                            + " filled=" + countFilled(binds));
                                }
                                return binds;
                            }
                        }
                    }
                } catch (SQLException e) {
                    if (warn != null) {
                        warn.warn("bind backup fallback " + htz + ": " + e.getMessage());
                    }
                }
            }
        }
        return new ArrayList<BindValue>();
    }

    public static List<String[]> toReplayRows(List<BindValue> binds) {
        List<String[]> rows = new ArrayList<String[]>();
        if (binds == null) {
            return rows;
        }
        for (BindValue b : binds) {
            rows.add(new String[] {
                String.valueOf(b.position),
                b.datatype == null ? "" : b.datatype,
                b.value == null ? "" : b.value
            });
        }
        return rows;
    }

    private static BindValue row(ResultSet rs) throws SQLException {
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
}
