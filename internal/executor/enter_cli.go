package executor

import (
	"context"
	"fmt"
	"runtime"

	"github.com/yihan/ytop/internal/connector"
	"github.com/yihan/ytop/internal/platform"
)

// EnterInteractiveCLI 进入交互式 DB CLI; 成功时 err==nil 且 exitCode 为 CLI Wait 码.
func (e *Executor) EnterInteractiveCLI(ctx context.Context) (exitCode int, err error) {
	_ = ctx
	if runtime.GOOS == "windows" {
		return 1, fmt.Errorf("interactive CLI (-e) is not supported on Windows in this version")
	}
	if e.cfg.ConnectionMode == "ssh" {
		if e.cfg.TargetOS == platform.OSWindows {
			return 1, fmt.Errorf("interactive CLI (-e) is not supported on Windows remote in this version")
		}
		sshConn, ok := e.conn.(*connector.SSHConnector)
		if !ok {
			return 1, fmt.Errorf("not an SSH connection")
		}
		return sshConn.RunInteractiveCLI()
	}
	return connector.RunLocalInteractiveCLI(e.cfg)
}
