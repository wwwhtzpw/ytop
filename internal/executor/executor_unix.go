// +build !windows

package executor

import (
	"os/exec"
	"syscall"
)

// setProcAttributes sets platform-specific process attributes
func setProcAttributes(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid: true,
	}
}

// killProcessGroup kills the entire process group
func killProcessGroup(cmd *exec.Cmd) error {
	if cmd.Process != nil {
		pgid, err := syscall.Getpgid(cmd.Process.Pid)
		if err == nil {
			syscall.Kill(-pgid, syscall.SIGKILL)
		}
	}
	return nil
}
