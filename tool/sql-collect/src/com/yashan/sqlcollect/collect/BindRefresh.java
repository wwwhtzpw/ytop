package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.db.HtzSqlSource;
import com.yashan.sqlcollect.db.HtzTables;
import com.yashan.sqlcollect.db.JdbcSession;
import com.yashan.sqlcollect.db.SqlDataSource;
import com.yashan.sqlcollect.db.SqlLookup;
import com.yashan.sqlcollect.model.BindValue;
import com.yashan.sqlcollect.util.JsonBinds;
import com.yashan.sqlcollect.util.PipeEscape;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

/**
 * 绑定刷新判定: 空包绑定 + capture 有更多非空值 => 重导出.
 * HTZ 路径 (HtzSqlSource / useHtz=true): filled 计数查 HTZ_GV_SQL_BIND_CAPTURE;
 * 包侧统计读 replay/ 文件.
 */
public class BindRefresh {

    /** 仅文件包路径: 无 replay/ 包则视为需要刷新. */
    public boolean needsRefresh(Path outdir, String sqlId) {
        return needsRefresh(null, outdir, sqlId, false, null);
    }

    /**
     * @param session  保留参数 (兼容旧调用); 包侧仅读文件
     * @param useHtz   true 时 filled 计数走 HTZ_GV_SQL_BIND_CAPTURE
     * @param jdbcUser HTZ 表所属登录用户; useHtz 时必填
     */
    public boolean needsRefresh(JdbcSession session, Path outdir, String sqlId,
                                boolean useHtz, String jdbcUser) {
        int[] stats = packageSideBindStats(outdir, sqlId);
        if (stats == null) {
            // 无文件包 → 需要刷新/首次导出
            return true;
        }
        int nBinds = stats[0];
        int nEmpty = stats[1];
        if (nBinds == 0) {
            return false;
        }
        return nEmpty > 0;
    }

    /** live 路径: filled 计数查 gv$/v$sql_bind_capture. */
    public boolean shouldReExport(JdbcSession session, Path outdir, String sqlId) throws SQLException {
        return shouldReExport(session, outdir, sqlId, false, null);
    }

    /**
     * @param src      非 null 且为 {@link HtzSqlSource} 时走 HTZ filled 计数
     * @param jdbcUser HTZ 表所属登录用户; HTZ 路径必填
     */
    public boolean shouldReExport(JdbcSession session, Path outdir, String sqlId,
                                  SqlDataSource src, String jdbcUser) throws SQLException {
        boolean useHtz = src instanceof HtzSqlSource;
        return shouldReExport(session, outdir, sqlId, useHtz, jdbcUser);
    }

    /**
     * @param useHtz   true 时从 HTZ_GV_SQL_BIND_CAPTURE 计 filled
     * @param jdbcUser HTZ 路径下表所属登录用户; useHtz=false 时可 null
     */
    public boolean shouldReExport(JdbcSession session, Path outdir, String sqlId,
                                  boolean useHtz, String jdbcUser) throws SQLException {
        int[] stats = packageSideBindStats(outdir, sqlId);
        if (stats == null) {
            return true;
        }
        int pkgFilled = Math.max(0, stats[0] - stats[1]);
        Integer capFilled;
        if (useHtz) {
            capFilled = htzFilledCount(session.getConnection(), jdbcUser, sqlId);
        } else {
            capFilled = captureFilledCount(session.getConnection(), sqlId);
        }
        if (capFilled == null) {
            return true;
        }
        return capFilled > pkgFilled;
    }

    /**
     * 包侧绑定统计: 读 replay/ 文件.
     * @return [nBinds, nEmpty]; 无包则 null
     */
    private int[] packageSideBindStats(Path outdir, String sqlId) {
        List<Path> pkgs = listPackages(outdir, sqlId);
        if (!pkgs.isEmpty()) {
            return packageBindStats(pkgs.get(0));
        }
        return null;
    }

