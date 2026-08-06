package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.cli.Args;

/**
 * collect 落点模式.
 * <ul>
 *   <li>{@link #FILE} — 视图 → 报告(+replay)</li>
 *   <li>{@link #BACKUP} — 视图 → HTZ_GV_*</li>
 *   <li>{@link #BOTH} — 视图 → HTZ → 报告(+replay)</li>
 *   <li>{@link #TABLE} — HTZ → 报告(+replay)</li>
 * </ul>
 * 解析 --sink 与 -K; -B/--backup-only 已废弃并报错.
 */
public enum SinkMode {
    /** HTZ_GV_* → reports(+replay); 不跑 BackupService. */
    TABLE,
    /** live gv$/v$ → reports(+replay); 不写 HTZ. */
    FILE,
    /** live → HTZ_GV_* → reports(+replay). */
    BOTH,
    /** live → HTZ_GV_* only; 不写报告/replay/包表. */
    BACKUP;

    /**
     * 从 Args 解析 sink 模式.
     *
     * @throws IllegalArgumentException 非法值、旗标冲突、已废弃 -B、或 backup + -X
     */
    public static SinkMode resolve(Args args) {
        boolean backupOnly = args.flag("backup-only");
        boolean skipBackup = args.flag("skip-backup");
        boolean skipReplayExport = args.flag("skip-replay-export");

        if (backupOnly) {
            throw new IllegalArgumentException(
                    "backup-only is removed; use --sink backup");
        }

        SinkMode fromSink = parseSinkOpt(args.opt("sink", null));
        SinkMode fromFlags = null;
        if (skipBackup) {
            fromFlags = FILE;
        }

        SinkMode resolved;
        if (fromSink != null && fromFlags != null) {
            if (fromSink != fromFlags) {
                throw new IllegalArgumentException(
                        "sink mode conflicts with skip-backup flag");
            }
            resolved = fromSink;
        } else if (fromSink != null) {
            resolved = fromSink;
        } else if (fromFlags != null) {
            resolved = fromFlags;
        } else {
            resolved = BOTH;
        }

        if (resolved == BACKUP && skipReplayExport) {
            throw new IllegalArgumentException(
                    "backup sink conflicts with --skip-replay-export; remove -X");
        }

        return resolved;
    }

    /** 解析 --sink 取值; 空/null 返回 null. */
    private static SinkMode parseSinkOpt(String raw) {
        if (raw == null) {
            return null;
        }
        String s = raw.trim().toLowerCase();
        if (s.isEmpty()) {
            return null;
        }
        if ("table".equals(s)) {
            return TABLE;
        }
        if ("file".equals(s)) {
            return FILE;
        }
        if ("both".equals(s)) {
            return BOTH;
        }
        if ("backup".equals(s)) {
            return BACKUP;
        }
        throw new IllegalArgumentException("invalid sink mode: " + raw);
    }
}
