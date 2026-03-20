package connector

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/yihan/ytop/internal/config"
	"github.com/yihan/ytop/internal/logger"
)

// readSSHKey reads SSH private key from file
func readSSHKey(keyFile string) ([]byte, error) {
	key, err := os.ReadFile(keyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read SSH key file: %w", err)
	}
	return key, nil
}

// SSHConnectionPool manages SSH client connection (not sessions)
// Sessions are created on-demand and closed after use
type SSHConnectionPool struct {
	cfg       *config.Config
	client    *ssh.Client
	mu        sync.Mutex
	connected bool
}

// NewSSHConnectionPool creates a new SSH connection pool
func NewSSHConnectionPool(cfg *config.Config, maxSize int) *SSHConnectionPool {
	return &SSHConnectionPool{
		cfg: cfg,
	}
}

// Connect establishes the SSH connection
func (p *SSHConnectionPool) Connect(ctx context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.connected && p.client != nil {
		return nil
	}

	// Prepare SSH client config
	sshConfig := &ssh.ClientConfig{
		User:            p.cfg.SSHUser,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         time.Duration(p.cfg.SSHTimeout) * time.Second,
	}

	// Add authentication method
	if p.cfg.SSHPassword != "" {
		sshConfig.Auth = append(sshConfig.Auth, ssh.Password(p.cfg.SSHPassword))
		sshConfig.Auth = append(sshConfig.Auth, ssh.KeyboardInteractive(func(user, instruction string, questions []string, echos []bool) ([]string, error) {
			answers := make([]string, len(questions))
			for i := range answers {
				answers[i] = p.cfg.SSHPassword
			}
			return answers, nil
		}))
	}

	if p.cfg.SSHKeyFile != "" {
		key, err := readSSHKey(p.cfg.SSHKeyFile)
		if err != nil {
			return fmt.Errorf("failed to read SSH key file '%s': %w", p.cfg.SSHKeyFile, err)
		}

		signer, err := ssh.ParsePrivateKey(key)
		if err != nil {
			return fmt.Errorf("failed to parse SSH key file '%s': %w", p.cfg.SSHKeyFile, err)
		}

		sshConfig.Auth = append(sshConfig.Auth, ssh.PublicKeys(signer))
	}

	// Connect to SSH server
	addr := fmt.Sprintf("%s:%d", p.cfg.SSHHost, p.cfg.SSHPort)

	// Build connection info for debugging
	var authMethod string
	if p.cfg.SSHPassword != "" && p.cfg.SSHKeyFile != "" {
		authMethod = "password + key"
	} else if p.cfg.SSHPassword != "" {
		authMethod = "password"
	} else if p.cfg.SSHKeyFile != "" {
		authMethod = "key"
	} else {
		authMethod = "none"
	}

	if p.cfg.DebugMode {
		logger.Debug("SSH Connection attempt:\n")
		logger.Debug("  Host: %s\n", p.cfg.SSHHost)
		logger.Debug("  Port: %d\n", p.cfg.SSHPort)
		logger.Debug("  User: %s\n", p.cfg.SSHUser)
		logger.Debug("  Auth: %s\n", authMethod)
		if p.cfg.SSHKeyFile != "" {
			logger.Debug("  Key file: %s\n", p.cfg.SSHKeyFile)
		}
	}

	client, err := ssh.Dial("tcp", addr, sshConfig)
	if err != nil {
		// Build detailed error message with connection info
		var errorMsg strings.Builder
		fmt.Fprintf(&errorMsg, "SSH connection failed:\n")
		fmt.Fprintf(&errorMsg, "  Host: %s\n", p.cfg.SSHHost)
		fmt.Fprintf(&errorMsg, "  Port: %d\n", p.cfg.SSHPort)
		fmt.Fprintf(&errorMsg, "  User: %s\n", p.cfg.SSHUser)
		fmt.Fprintf(&errorMsg, "  Auth method: %s\n", authMethod)
		if p.cfg.SSHKeyFile != "" {
			fmt.Fprintf(&errorMsg, "  Key file: %s\n", p.cfg.SSHKeyFile)
		}

		// Build test command for user
		fmt.Fprintf(&errorMsg, "\nTest command:\n")
		if p.cfg.SSHKeyFile != "" {
			// Use key file authentication
			fmt.Fprintf(&errorMsg, "  ssh -i %s -p %d %s@%s\n",
				p.cfg.SSHKeyFile, p.cfg.SSHPort, p.cfg.SSHUser, p.cfg.SSHHost)
		} else {
			// Use password authentication
			fmt.Fprintf(&errorMsg, "  ssh -p %d %s@%s\n",
				p.cfg.SSHPort, p.cfg.SSHUser, p.cfg.SSHHost)
		}

		fmt.Fprintf(&errorMsg, "\nOriginal error: %v\n", err)

		return fmt.Errorf("%s", errorMsg.String())
	}

	p.client = client
	p.connected = true

	if p.cfg.DebugMode {
		logger.Debug("SSH connection pool connected to %s\n", addr)
	}

	return nil
}

// NewSession creates a new SSH session from the pool's client
func (p *SSHConnectionPool) NewSession() (*ssh.Session, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if !p.connected || p.client == nil {
		return nil, fmt.Errorf("not connected")
	}

	session, err := p.client.NewSession()
	if err != nil {
		return nil, fmt.Errorf("failed to create SSH session: %w", err)
	}

	if p.cfg.DebugMode {
		logger.Debug("Created new SSH session from pool\n")
	}

	return session, nil
}

// Close closes the connection
func (p *SSHConnectionPool) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Close client
	if p.client != nil {
		err := p.client.Close()
		p.client = nil
		p.connected = false
		return err
	}

	return nil
}

// IsConnected returns connection status
func (p *SSHConnectionPool) IsConnected() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.connected && p.client != nil
}

