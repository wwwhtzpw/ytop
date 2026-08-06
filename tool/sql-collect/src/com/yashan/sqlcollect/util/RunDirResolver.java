package com.yashan.sqlcollect.util;

import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * 解析 collect/replay 运行目录: base/yyyyMMddHHmmss.
 * 默认沿用最新时间戳子目录; --new-run 新建; 无子目录则创建.
 * 目录不存在才创建; 创建失败或创建后仍非目录则抛 IOException (由调用方退出).
 */
public final class RunDirResolver {

    /** 目录名: yyyyMMddHHmmss (14 位数字) */
    public static final Pattern RUN_DIR_NAME = Pattern.compile("^\\d{14}$");

    private RunDirResolver() {
    }

    public static final class Result {
        /** 用户传入的 --outdir (基目录或已是 run 目录) */
        public final Path baseOutdir;
        /** 实际读写 reports/replay/collected 的目录 */
        public final Path runDir;
        /** 是否本轮新建了时间戳目录 (此前不存在) */
        public final boolean created;
        /** pinned | latest | new */
        public final String mode;

        public Result(Path baseOutdir, Path runDir, boolean created, String mode) {
            this.baseOutdir = baseOutdir;
            this.runDir = runDir;
            this.created = created;
            this.mode = mode;
        }
    }

    /**
     * @param outdirArg --outdir 绝对或相对路径
     * @param newRun    true=强制新建 yyyyMMddHHmmss 子目录
     */
    public static Result resolve(Path outdirArg, boolean newRun) throws IOException {
        Path out = outdirArg.toAbsolutePath().normalize();
        String name = out.getFileName() == null ? "" : out.getFileName().toString();

        // 已指向某个时间戳 run 目录
        if (RUN_DIR_NAME.matcher(name).matches()) {
            ensureDirectory(out);
            Path base = out.getParent() == null ? out : out.getParent();
            return new Result(base, out, false, "pinned");
        }

        ensureDirectory(out);

        if (newRun) {
            Path run = out.resolve(nowStamp());
            boolean created = ensureDirectory(run);
            return new Result(out, run, created, "new");
        }

        Path latest = findLatestRunDir(out);
        if (latest != null) {
            ensureDirectory(latest);
            return new Result(out, latest, false, "latest");
        }

        Path run = out.resolve(nowStamp());
        boolean created = ensureDirectory(run);
        return new Result(out, run, created, "new");
    }

    /**
     * 目录不存在则创建; 已存在则复用.
     *
     * @return true 表示本调用新建了目录; false 表示此前已存在
     * @throws IOException 创建失败, 或结束后仍不是目录 (例如路径上是普通文件)
     */
    public static boolean ensureDirectory(Path dir) throws IOException {
        if (dir == null) {
            throw new IOException("directory path is null");
        }
        boolean existed = Files.isDirectory(dir);
        if (!existed) {
            try {
                Files.createDirectories(dir);
            } catch (IOException e) {
                throw new IOException("create directory failed: " + dir + ": " + e.getMessage(), e);
            }
        }
        if (!Files.isDirectory(dir)) {
            throw new IOException("path is not a directory after create: " + dir);
        }
        return !existed;
    }

    public static Path findLatestRunDir(Path base) throws IOException {
        if (!Files.isDirectory(base)) {
            return null;
        }
        List<String> names = new ArrayList<String>();
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(base)) {
            for (Path p : ds) {
                if (!Files.isDirectory(p)) {
                    continue;
                }
                String n = p.getFileName().toString();
                if (RUN_DIR_NAME.matcher(n).matches()) {
                    names.add(n);
                }
            }
        }
        if (names.isEmpty()) {
            return null;
        }
        Collections.sort(names);
        return base.resolve(names.get(names.size() - 1));
    }

    public static String nowStamp() {
        return new SimpleDateFormat("yyyyMMddHHmmss", Locale.US).format(new Date());
    }

    public static boolean isRunDirName(String name) {
        return name != null && RUN_DIR_NAME.matcher(name).matches();
    }
}
