package scripts

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// ExternalEmbeddedFS is set by main package if scripts are embedded at the project root
var ExternalEmbeddedFS fs.FS = nil

// getScriptDir returns the scripts directory path
func getScriptDir() (string, error) {
	// Get executable path
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}

	// Get directory of executable
	exeDir := filepath.Dir(exe)

	// Try to find scripts directory
	// First try: same directory as executable
	scriptsDir := filepath.Join(exeDir, "scripts")
	if _, err := os.Stat(scriptsDir); err == nil {
		return scriptsDir, nil
	}

	// Second try: parent directory (for development)
	scriptsDir = filepath.Join(exeDir, "..", "scripts")
	if _, err := os.Stat(scriptsDir); err == nil {
		return scriptsDir, nil
	}

	// Third try: current working directory
	cwd, err := os.Getwd()
	if err == nil {
		scriptsDir = filepath.Join(cwd, "scripts")
		if _, err := os.Stat(scriptsDir); err == nil {
			return scriptsDir, nil
		}
	}

	// If no filesystem scripts found, we'll use embedded scripts (if available)
	if ExternalEmbeddedFS != nil {
		return "", nil
	}

	return "", fmt.Errorf("scripts directory not found")
}

// GetSQLScript loads a SQL script from embedded files or filesystem
func GetSQLScript(name string) (string, error) {
	// Check if it's an explicit path (absolute or relative)
	if isExplicitPath(name) {
		// Read from filesystem
		content, err := os.ReadFile(name)
		if err != nil {
			return "", fmt.Errorf("failed to read SQL script from filesystem %s: %w", name, err)
		}
		return string(content), nil
	}

	// First try to read from filesystem
	scriptsDir, err := getScriptDir()
	if err == nil && scriptsDir != "" {
		scriptPath := filepath.Join(scriptsDir, "sql", name)
		content, err := os.ReadFile(scriptPath)
		if err == nil {
			return string(content), nil
		}
	}

	// Try default embedded FS (root scripts/sql, scripts/os copied to internal/scripts at build)
	{
		path := "sql/" + name
		content, err := fs.ReadFile(defaultEmbeddedFS, path)
		if err == nil {
			return string(content), nil
		}
	}

	// Try external embedded filesystem (from project root, legacy)
	if ExternalEmbeddedFS != nil {
		scriptPath := filepath.Join("scripts", "sql", name)
		content, err := fs.ReadFile(ExternalEmbeddedFS, scriptPath)
		if err == nil {
			return string(content), nil
		}
	}

	return "", fmt.Errorf("failed to read SQL script %s", name)
}

// GetOSScript loads an OS script from embedded files or filesystem
func GetOSScript(name string) (string, error) {
	// Check if it's an explicit path (absolute or relative)
	if isExplicitPath(name) {
		// Read from filesystem
		content, err := os.ReadFile(name)
		if err != nil {
			return "", fmt.Errorf("failed to read OS script from filesystem %s: %w", name, err)
		}
		return string(content), nil
	}

	// First try to read from filesystem
	scriptsDir, err := getScriptDir()
	if err == nil && scriptsDir != "" {
		scriptPath := filepath.Join(scriptsDir, "os", name)
		content, err := os.ReadFile(scriptPath)
		if err == nil {
			return string(content), nil
		}
	}

	// Try default embedded FS (root scripts copied to internal/scripts at build)
	{
		path := "os/" + name
		content, err := fs.ReadFile(defaultEmbeddedFS, path)
		if err == nil {
			return string(content), nil
		}
	}

	// Try external embedded filesystem (legacy)
	if ExternalEmbeddedFS != nil {
		scriptPath := filepath.Join("scripts", "os", name)
		content, err := fs.ReadFile(ExternalEmbeddedFS, scriptPath)
		if err == nil {
			return string(content), nil
		}
	}

	return "", fmt.Errorf("failed to read OS script %s", name)
}

