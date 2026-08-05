package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.db.LiveSqlSource;
import com.yashan.sqlcollect.db.SqlDataSource;
import com.yashan.sqlcollect.log.DualLogger;

import java.io.IOException;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

/**
 * 报告正文由 {@link JdbcReportBuilder} 生成; 落盘路径由 CollectCommand 分流:
 * 有效报告 → outdir/reports/; 跳过/不完整 → outdir/skipped/.
 */
public class ReportWriter {

    /** 报告采集默认超时秒数 (对齐 Python YASQL_TIMEOUT=600) */
    public static final int DEFAULT_REPORT_TIMEOUT_SEC = 600;

    private final DualLogger log;
    private final JdbcReportBuilder builder;
    private int reportTimeoutSec = DEFAULT_REPORT_TIMEOUT_SEC;
    private SqlDataSource reportSrc = LiveSqlSource.INSTANCE;
    private boolean htzSections;
    private String htzOwner;

    public ReportWriter() {
        this(null);
    }

    public ReportWriter(DualLogger log) {
        this.log = log;
        this.builder = new JdbcReportBuilder(log);
    }

    public void setReportTimeoutSec(int sec) {
        this.reportTimeoutSec = sec < 0 ? 0 : sec;
    }

    public int getReportTimeoutSec() {
        return reportTimeoutSec;
    }

    /** 是否追加 EXPLAIN PLAN 段 (默认 false; 仅 SELECT/WITH CTE). */
    public void setExplainPlan(boolean on) {
        builder.setExplainPlan(on);
    }

    /**
     * 报告数据源与段改写开关.
     * @param src   FILE→Live; BOTH→Htz
     * @param htz   true 时 PLAN/sqlarea 改写为 HTZ 表
     * @param owner HTZ schema; htz 时必填
     */
    public void setReportDataSource(SqlDataSource src, boolean htz, String owner) {
        this.reportSrc = src == null ? LiveSqlSource.INSTANCE : src;
        this.htzSections = htz;
        this.htzOwner = owner;
    }

    /**
     * 是否仍在性能视图中: 只要 gv$/v$sql 有该 sql_id 即放行.
     * sqlstats 缺失仅记日志 (统计段可能稀疏, 不跳过报告).
     */
    public boolean sqlIdPresentForReport(JdbcSession session, String sqlId) throws SQLException {
        Connection c = session.getConnection();
        boolean inSql = existsSqlId(c, sqlId, "gv$sql") || existsSqlId(c, sqlId, "v$sql");
        Boolean inStats = null;
        try {
            inStats = Boolean.valueOf(
                    existsSqlId(c, sqlId, "gv$sqlstats") || existsSqlId(c, sqlId, "v$sqlstats"));
        } catch (SQLException e) {
            if (log != null) {
                log.logDbg("sqlstats presence check failed: " + e.getMessage());
            }
        }
        if (log != null) {
            log.logDbg("sql_id=" + sqlId + " in_sql=" + inSql
                    + " in_sqlstats=" + (inStats == null ? "n/a" : inStats));
        }
        return inSql;
    }

    private static boolean existsSqlId(Connection c, String sqlId, String view) throws SQLException {
        String v = view == null ? "" : view.trim().toLowerCase();
        if (!"gv$sql".equals(v) && !"v$sql".equals(v)
                && !"gv$sqlstats".equals(v) && !"v$sqlstats".equals(v)) {
            throw new SQLException("unsupported view: " + view);
        }
        String sql = "SELECT 1 FROM " + v + " WHERE sql_id = ? AND ROWNUM = 1";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setQueryTimeout(30);
            ps.setString(1, sqlId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next();
            }
        }
    }

    public String buildReport(JdbcSession session, String sqlId) throws SQLException, IOException {
        return builder.build(session, sqlId, reportTimeoutSec, reportSrc, htzSections, htzOwner);
    }

    public boolean isValidReport(String report) {
        if (report == null) {
            return false;
        }
        if (report.contains("===== ORIGINAL SQL =====")) {
            return true;
        }
        if (report.contains("No SQL found in V$SQL")) {
            return false;
        }
        if (report.contains("[ERROR] report timeout")) {
            return false;
        }
        if (report.startsWith("# skipped:")) {
            return false;
        }
        return false;
    }

    /** 跳过报告时的短 stub 内容 */
    public static String skippedStub(String sqlId, String reason) {
        return "# skipped: sql_id=" + sqlId + " " + reason + "\n";
    }
}