    public List<Path> listPackages(Path outdir, String sqlId) {
        Path root = outdir.resolve(PackageExporter.REPLAY_DIR);
        List<Path> out = new ArrayList<Path>();
        if (!Files.isDirectory(root)) {
            return out;
        }
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(root)) {
            for (Path d : ds) {
                if (!Files.isDirectory(d)) {
                    continue;
                }
                Path orig = d.resolve("orig.sql");
                Path meta = d.resolve("meta.txt");
                if (!Files.isRegularFile(orig) || !Files.isRegularFile(meta)) {
                    continue;
                }
                String sid = readMeta(meta, "sql_id");
                if (sid.isEmpty()) {
                    String name = d.getFileName().toString();
                    if (name.contains("__c")) {
                        sid = name.substring(0, name.indexOf("__c"));
                    } else {
                        sid = name;
                    }
                }
                if (sqlId != null && !sqlId.isEmpty() && !sid.equals(sqlId)) {
                    continue;
                }
                out.add(d);
            }
        } catch (IOException e) {
            return new ArrayList<Path>();
        }
        return out;
    }

    private int[] packageBindStats(Path pkgDir) {
        Path bj = pkgDir.resolve("binds.json");
        if (Files.isRegularFile(bj)) {
            try {
                String raw = new String(Files.readAllBytes(bj), StandardCharsets.UTF_8);
                return bindStatsFromJson(raw);
            } catch (IOException e) {
                return null;
            }
        }
        Path bt = pkgDir.resolve("binds.txt");
        if (!Files.isRegularFile(bt)) {
            return null;
        }
        try {
            List<String> lines = Files.readAllLines(bt, StandardCharsets.UTF_8);
            int n = 0;
            int empty = 0;
            for (String line : lines) {
                if (line.isEmpty() || line.startsWith("#")) {
                    continue;
                }
                String[] p = PipeEscape.split(line, 3);
                if (p.length < 1 || !p[0].trim().matches("\\d+")) {
                    continue;
                }
                n++;
                String val = p.length > 2 ? PipeEscape.unescape(p[2]) : "";
                if (isEmptyValue(val)) {
                    empty++;
                }
            }
            return new int[] {n, empty};
        } catch (IOException e) {
            return null;
        }
    }

    private static int[] bindStatsFromJson(String raw) {
        List<BindValue> binds = JsonBinds.read(raw == null ? "" : raw);
        int empty = 0;
        for (BindValue b : binds) {
            if (isEmptyValue(b.value)) {
                empty++;
            }
        }
        return new int[] {binds.size(), empty};
    }

    private Integer captureFilledCount(Connection c, String sqlId) {
        String[] queries = new String[] {
            "SELECT COUNT(*) FROM gv$sql_bind_capture b "
                    + "WHERE b.sql_id = ? AND " + SqlLookup.PRED_B_FILLED,
            "SELECT COUNT(*) FROM v$sql_bind_capture b "
                    + "WHERE b.sql_id = ? AND " + SqlLookup.PRED_B_FILLED
        };
        for (String q : queries) {
            try (PreparedStatement ps = c.prepareStatement(q)) {
                ps.setString(1, sqlId);
                try (ResultSet rs = ps.executeQuery()) {
                    rs.next();
                    return rs.getInt(1);
                }
            } catch (SQLException ignored) {
            }
        }
        return null;
    }

    /** HTZ_GV_SQL_BIND_CAPTURE 上已 capture 行计数 (仅 last_captured; 不做 value 长度判断). */
    private Integer htzFilledCount(Connection c, String jdbcUser, String sqlId) {
        if (jdbcUser == null || jdbcUser.trim().isEmpty()) {
            return null;
        }
        String owner = HtzTables.normalizeOwner(jdbcUser);
        String qn = HtzTables.qname(owner, HtzTables.GV_BIND);
        String[] queries = new String[] {
            "SELECT COUNT(*) FROM " + qn + " b WHERE b.sql_id = ? AND " + SqlLookup.PRED_B_FILLED,
            "SELECT COUNT(*) FROM " + qn + " b WHERE b.sql_id = ?"
        };
        for (String q : queries) {
            try (PreparedStatement ps = c.prepareStatement(q)) {
                ps.setString(1, sqlId);
                try (ResultSet rs = ps.executeQuery()) {
                    rs.next();
                    return rs.getInt(1);
                }
            } catch (SQLException ignored) {
            }
        }
        return null;
    }

    private static boolean isEmptyValue(String val) {
        if (val == null) {
            return true;
        }
        String s = val.trim();
        return s.isEmpty() || "\\N".equals(s);
    }

    private static String readMeta(Path meta, String key) {
        try {
            for (String line : Files.readAllLines(meta, StandardCharsets.UTF_8)) {
                if (line.contains("=")) {
                    String[] kv = line.split("=", 2);
                    if (kv[0].trim().equals(key)) {
                        return kv[1].trim();
                    }
                }
            }
        } catch (IOException ignored) {
        }
        return "";
    }
}
