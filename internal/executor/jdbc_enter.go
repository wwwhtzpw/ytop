package executor

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/scripts"
)

// BuildYashanJdbcURL 拼装 YashanDB JDBC URL.
func BuildYashanJdbcURL(host string, port int, dbName string) string {
	return fmt.Sprintf("jdbc:yasdb://%s:%d/%s", host, port, dbName)
}

// ResolveYjdbcJar 按规格顺序解析业务 jar: YJDBC_JAR → embed → 开发路径.
func ResolveYjdbcJar() (path string, cleanup func(), err error) {
	cleanup = func() {}
	if env := strings.TrimSpace(os.Getenv("YJDBC_JAR")); env != "" {
		if st, e := os.Stat(env); e == nil && !st.IsDir() {
			return env, cleanup, nil
		}
	}
	data, e := scripts.GetOSBytes("yjdbc.jar")
	if e == nil && len(data) > 0 {
		f, ce := os.CreateTemp("", "ytop-yjdbc-*.jar")
		if ce != nil {
			return "", cleanup, fmt.Errorf("create temp yjdbc.jar: %w", ce)
		}
		tmp := f.Name()
		if _, we := f.Write(data); we != nil {
			f.Close()
			os.Remove(tmp)
			return "", cleanup, fmt.Errorf("write temp yjdbc.jar: %w", we)
		}
		if ce = f.Close(); ce != nil {
			os.Remove(tmp)
			return "", cleanup, ce
		}
		cleanup = func() { _ = os.Remove(tmp) }
		return tmp, cleanup, nil
	}
	dev := filepath.Join("tool", "yjdbc", "build", "yjdbc.jar")
	if st, se := os.Stat(dev); se == nil && !st.IsDir() {
		return dev, cleanup, nil
	}
	if wd, we := os.Getwd(); we == nil {
		cand := filepath.Join(wd, "tool", "yjdbc", "build", "yjdbc.jar")
		if st, se := os.Stat(cand); se == nil && !st.IsDir() {
			return cand, cleanup, nil
		}
	}
	return "", cleanup, fmt.Errorf("yjdbc.jar not found (set YJDBC_JAR or rebuild tool/yjdbc)")
}

// ResolveJdbcDriverJar 解析 YashanDB JDBC 驱动:
// CLI cfg.JdbcJar → env JDBC_JAR → embed yashandb-jdbc.jar → 错误.
// CLI/env 非空但文件不存在时硬失败, 不 fallthrough.
func ResolveJdbcDriverJar(cfg *config.Config) (path string, cleanup func(), err error) {
	cleanup = func() {}
	if cfg != nil {
		if j := strings.TrimSpace(cfg.JdbcJar); j != "" {
			st, e := os.Stat(j)
			if e != nil || st.IsDir() {
				return "", cleanup, fmt.Errorf("JDBC driver jar not found: %s", j)
			}
			return j, cleanup, nil
		}
	}
	if env := strings.TrimSpace(os.Getenv("JDBC_JAR")); env != "" {
		st, e := os.Stat(env)
		if e != nil || st.IsDir() {
			return "", cleanup, fmt.Errorf("JDBC driver jar not found (JDBC_JAR): %s", env)
		}
		return env, cleanup, nil
	}
	data, e := scripts.GetOSBytes("yashandb-jdbc.jar")
	if e == nil && len(data) > 0 {
		f, ce := os.CreateTemp("", "ytop-yas-jdbc-*.jar")
		if ce != nil {
			return "", cleanup, fmt.Errorf("create temp yashandb-jdbc.jar: %w", ce)
		}
		tmp := f.Name()
		if _, we := f.Write(data); we != nil {
			f.Close()
			os.Remove(tmp)
			return "", cleanup, fmt.Errorf("write temp yashandb-jdbc.jar: %w", we)
		}
		if ce = f.Close(); ce != nil {
			os.Remove(tmp)
			return "", cleanup, ce
		}
		cleanup = func() { _ = os.Remove(tmp) }
		return tmp, cleanup, nil
	}
	return "", cleanup, fmt.Errorf(
		"JDBC driver jar not found: pass -J/--jdbc-jar, set JDBC_JAR, or embed internal/scripts/os/yashandb-jdbc.jar")
}

