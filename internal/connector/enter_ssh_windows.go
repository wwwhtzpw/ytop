//go:build windows

package connector

import "fmt"

func (c *SSHConnector) RunInteractiveCLI() (int, error) {
	_ = c
	return 1, fmt.Errorf("interactive CLI (-e) is not supported on Windows in this version")
}