// isExplicitPath checks if path is an explicit filesystem path
func isExplicitPath(path string) bool {
	// Absolute path
	if filepath.IsAbs(path) {
		return true
	}

	// Relative path with ./ or ../
	if strings.HasPrefix(path, "./") || strings.HasPrefix(path, "../") {
		return true
	}

	// Windows relative path with .\ or ..\
	if strings.HasPrefix(path, ".\\") || strings.HasPrefix(path, "..\\") {
		return true
	}

	return false
}

// ReplaceSQLID replaces &&sqlid with actual SQL ID
func ReplaceSQLID(script, sqlID string) string {
	return strings.ReplaceAll(script, "&&sqlid", sqlID)
}

// WriteCommandOutput writes command output to a file
func WriteCommandOutput(command, output string) error {
	// Sanitize command name for filename
	filename := strings.ReplaceAll(command, " ", "_")
	filename = strings.ReplaceAll(filename, "/", "_")
	filename = "output_" + filename + ".txt"

	return os.WriteFile(filename, []byte(output), 0644)
}

// WriteSQLOutput writes SQL output to a file
func WriteSQLOutput(sqlID, output string) error {
	filename := fmt.Sprintf("sql_%s.txt", sqlID)
	return os.WriteFile(filename, []byte(output), 0644)
}

// ScriptInfo holds information about a script file
type ScriptInfo struct {
	Type        string // "sql" or "os"
	Filename    string
	Description string
}

// SearchScripts searches for scripts matching pattern
func SearchScripts(pattern string) ([]ScriptInfo, error) {
	// First try filesystem
	scriptsDir, err := getScriptDir()
	if err != nil && scriptsDir == "" {
		return nil, fmt.Errorf("failed to locate scripts directory: %w", err)
	}

	// Compile regex pattern
	regex, err := getRegexForPattern(pattern)
	if err != nil {
		return nil, err
	}

	var results []ScriptInfo

	// Search in filesystem
	if scriptsDir != "" {
		sqlDir := filepath.Join(scriptsDir, "sql")
		searchInDirectory(sqlDir, "sql", regex, &results)

		osDir := filepath.Join(scriptsDir, "os")
		searchInDirectory(osDir, "os", regex, &results)

		if len(results) > 0 {
			return results, nil
		}
	}

	// Try default embedded FS (sql + os at root of embed)
	searchInEmbeddedFS(defaultEmbeddedFS, "sql", regex, &results)
	searchInEmbeddedFS(defaultEmbeddedFS, "os", regex, &results)
	if len(results) > 0 {
		return results, nil
	}

	// Try external embedded filesystem (legacy)
	if ExternalEmbeddedFS != nil {
		searchInEmbeddedFS(ExternalEmbeddedFS, "scripts", regex, &results)
		if len(results) > 0 {
			return results, nil
		}
	}

	return []ScriptInfo{}, nil
}

// getRegexForPattern creates a regex matcher for the pattern
func getRegexForPattern(pattern string) (func(string) bool, error) {
	if pattern == ".*" {
		// Match everything
		return func(s string) bool {
			return true
		}, nil
	}

	// Use simple contains matching for simplicity
	return func(s string) bool {
		return strings.Contains(s, pattern)
	}, nil
}

// searchInDirectory searches for scripts in a specific directory
func searchInDirectory(dir, scriptType string, matcher func(string) bool, results *[]ScriptInfo) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		filename := entry.Name()
		if !matcher(filename) {
			continue
		}

		// Read description from file
		desc := getDescriptionFromPath(filepath.Join(dir, filename))
		*results = append(*results, ScriptInfo{
			Type:        scriptType,
			Filename:    filename,
			Description: desc,
		})
	}
}

