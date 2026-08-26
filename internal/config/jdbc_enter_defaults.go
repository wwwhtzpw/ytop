package config

import (
	"fmt"
	"net"
	"strings"
	"time"
)

// -E 专用 lab 默认 (禁止用于非 JdbcEnter 路径).
const (
	jdbcEnterDefaultUser     = "sys"
	jdbcEnterDefaultPort     = 1688
	jdbcEnterDefaultPassword = "Yashan1!"
)

// localIPv4ForJdbcEnter 可在测试中替换.
var localIPv4ForJdbcEnter = detectLocalIPv4ForJdbcEnter

// ApplyJdbcEnterDefaultsForTest 导出供 test/go 调用.
func ApplyJdbcEnterDefaultsForTest(cfg *Config) error {
	return applyJdbcEnterDefaults(cfg)
}

// SetLocalIPv4ForJdbcEnterForTest 注入本机 IP 解析; 返回恢复函数.
func SetLocalIPv4ForJdbcEnterForTest(f func() (string, error)) func() {
	prev := localIPv4ForJdbcEnter
	if f == nil {
		localIPv4ForJdbcEnter = detectLocalIPv4ForJdbcEnter
	} else {
		localIPv4ForJdbcEnter = f
	}
	return func() { localIPv4ForJdbcEnter = prev }
}

// IsUsableJdbcLocalIPv4ForTest 导出过滤规则供单测.
func IsUsableJdbcLocalIPv4ForTest(ipStr string) bool {
	return isUsableJdbcLocalIPv4(net.ParseIP(ipStr))
}

// applyJdbcEnterDefaults 仅在 -E 时填充缺省; 不改动 SSH/监控等非 JDBC 默认.
func applyJdbcEnterDefaults(cfg *Config) error {
	if cfg == nil || !cfg.JdbcEnter {
		return nil
	}
	if strings.TrimSpace(cfg.JdbcUser) == "" {
		cfg.JdbcUser = jdbcEnterDefaultUser
	}
	if !cfg.JdbcPortSet || cfg.JdbcPort <= 0 {
		cfg.JdbcPort = jdbcEnterDefaultPort
		cfg.JdbcPortSet = true
	}
	if !cfg.JdbcPasswordSet {
		cfg.JdbcPassword = jdbcEnterDefaultPassword
		cfg.JdbcPasswordSet = true
	}
	if strings.TrimSpace(cfg.JdbcHost) == "" {
		ip, err := localIPv4ForJdbcEnter()
		if err != nil {
			return fmt.Errorf("-E: cannot resolve local IPv4 for empty -t: %w (pass -t <db-host>)", err)
		}
		cfg.JdbcHost = ip
	}
	return nil
}

// detectLocalIPv4ForJdbcEnter: 优先默认路由出口 IPv4; 否则枚举跳过 127/8 与 169/8.
func detectLocalIPv4ForJdbcEnter() (string, error) {
	if ip := ipv4ViaDefaultRouteUDP(); ip != "" {
		return ip, nil
	}
	if ip := firstNonLoopbackNon169IPv4(); ip != "" {
		return ip, nil
	}
	return "", fmt.Errorf("no suitable IPv4 address found")
}

func ipv4ViaDefaultRouteUDP() string {
	// 向公网 DNS 建 UDP (不真正要求应答) 以绑定默认路由网卡地址.
	d := net.Dialer{Timeout: 500 * time.Millisecond}
	conn, err := d.Dial("udp4", "8.8.8.8:53")
	if err != nil {
		conn, err = d.Dial("udp4", "1.1.1.1:53")
		if err != nil {
			return ""
		}
	}
	defer conn.Close()
	la, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok || la == nil || la.IP == nil {
		return ""
	}
	ip4 := la.IP.To4()
	if ip4 == nil || !isUsableJdbcLocalIPv4(ip4) {
		return ""
	}
	return ip4.String()
}

func firstNonLoopbackNon169IPv4() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			ip4 := ip.To4()
			if ip4 == nil || !isUsableJdbcLocalIPv4(ip4) {
				continue
			}
			return ip4.String()
		}
	}
	return ""
}

func isUsableJdbcLocalIPv4(ip net.IP) bool {
	if ip == nil || ip.IsLoopback() || ip.IsUnspecified() {
		return false
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	// 跳过 169.0.0.0/8 (含链路本地 169.254/16)
	if ip4[0] == 169 {
		return false
	}
	return true
}
