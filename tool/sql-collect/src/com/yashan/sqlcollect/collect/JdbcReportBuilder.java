package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.db.CursorSnapshot;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.db.LiveSqlSource;
import com.yashan.sqlcollect.db.SqlDataSource;
import com.yashan.sqlcollect.log.DualLogger;
import com.yashan.sqlcollect.model.BindValue;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.List;

/**
 * 纯 JDBC 报告构建.
 * ORIGINAL + LITERAL: 经 {@link SqlDataSource}; PLAN/sqlarea/AWR/objects: {@link SqlReportRunner}.
 */
public class JdbcReportBuilder {

    private final DualLogger log;
    private final SqlReportRunner selectSections;
    private boolean explainPlan;

    public JdbcReportBuilder(DualLogger log) {
        this.log = log;
        this.selectSections = new SqlReportRunner(log);
    }

    public void setExplainPlan(boolean explainPlan) {
        this.explainPlan = explainPlan;
    }

    /** 兼容: live 源, 不改写报告段. */
    public String build(JdbcSession session, String sqlId, int timeoutSec) throws SQLException {
        return build(session, sqlId, timeoutSec, LiveSqlSource.INSTANCE, false, null);
    }

    /**
     * @param src         游标/bind 来源 (FILE=Live, BOTH=Htz)
     * @param htzSections true 时 PLAN/sqlarea 走 HTZ 表名改写
     * @param htzOwner    HTZ schema; htzSections 时必填
     */
    public String build(JdbcSession session, String sqlId, int timeoutSec,
                        SqlDataSource src, boolean htzSections, String htzOwner) throws SQLException {
        if (src == null) {
            src = LiveSqlSource.INSTANCE;
        }
        long deadlineMs = timeoutSec <= 0
                ? Long.MAX_VALUE
                : System.currentTimeMillis() + (long) timeoutSec * 1000L;
        StringBuilder out = new StringBuilder();
        Connection c = session.getConnection();

        out.append("****************************************************************************************\n");
        out.append("ORIGINAL SQL / LITERAL SQL (JDBC native report)\n");
        out.append("****************************************************************************************\n");
        out.append("sql_id=").append(sqlId == null ? "" : sqlId).append('\n');
        if (htzSections) {
            out.append("data_source=HTZ_GV_*\n");
        }

        CursorSnapshot snap;
        try {
            snap = src.pickCursor(c, sqlId);
        } catch (SQLException e) {
            out.append("[ERROR] load cursor: ").append(e.getMessage()).append('\n');
            if (log != null) {
                log.logWarn("report load cursor failed sql_id=" + sqlId + ": " + e.getMessage());
            }
            return out.toString();
        }
        if (snap == null || snap.sqlText == null || snap.sqlText.isEmpty()) {
            out.append("No SQL found in V$SQL for sql_id=").append(sqlId).append('\n');
            return out.toString();
        }

        out.append("===== ORIGINAL SQL =====\n");
        out.append("Schema: ").append(nvl(snap.schema))
                .append(" child=").append(snap.childNumber)
                .append(" inst_id=").append(snap.instId)
                .append(" len=").append(snap.sqlText.length())
                .append('\n');
        out.append(snap.sqlText);
        if (!snap.sqlText.endsWith("\n")) {
            out.append('\n');
        }
        out.append("--------------------------------------------------------\n");

        if (timedOut(deadlineMs)) {
            out.append("[ERROR] report timeout after ").append(timeoutSec).append("s\n");
            return out.toString();
        }

        try {
            List<BindValue> binds = src.loadBinds(c, sqlId, snap.childNumber, snap.instId);
            out.append("===== LITERAL SQL =====\n");
            out.append("Schema: ").append(nvl(snap.schema))
                    .append(" child=").append(snap.childNumber)
                    .append(" (bind values from capture; Java rewrite)\n");
            if (binds == null || binds.isEmpty()) {
                out.append("(no bind capture on executed child; same as ORIGINAL SQL)\n");
                out.append(snap.sqlText);
            } else {
                out.append(LiteralBindRewrite.rewrite(snap.sqlText, binds));
            }
            if (out.charAt(out.length() - 1) != '\n') {
                out.append('\n');
            }
            out.append("--------------------------------------------------------\n");
        } catch (SQLException e) {
            out.append("[ERROR] literal binds: ").append(e.getMessage()).append('\n');
            if (log != null) {
                log.logWarn("report literal failed sql_id=" + sqlId + ": " + e.getMessage());
            }
        }

        if (timedOut(deadlineMs)) {
            out.append("[ERROR] report timeout after ").append(timeoutSec).append("s\n");
            return out.toString();
        }

        out.append('\n');
        try {
            selectSections.appendFromPlan(session, sqlId, out, deadlineMs, timeoutSec,
                    htzSections, htzOwner);
        } catch (java.io.IOException e) {
            out.append("[ERROR] P1 sections: ").append(e.getMessage()).append('\n');
            if (log != null) {
                log.logWarn("report P1 failed sql_id=" + sqlId + ": " + e.getMessage());
            }
        } catch (SQLException e) {
            out.append("[ERROR] P1 sections: ").append(e.getMessage()).append('\n');
            if (log != null) {
                log.logWarn("report P1 failed sql_id=" + sqlId + ": " + e.getMessage());
            }
        }

        if (explainPlan && !timedOut(deadlineMs)) {
            ExplainPlanSection.append(c, sqlId, snap.sqlText, out, log,
                    stmtTimeout(deadlineMs, timeoutSec));
        }
        return out.toString();
    }

    private static int stmtTimeout(long deadlineMs, int overallTimeoutSec) {
        if (overallTimeoutSec <= 0) {
            return 0;
        }
        long leftMs = deadlineMs - System.currentTimeMillis();
        if (leftMs <= 0) {
            return 1;
        }
        return Math.max(1, (int) ((leftMs + 999L) / 1000L));
    }

    private static boolean timedOut(long deadlineMs) {
        return System.currentTimeMillis() > deadlineMs;
    }

    private static String nvl(String s) {
        return s == null ? "" : s;
    }
}
