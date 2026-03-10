package config

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestReproduce_SSHPasswordViaShell_DoubleQuotes 复现问题：通过 shell 用双引号传 -p "Oracle1!" 时，
// 在启用 history expansion 的 bash 下，! 可能被解释导致密码被篡改。
// 使用 bash -H -c 启用 history expansion，使复现稳定。
func TestReproduce_SSHPasswordViaShell_DoubleQuotes(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell behavior test skipped on Windows")
	}

	dir := t.TempDir()
	bin := filepath.Join(dir, "printpass")
	repoRoot := filepath.Join("..", "..")
	cmdBuild := exec.Command("go", "build", "-o", bin, "cmd/printpass/main.go")
	cmdBuild.Dir = repoRoot
	if out, err := cmdBuild.CombinedOutput(); err != nil {
		t.Fatalf("build printpass: %v\n%s", err, out)
	}

	// -H 启用 history expansion；双引号内 "Oracle1!" 的 ! 会触发历史展开，导致程序收到的不是 Oracle1!
	cmd := exec.Command("bash", "-H", "-c", bin+` -p "Oracle1!"`)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "HISTFILE=", "HISTSIZE=0")
	out, _ := cmd.CombinedOutput()
	got := strings.TrimSpace(string(out))
	want := "Oracle1!"

	if got != want {
		t.Logf("REPRODUCED: with bash -H and double quotes, program received %q, expected %q", got, want)
		t.Logf("Reason: ! in double-quoted string triggers history expansion in bash.")
		t.Fail() // 复现成功
	}
}

// TestVerify_SSHPasswordViaCommandLine 验证：通过命令行参数 -p 传入密码时，用单引号可正确传递含特殊字符（如 !）的密码。
// 用法示例: ytop -h host -u yashan -p 'Oracle1!' -i 2 -c 3
func TestVerify_SSHPasswordViaCommandLine(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell behavior test skipped on Windows")
	}

	dir := t.TempDir()
	bin := filepath.Join(dir, "printpass")
	cmdBuild := exec.Command("go", "build", "-o", bin, "cmd/printpass/main.go")
	cmdBuild.Dir = filepath.Join("..", "..")
	if out, err := cmdBuild.CombinedOutput(); err != nil {
		t.Fatalf("build printpass: %v\n%s", err, out)
	}

	// 单引号内 ! 在 bash 中不触发 history expansion
	cmd := exec.Command("bash", "-c", bin+` -p 'Oracle1!'`)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("run printpass: %v\n%s", err, out)
	}
	got := strings.TrimSpace(string(out))
	want := "Oracle1!"
	if got != want {
		t.Errorf("command line -p with single quotes: got %q, want %q", got, want)
	}
}