// ResolveJdbcSQLScript 将 -f SQL 解析为本地可读文件 (embed 则落临时文件).
func ResolveJdbcSQLScript(scriptArg string) (path string, cleanup func(), err error) {
	cleanup = func() {}
	name := scripts.FirstToken(scriptArg)
	if name == "" {
		return "", cleanup, fmt.Errorf("empty -f script")
	}
	if !scripts.IsSQLScriptInput(name) {
		return "", cleanup, fmt.Errorf("-E -f only supports SQL scripts (.sql)")
	}
	// 显式路径且文件存在: 直接用
	if filepath.IsAbs(name) || strings.HasPrefix(name, "./") || strings.HasPrefix(name, "../") {
		if st, e := os.Stat(name); e == nil && !st.IsDir() {
			abs, ae := filepath.Abs(name)
			if ae != nil {
				return name, cleanup, nil
			}
			return abs, cleanup, nil
		}
	}
	content, e := scripts.GetSQLScript(name)
	if e != nil {
		return "", cleanup, fmt.Errorf("load SQL script %s: %w", name, e)
	}
	f, ce := os.CreateTemp("", "ytop-yjdbc-script-*.sql")
	if ce != nil {
		return "", cleanup, fmt.Errorf("create temp script: %w", ce)
	}
	tmp := f.Name()
	if _, we := f.WriteString(content); we != nil {
		f.Close()
		os.Remove(tmp)
		return "", cleanup, we
	}
	if ce = f.Close(); ce != nil {
		os.Remove(tmp)
		return "", cleanup, ce
	}
	cleanup = func() { _ = os.Remove(tmp) }
	return tmp, cleanup, nil
}

// sanitizeJdbcTermEnv 复制环境; TERM 为空或 dumb 时改为 xterm-256color, 避免 JLine UnsupportedTerminal.
func sanitizeJdbcTermEnv(base []string) []string {
	out := make([]string, 0, len(base)+1)
	term := ""
	hasTerm := false
	for _, kv := range base {
		if strings.HasPrefix(kv, "TERM=") {
			hasTerm = true
			term = strings.TrimPrefix(kv, "TERM=")
			if term == "" || strings.EqualFold(term, "dumb") {
				out = append(out, "TERM=xterm-256color")
			} else {
				out = append(out, kv)
			}
			continue
		}
		out = append(out, kv)
	}
	if !hasTerm {
		out = append(out, "TERM=xterm-256color")
	}
	return out
}

// EnterJdbcShell 在控制端本机拉起 Java yjdbc shell; 不走 SSH.
// 若 cfg.ExecuteScript 为 SQL, 则以 --script 批处理执行后退出.
func (e *Executor) EnterJdbcShell() (exitCode int, err error) {
	cfg := e.cfg
	if cfg == nil || !cfg.JdbcEnter {
		return 1, fmt.Errorf("JdbcEnter is not set")
	}
	javaPath, err := exec.LookPath("java")
	if err != nil {
		return 1, fmt.Errorf("java not found in PATH (Java 8+ required)")
	}
	yjdbc, cleanupJar, err := ResolveYjdbcJar()
	if err != nil {
		return 1, err
	}
	defer cleanupJar()

	driver, cleanupDriver, err := ResolveJdbcDriverJar(cfg)
	if err != nil {
		return 1, err
	}
	defer cleanupDriver()

	// JLine: 拉长 ESC 歧义超时; 非 Windows 强制 unix, 避免 TERM=dumb 落入 UnsupportedTerminal
	args := []string{
		"-Djline.esc.timeout=500",
	}
	if runtime.GOOS != "windows" {
		args = append(args, "-Djline.terminal=unix")
	}
	args = append(args,
		"-cp", yjdbc+string(os.PathListSeparator)+driver,
		"com.yashan.yjdbc.Main", "shell",
		"--url", BuildYashanJdbcURL(cfg.JdbcHost, cfg.JdbcPort, cfg.DbName),
		"--user", cfg.JdbcUser,
		"--password", cfg.JdbcPassword,
	)

	// 抽出内嵌 SQL, 供 @ / @@ 按「内嵌 → cwd」查找 (失败则仅 cwd/绝对路径仍可用)
	sqlHome, cleanupHome, he := scripts.StageSQLScriptHome()
	if he == nil {
		defer cleanupHome()
		args = append(args, "--sql-home", sqlHome)
	}

	if strings.TrimSpace(cfg.ExecuteScript) != "" {
		scriptPath, cleanupScript, se := ResolveJdbcSQLScript(cfg.ExecuteScript)
		if se != nil {
			return 1, se
		}
		defer cleanupScript()
		args = append(args, "--script", scriptPath, "--batch")
	}

	for _, d := range cfg.JdbcDefines {
		d = strings.TrimSpace(d)
		if d == "" {
			continue
		}
		args = append(args, "--define", d)
	}

	cmd := exec.Command(javaPath, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = sanitizeJdbcTermEnv(os.Environ())
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode(), nil
		}
		return 1, err
	}
	return 0, nil
}
