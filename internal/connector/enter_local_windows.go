//go:build windows

package connector

import (
	"fmt"

	"github.com/yihan/ytop/internal/config"
)

func RunLocalInteractiveCLI(cfg *config.Config) (int, error) {
	_ = cfg
	return 1, fmt.Errorf("interactive CLI (-e) is not supported on Windows in this version")
}
