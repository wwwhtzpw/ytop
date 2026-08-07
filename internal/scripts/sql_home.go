package scripts

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// StageSQLScriptHome 将当前 DBType 的 SQL 脚本落到临时目录, 供 yjdbc @ 按「内嵌优先」查找.
//
// 行为:
//  1. 先按物理文件名写入全部 .sql (显式 @we_yjdbc.sql 仍可用)
//  2. 再按「当前引擎 + CurrentDBVersion」解析每个逻辑名, 把解析结果覆盖写入逻辑名文件
//     (例如 -E 下存在 we_yjdbc.sql 时, @we.sql 读到的是 yjdbc 变体内容)
//
// 覆盖顺序与 readSQLScriptBytes 一致: embed 先, filesystem scripts 后覆盖同名.
func StageSQLScriptHome() (dir string, cleanup func(), err error) {
	cleanup = func() {}
	dir, err = os.MkdirTemp("", "ytop-sql-home-*")
	if err != nil {
		return "", cleanup, err
	}
	cleanup = func() { _ = os.RemoveAll(dir) }

	db := CurrentDBType
	if db == "" {
		db = "yashandb"
	}

	physical := make(map[string][]byte) // basename -> content
	collect := func(filename string, data []byte) {
		if !strings.HasSuffix(strings.ToLower(filename), ".sql") {
			return
		}
		physical[filename] = data
	}

	_ = fs.WalkDir(defaultEmbeddedFS, "sql/"+db, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil || d.IsDir() {
			return nil
		}
		data, re := fs.ReadFile(defaultEmbeddedFS, path)
		if re != nil {
			return nil
		}
		collect(filepath.Base(path), data)
		return nil
	})
	if scriptsDir, ge := getScriptDir(); ge == nil && scriptsDir != "" {
		fsDir := filepath.Join(scriptsDir, "sql", db)
		_ = filepath.WalkDir(fsDir, func(path string, d fs.DirEntry, walkErr error) error {
			if walkErr != nil || d.IsDir() {
				return nil
			}
			data, re := os.ReadFile(path)
			if re != nil {
				return nil
			}
			collect(filepath.Base(path), data)
			return nil
		})
	}

	if len(physical) == 0 {
		cleanup()
		cleanup = func() {}
		return "", cleanup, fmt.Errorf("no SQL scripts staged for db type %s", db)
	}

	for name, data := range physical {
		if we := os.WriteFile(filepath.Join(dir, name), data, 0644); we != nil {
			cleanup()
			cleanup = func() {}
			return "", cleanup, we
		}
	}

	// 逻辑名覆盖: 使 @we.sql 命中引擎/版本解析后的内容
	logicals := make(map[string]struct{})
	for name := range physical {
		base, _, _ := parseScriptNameParts(name)
		if base == "" {
			continue
		}
		logicals[base+".sql"] = struct{}{}
	}
	for logical := range logicals {
		picked, rerr := ResolveSQLScriptNameForEngine(logical, CurrentSQLEngine, CurrentDBVersion)
		if rerr != nil || picked == "" {
			continue
		}
		data, ok := physical[picked]
		if !ok {
			// 解析名可能仅在 embed/fs 可读路径; 再读一次
			if b, re := readSQLScriptBytes(picked); re == nil {
				data = b
			} else {
				continue
			}
		}
		if we := os.WriteFile(filepath.Join(dir, logical), data, 0644); we != nil {
			cleanup()
			cleanup = func() {}
			return "", cleanup, we
		}
	}

	return dir, cleanup, nil
}
