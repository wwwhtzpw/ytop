package com.yashan.sqlcollect.db;

/**
 * gv$/v$sql 游标快照: sql 文本与 child/inst 定位信息.
 */
public final class CursorSnapshot {

    public String sqlId = "";
    public String schema = "";
    public String sqlText = "";
    public int childNumber;
    public int instId = 1;
    public long hashValue;
    public int sqlLen;

    public CursorSnapshot() {
    }

    /** 从 {@link SqlLookup.SqlTextInfo} 构造; sqlId 由调用方填入. */
    public static CursorSnapshot fromSqlTextInfo(String sqlId, SqlLookup.SqlTextInfo info) {
        CursorSnapshot snap = new CursorSnapshot();
        if (sqlId != null) {
            snap.sqlId = sqlId.trim();
        }
        if (info == null) {
            return snap;
        }
        snap.schema = info.schema == null ? "" : info.schema;
        snap.sqlText = info.sqlText == null ? "" : info.sqlText;
        snap.childNumber = info.childNumber;
        snap.instId = info.instId;
        if (info.hashValue != null) {
            snap.hashValue = info.hashValue.longValue();
        }
        snap.sqlLen = snap.sqlText.length();
        return snap;
    }
}
