package connector

import (
	"fmt"

	"github.com/yihan/ytop/internal/config"
)

// NewConnector creates a connector based on configuration
func NewConnector(cfg *config.Config) (Connector, error) {
	switch cfg.ConnectionMode {
	case "local":
		return NewLocalConnector(cfg), nil
	case "ssh":
		return NewSSHConnector(cfg), nil
	default:
		return nil, fmt.Errorf("unsupported connection mode: %s", cfg.ConnectionMode)
	}
}
