package connector

import (
	"fmt"
	"strings"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/platform"
)

// BuildInteractiveLoginCmd 拼装交互式 DB CLI 登录命令(无 silent/adhoc 执行参数).
func BuildInteractiveLoginCmd(cfg *config.Config) (string, error) {
	if cfg == nil {
		return "", fmt.Errorf("nil config")
	}
	if s := strings.TrimSpace(cfg.LoginCmd); s != "" {
		return s, nil
	}
	cli := cfg.ResolveCLIForExec()
	conn := strings.TrimSpace(cfg.ConnectString)

	switch cfg.DBType {
	case "mysql":
		args := sortMySQLDefaultsFileFirst(MySQLConnectArgs(conn))
		parts := append([]string{cli}, args...)
		return joinQuotedUnix(parts), nil
	case "postgresql":
		parts := append([]string{cli}, strings.Fields(conn)...)
		return joinQuotedUnix(parts), nil
	case "mssql":
		parts := append([]string{cli}, SQLCmdConnectArgs(conn)...)
		return joinQuotedUnix(parts), nil
	default: // yashandb, oracle, dameng
		if conn == "" {
			return platform.ShellQuoteUnix(cli), nil
		}
		return FormatCLIInvocation(cli, conn), nil
	}
}

func joinQuotedUnix(parts []string) string {
	out := make([]string, len(parts))
	for i, p := range parts {
		out[i] = platform.ShellQuoteUnix(p)
	}
	return strings.Join(out, " ")
}
