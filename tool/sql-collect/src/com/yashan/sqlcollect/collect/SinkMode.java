package com.yashan.sqlcollect.collect;

import com.yashan.sqlcollect.cli.Args;

/**
 * collect 落点模式: 只表 / 只文件 / 两者.
 * 解析 --sink 与旧旗标 (-B/-K) 的互斥与映射.
 */
public enum SinkMode {
    TABLE,
    FILE,
    BOTH;

    /**
     * 从 Args 解析 sink 模式.
     *
     * @throws IllegalArgumentException 非法值、旗标冲突或 table + -X
     */
    public static SinkMode resolve(Args args) {
        boolean backupOnly = args.flag("backup-only");
        boolean skipBackup = args.flag("skip-backup");
        boolean skipReplayExport = args.flag("skip-replay-export");

        if (backupOnly && skipBackup) {
            throw new IllegalArgumentException(
                    "backup-only and skip-backup are mutually exclusive");
        }

        SinkMode fromSink = parseSinkOpt(args.opt("sink", null));
        SinkMode fromFlags = null;
        if (backupOnly) {
            fromFlags = TABLE;
        } else if (skipBackup) {
            fromFlags = FILE;
        }

        SinkMode resolved;
        if (fromSink != null && fromFlags != null) {
            if (fromSink != fromFlags) {
                throw new IllegalArgumentException(
                        "sink mode conflicts with backup-only/skip-backup flags");
            }
            resolved = fromSink;
        } else if (fromSink != null) {
            resolved = fromSink;
        } else if (fromFlags != null) {
            resolved = fromFlags;
        } else {
            resolved = BOTH;
        }

        if (resolved == TABLE && skipReplayExport) {
            throw new IllegalArgumentException(
                    "table sink requires replay package table; remove -X");
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
        throw new IllegalArgumentException("invalid sink mode: " + raw);
    }
}
