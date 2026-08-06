//go:build !windows

package connector

import (
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/yihan/ytop/internal/logger"
	"github.com/yihan/ytop/internal/platform"
	"golang.org/x/crypto/ssh"
	"golang.org/x/term"
)

// RunInteractiveCLI 在远程 Unix SSH PTY 中启动交互式 DB CLI.
func (c *SSHConnector) RunInteractiveCLI() (int, error) {
	if c.cfg.TargetOS == platform.OSWindows {
		return 1, fmt.Errorf("interactive CLI (-e) is not supported on Windows remote in this version")
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return 1, fmt.Errorf("-e requires a terminal")
	}

	loginCmd, err := BuildInteractiveLoginCmd(c.cfg)
	if err != nil {
		return 1, err
	}
	remote := c.WrapCmd(loginCmd)
	if c.cfg.DebugMode {
		logger.Debug("interactive ssh login: %s\n", remote)
	}

	session, err := c.pool.NewSession()
	if err != nil {
		return 1, err
	}
	defer session.Close()

	fd := int(os.Stdin.Fd())
	w, h, err := term.GetSize(fd)
	if err != nil {
		w, h = 80, 24
	}
	modes := ssh.TerminalModes{
		ssh.ECHO:          1,
		ssh.TTY_OP_ISPEED: 14400,
		ssh.TTY_OP_OSPEED: 14400,
	}
	termType := os.Getenv("TERM")
	if termType == "" {
		termType = "xterm-256color"
	}
	if err := session.RequestPty(termType, h, w, modes); err != nil {
		return 1, fmt.Errorf("request pty: %w", err)
	}

	stdin, err := session.StdinPipe()
	if err != nil {
		return 1, err
	}
	stdout, err := session.StdoutPipe()
	if err != nil {
		return 1, err
	}
	// PTY merges stderr into stdout; do not attach a separate stderr pipe.

	oldState, err := term.MakeRaw(fd)
	if err != nil {
		return 1, fmt.Errorf("make raw: %w", err)
	}
	defer func() { _ = term.Restore(fd, oldState) }()

	if err := session.Start(remote); err != nil {
		return 1, fmt.Errorf("start: %w", err)
	}

	winCh := make(chan os.Signal, 1)
	signal.Notify(winCh, syscall.SIGWINCH)
	defer signal.Stop(winCh)
	go func() {
		for range winCh {
			if nw, nh, e := term.GetSize(fd); e == nil {
				_ = session.WindowChange(nh, nw)
			}
		}
	}()

	go func() { _, _ = io.Copy(stdin, os.Stdin) }()
	go func() { _, _ = io.Copy(os.Stdout, stdout) }()

	if err := session.Wait(); err != nil {
		if ee, ok := err.(*ssh.ExitError); ok {
			return ee.ExitStatus(), nil
		}
		return 1, err
	}
	return 0, nil
}
