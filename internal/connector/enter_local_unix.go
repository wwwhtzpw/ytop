//go:build !windows

package connector

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"github.com/creack/pty"
	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/logger"
	"golang.org/x/term"
)

// RunLocalInteractiveCLI 在本机 PTY 中启动交互式 DB CLI; 返回进程退出码.
func RunLocalInteractiveCLI(cfg *config.Config) (int, error) {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return 1, fmt.Errorf("-e requires a terminal")
	}

	loginCmd, err := BuildInteractiveLoginCmd(cfg)
	if err != nil {
		return 1, err
	}
	full := WrapSourceCmd(cfg.SourceCmd, loginCmd)
	if cfg.DebugMode {
		logger.Debug("interactive local login: %s\n", full)
	}

	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return 1, fmt.Errorf("make raw: %w", err)
	}
	defer func() { _ = term.Restore(fd, oldState) }()

	cmd := exec.Command("bash", "-c", full)
	ptmx, err := pty.Start(cmd)
	if err != nil {
		return 1, fmt.Errorf("pty start: %w", err)
	}
	defer func() { _ = ptmx.Close() }()

	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGWINCH)
	go func() {
		for range ch {
			_ = pty.InheritSize(os.Stdin, ptmx)
		}
	}()
	ch <- syscall.SIGWINCH
	defer signal.Stop(ch)

	go func() { _, _ = io.Copy(ptmx, os.Stdin) }()
	_, _ = io.Copy(os.Stdout, ptmx)

	if err := cmd.Wait(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			if status, ok := ee.Sys().(syscall.WaitStatus); ok {
				return status.ExitStatus(), nil
			}
			return ee.ExitCode(), nil
		}
		return 1, err
	}
	return 0, nil
}