// searchInEmbeddedFS searches for scripts in embedded filesystem
func searchInEmbeddedFS(embeddedFS fs.FS, basePath string, matcher func(string) bool, results *[]ScriptInfo) {
	fs.WalkDir(embeddedFS, basePath, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			return nil
		}

		// Extract filename and type (support "sql/we.sql" and "scripts/sql/we.sql")
		parts := strings.Split(path, "/")
		if len(parts) < 2 {
			return nil
		}
		scriptType := parts[0] // "sql" or "os" for defaultEmbeddedFS; "scripts" for legacy
		filename := parts[len(parts)-1]
		if scriptType == "scripts" && len(parts) >= 3 {
			scriptType = parts[1] // "sql" or "os"
		}

		if !matcher(filename) {
			return nil
		}

		// Read file content for description
		content, err := fs.ReadFile(embeddedFS, path)
		if err != nil {
			return nil
		}

		desc := getDescriptionFromContent(content)
		*results = append(*results, ScriptInfo{
			Type:        scriptType,
			Filename:    filename,
			Description: desc,
		})

		return nil
	})
}

// getDescriptionFromPath reads description from a file path
func getDescriptionFromPath(filePath string) string {
	file, err := os.Open(filePath)
	if err != nil {
		return ""
	}
	defer file.Close()

	// Check if file is text (by reading first few bytes)
	buf := make([]byte, 512)
	n, err := file.Read(buf)
	if err != nil {
		return ""
	}

	// Check if content is valid UTF-8 (text file)
	if !utf8.Valid(buf[:n]) {
		return "[binary file]"
	}

	// Reset to beginning
	file.Seek(0, 0)

	// Read second line for description
	lines := strings.Split(string(buf[:n]), "\n")
	if len(lines) >= 2 {
		line := strings.TrimSpace(lines[1])
		// Remove comment markers
		line = strings.TrimPrefix(line, "#")
		line = strings.TrimPrefix(line, "--")
		line = strings.TrimSpace(line)
		return line
	}

	return ""
}

// getDescriptionFromContent extracts description from script content
func getDescriptionFromContent(content []byte) string {
	// Check if content is valid UTF-8 (text file)
	if !utf8.Valid(content) {
		return "[binary file]"
	}

	// Split content into lines
	lines := strings.Split(string(content), "\n")
	if len(lines) >= 2 {
		// Get second line for description
		line := strings.TrimSpace(lines[1])
		// Remove comment markers
		line = strings.TrimPrefix(line, "#")
		line = strings.TrimPrefix(line, "--")
		line = strings.TrimSpace(line)
		return line
	}

	return ""
}

// ReadScriptContent reads and returns the content of a script file
// Returns content, isBinary flag, and error
func ReadScriptContent(filename string) (string, bool, error) {
	// First try filesystem
	scriptsDir, err := getScriptDir()
	if err == nil && scriptsDir != "" {
		var scriptPath string

		// Determine if it's a SQL script or OS script
		if strings.HasSuffix(filename, ".sql") {
			scriptPath = filepath.Join(scriptsDir, "sql", filename)
		} else {
			scriptPath = filepath.Join(scriptsDir, "os", filename)
		}

		// Check if file exists
		if _, err := os.Stat(scriptPath); err == nil {
			// Read file content
			content, err := os.ReadFile(scriptPath)
			if err != nil {
				return "", false, fmt.Errorf("failed to read script file: %w", err)
			}

			// Check if content is valid UTF-8 (text file)
			if !utf8.Valid(content) {
				return "", true, nil // Binary file
			}

			return string(content), false, nil
		}
	}

	// Try default embedded FS
	{
		var path string
		if strings.HasSuffix(filename, ".sql") {
			path = "sql/" + filename
		} else {
			path = "os/" + filename
		}
		content, err := fs.ReadFile(defaultEmbeddedFS, path)
		if err == nil {
			if !utf8.Valid(content) {
				return "", true, nil
			}
			return string(content), false, nil
		}
	}

	// Try external embedded filesystem (legacy)
	if ExternalEmbeddedFS != nil {
		var scriptPath string
		if strings.HasSuffix(filename, ".sql") {
			scriptPath = filepath.Join("scripts", "sql", filename)
		} else {
			scriptPath = filepath.Join("scripts", "os", filename)
		}
		content, err := fs.ReadFile(ExternalEmbeddedFS, scriptPath)
		if err == nil {
			if !utf8.Valid(content) {
				return "", true, nil
			}
			return string(content), false, nil
		}
	}

	return "", false, fmt.Errorf("script file not found: %s", filename)
}
