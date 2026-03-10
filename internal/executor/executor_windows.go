// +build windows

package executor

import (
	"os/exec"
)

// setProcAttributes sets platform-specific process attributes
func setProcAttributes(cmd *exec.Cmd) {
	// Windows doesn't support process groups in the same way
	// No special attributes needed
}

// killProcessGroup kills the process (Windows doesn't have process groups)
func killProcessGroup(cmd *exec.Cmd) error {
	if cmd.Process != nil {
		return cmd.Process.Kill()
	}
	return nil
}
