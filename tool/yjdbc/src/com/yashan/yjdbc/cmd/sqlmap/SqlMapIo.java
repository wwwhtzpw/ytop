package com.yashan.yjdbc.cmd.sqlmap;

import com.yashan.yjdbc.cmd.sqlmap.support.config.JdbcConfig;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcPool;
import com.yashan.yjdbc.cmd.sqlmap.support.db.JdbcSession;
import com.yashan.yjdbc.cmd.sqlmap.support.db.SqlLookup;
import com.yashan.yjdbc.cmd.sqlmap.support.log.DualLogger;
import com.yashan.yjdbc.cmd.sqlmap.support.model.BindValue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;

/** export / genbind */
public final class SqlMapIo {

    private SqlMapIo() {
    }

    public static int exportSql(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        String sqlId = a.opt("src-sql-id", "");
        String out = a.opt("out", "sql_" + sqlId + ".sql");
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                SqlLookup.SqlTextInfo info = SqlLookup.loadSqlText(sess.getConnection(), sqlId,
                        warn(log));
                if (!info.found) {
                    log.logError("sql_id not found in gv$/v$sql: " + sqlId);
                    return 1;
                }
                Files.write(Paths.get(out), info.sqlText.getBytes(StandardCharsets.UTF_8));
                log.logInfo("export sql_id=" + sqlId + " chars=" + info.sqlText.length()
                        + " out=" + out);
                System.out.println("[OK] export " + out + " chars=" + info.sqlText.length());
                return 0;
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("export failed: " + e.getMessage());
            return 1;
        }
    }

    public static int genbind(JdbcConfig cfg, JdbcPool pool, SqlMapArgs a, DualLogger log) {
        String sqlId = a.opt("src-sql-id", "");
        String out = a.opt("out", "bind_" + sqlId + ".txt");
        try {
            JdbcSession sess = new JdbcSession(cfg, log, pool);
            try {
                SqlLookup.BindSource src = SqlLookup.BindSource.AUTO;
                String kw = a.bindSourceKeyword();
                if ("backup".equals(kw)) {
                    src = SqlLookup.BindSource.BACKUP;
                } else if ("view".equals(kw)) {
                    src = SqlLookup.BindSource.VIEW;
                }
                List<BindValue> binds = SqlLookup.loadBindsBySqlId(sess.getConnection(), sqlId,
                        src, warn(log));
                // 方案 A: 结合 peep 文本 LTR 重排, 使一行一值可直接配全? SQL
                SqlLookup.SqlTextInfo info = SqlLookup.loadSqlText(sess.getConnection(), sqlId,
                        warn(log));
                if (info.found && binds != null && !binds.isEmpty()) {
                    com.yashan.yjdbc.cmd.sqlmap.support.collect.LiteralBindRewrite.Aligned aligned =
                            com.yashan.yjdbc.cmd.sqlmap.support.collect.LiteralBindRewrite.align(
                                    info.sqlText, binds);
                    for (String w : aligned.warnings) {
                        log.logInfo("[WARN] bind align: " + w);
                    }
                    binds = aligned.binds;
                }
                int filled = 0;
                StringBuilder sb = new StringBuilder();
                for (BindValue b : binds) {
                    String v = b.value;
                    if (v == null || v.isEmpty()) {
                        sb.append("NULL");
                    } else {
                        sb.append(v);
                        filled++;
                    }
                    sb.append('\n');
                }
                Files.write(Paths.get(out), sb.toString().getBytes(StandardCharsets.UTF_8));
                log.logInfo("genbind sql_id=" + sqlId + " n=" + binds.size()
                        + " filled=" + filled + " out=" + out
                        + " bind_source=" + src.name().toLowerCase(java.util.Locale.ROOT)
                        + " bind_align=A");
                if (binds.isEmpty()) {
                    log.logWarn("genbind: no captured binds (last_captured empty for all children);"
                            + " check v$sql_bind_capture / HTZ_GV_SQL_BIND_CAPTURE");
                    System.out.println("[WARN] genbind empty; no last_captured values for " + sqlId);
                } else if (filled == 0) {
                    log.logWarn("genbind: " + binds.size()
                            + " slot(s) but all NULL; likely stale jar or wrong child");
                    System.out.println("[WARN] genbind all NULL n=" + binds.size()
                            + "; redeploy ytop/sql_collect.jar");
                } else {
                    System.out.println("[OK] genbind " + out + " n=" + binds.size()
                            + " filled=" + filled + " source="
                            + src.name().toLowerCase(java.util.Locale.ROOT));
                }
                return filled > 0 || binds.isEmpty() ? 0 : 1;
            } finally {
                sess.close();
            }
        } catch (Exception e) {
            log.logError("genbind failed: " + e.getMessage());
            return 1;
        }
    }

    static SqlLookup.WarnOut warn(final DualLogger log) {
        return new SqlLookup.WarnOut() {
            public void warn(String msg) {
                log.logInfo("[WARN] " + msg);
            }
        };
    }

    /** 读 genbind 风格绑定文件 (一行一值) → Replay 行 [pos,dt,val] */
    public static java.util.List<String[]> readValueLines(String path) throws java.io.IOException {
        java.util.List<String[]> rows = new java.util.ArrayList<String[]>();
        if (path == null || path.isEmpty() || !Files.exists(Paths.get(path))) {
            return rows;
        }
        int pos = 1;
        for (String ln : new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8)
                .split("\n", -1)) {
            if (ln.isEmpty() || ln.startsWith("#")) {
                continue;
            }
            // 兼容 position|datatype|value 三列
            if (ln.contains("|")) {
                String[] p = ln.split("\\|", 3);
                if (p.length >= 1 && p[0].trim().matches("\\d+")) {
                    rows.add(new String[] {
                        p[0].trim(),
                        p.length > 1 ? p[1].trim() : "VARCHAR2",
                        p.length > 2 ? p[2] : ""
                    });
                    continue;
                }
            }
            String val = ln;
            if ("NULL".equalsIgnoreCase(val)) {
                val = "";
            }
            rows.add(new String[] {String.valueOf(pos), "VARCHAR2", val});
            pos++;
        }
        return rows;
    }

    public static String readFile(String path) throws java.io.IOException {
        return new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8);
    }
}
