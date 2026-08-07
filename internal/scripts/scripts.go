package scripts

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

const scriptHeaderScanMaxLines = 60

// ExternalEmbeddedFS is set by main package if scripts are embedded at the project root
var ExternalEmbeddedFS fs.FS = nil

// CurrentDBType controls which sql subdirectory is used for script lookups.
// Set this before calling any script functions. Defaults to "yashandb".
var CurrentDBType = "yashandb"

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

// GetSQLScript loads a SQL script from embedded files or filesystem.
// Explicit OS paths (e.g. ./we.sql, d:\we.sql) are read from the filesystem first; otherwise embedded/scripts dir.
// When CurrentDBVersion is set, logical names such as we.sql resolve to the best matching variant.
func GetSQLScript(name string) (string, error) {
	if isExplicitPath(name) {
		// Explicit path: read from OS filesystem
		content, err := os.ReadFile(name)
		if err != nil {
			return "", fmt.Errorf("failed to read SQL script from filesystem %s: %w", name, err)
		}
		LastResolvedScript = name
		return string(content), nil
	}

	resolved := name
	LastResolvedScript = name
	// 逻辑名: 按引擎变体 (_yjdbc/_yasql) + 可选版本解析; 请求名已带引擎/版本后缀则不改写
	if _, engPart, verPart := parseScriptNameParts(name); engPart == "" && verPart == "" {
		if picked, err := ResolveSQLScriptNameForEngine(name, CurrentSQLEngine, CurrentDBVersion); err == nil {
			resolved = picked
		} else if strings.TrimSpace(CurrentDBVersion) != "" && !sqlScriptExists(name) {
			return "", err
		}
	}
	LastResolvedScript = resolved

	content, err := readSQLScriptBytes(resolved)
	if err != nil {
		if resolved != name {
			return "", fmt.Errorf("failed to read SQL script %s (resolved from %s for DB version %s): %w",
				resolved, name, CurrentDBVersion, err)
		}
		return "", fmt.Errorf("failed to read SQL script %s", name)
	}
	return string(content), nil
}

// GetOSScript loads an OS script from embedded files or filesystem.
// Explicit OS paths (e.g. ./foo.sh, d:\foo.sh) are read from the filesystem first; otherwise embedded/scripts dir.
func GetOSScript(name string) (string, error) {
	content, err := GetOSBytes(name)
	if err != nil {
		return "", err
	}
	return string(content), nil
}

// GetOSBytes loads an OS asset (script or binary companion such as .jar) as raw bytes.
func GetOSBytes(name string) ([]byte, error) {
	if isExplicitPath(name) {
		content, err := os.ReadFile(name)
		if err != nil {
			return nil, fmt.Errorf("failed to read OS asset from filesystem %s: %w", name, err)
		}
		return content, nil
	}

	scriptsDir, err := getScriptDir()
	if err == nil && scriptsDir != "" {
		scriptPath := filepath.Join(scriptsDir, "os", name)
		content, err := os.ReadFile(scriptPath)
		if err == nil {
			return content, nil
		}
	}

	{
		path := "os/" + name
		content, err := fs.ReadFile(defaultEmbeddedFS, path)
		if err == nil {
			return content, nil
		}
	}

	if ExternalEmbeddedFS != nil {
		scriptPath := filepath.Join("scripts", "os", name)
		content, err := fs.ReadFile(ExternalEmbeddedFS, scriptPath)
		if err == nil {
			return content, nil
		}
	}

	return nil, fmt.Errorf("failed to read OS asset %s", name)
}

// ListOSCompanions returns companion filenames staged next to an OS script when present.
// Convention: same basename stem + ".jar" (e.g. sql_collect.sh -> sql_collect.jar).
// Explicit script paths resolve companions from the same directory on the filesystem.
func ListOSCompanions(scriptName string) []string {
	base := filepath.Base(scriptName)
	stem := strings.TrimSuffix(base, filepath.Ext(base))
	if stem == "" {
		return nil
	}
	candidates := []string{stem + ".jar"}
	var out []string
	if isExplicitPath(scriptName) {
		dir := filepath.Dir(scriptName)
		for _, c := range candidates {
			if _, err := os.Stat(filepath.Join(dir, c)); err == nil {
				out = append(out, c)
			}
		}
		return out
	}
	for _, c := range candidates {
		if _, err := GetOSBytes(c); err == nil {
			out = append(out, c)
		}
	}
	return out
}

// LoadOSCompanionBytes loads companion bytes for an OS script.
// For explicit script paths, companions are read from the script's directory.
func LoadOSCompanionBytes(scriptName, companionName string) ([]byte, error) {
	if isExplicitPath(scriptName) {
		path := filepath.Join(filepath.Dir(scriptName), companionName)
		content, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("failed to read OS companion %s: %w", path, err)
		}
		return content, nil
	}
	return GetOSBytes(companionName)
}

// isListableOSScript reports whether filename should appear in ytop -S (os).
func isListableOSScript(filename string) bool {
	switch strings.ToLower(filepath.Ext(filename)) {
	case ".sh", ".bash", ".zsh", ".ksh", ".py", ".c", ".ps1", ".bat", ".cmd":
		return true
	default:
		return false
	}
}

// isExplicitPath checks if path is an explicit OS filesystem path (not an embedded script name).
// When true, script is read from the OS (e.g. ./we.sql, /tmp/we.sql, d:\we.sql).
func isExplicitPath(path string) bool {
	// Absolute path (Unix /path or Windows C:\path)
	if filepath.IsAbs(path) {
		return true
	}

	// Windows-style drive letter (e.g. d:\we.sql, D:/we.sql) — recognize on all platforms
	if len(path) >= 3 {
		c := path[0]
		if (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z') && path[1] == ':' && (path[2] == '\\' || path[2] == '/') {
			return true
		}
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
	Description string // Purpose line (normalized)
	Versions    string // Applicable DB versions (from header metadata)
}

// SearchScripts searches for scripts matching pattern (filesystem first, then embedded FS)
func SearchScripts(pattern string) ([]ScriptInfo, error) {
	scriptsDir, _ := getScriptDir() // ignore err; always fall back to embedded FS

	// Compile regex pattern
	regex, err := getRegexForPattern(pattern)
	if err != nil {
		return nil, err
	}

	var results []ScriptInfo

	// Search in filesystem when scripts dir is available
	if scriptsDir != "" {
		sqlDir := filepath.Join(scriptsDir, "sql", CurrentDBType)
		searchInDirectory(sqlDir, "sql", regex, &results)

		osDir := filepath.Join(scriptsDir, "os")
		searchInDirectory(osDir, "os", regex, &results)

		if len(results) > 0 {
			return results, nil
		}
	}

	// Search default embedded FS
	searchInEmbeddedFS(defaultEmbeddedFS, "sql/"+CurrentDBType, regex, &results)
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

// getRegexForPattern creates a regex matcher for the pattern (supports full regex, e.g. .* for all, snapshot|user for alternation)
func getRegexForPattern(pattern string) (func(string) bool, error) {
	if strings.TrimSpace(pattern) == "" {
		pattern = ".*"
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return nil, fmt.Errorf("invalid regex %q: %w", pattern, err)
	}
	return func(s string) bool {
		return re.MatchString(s)
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
		if scriptType == "os" && !isListableOSScript(filename) {
			continue
		}
		if !matcher(filename) {
			continue
		}

		content, err := os.ReadFile(filepath.Join(dir, filename))
		if err != nil {
			continue
		}
		*results = append(*results, buildScriptInfo(scriptType, filename, content))
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

		if scriptType == "os" && !isListableOSScript(filename) {
			return nil
		}
		if !matcher(filename) {
			return nil
		}

		// Read file content for description
		content, err := fs.ReadFile(embeddedFS, path)
		if err != nil {
			return nil
		}

		*results = append(*results, buildScriptInfo(scriptType, filename, content))

		return nil
	})
}

// buildScriptInfo parses Purpose from the script header for -S listing.
func buildScriptInfo(scriptType, filename string, content []byte) ScriptInfo {
	fields := parseScriptHeaderFields(content)
	return ScriptInfo{
		Type:        scriptType,
		Filename:    filename,
		Description: fields.Purpose,
		Versions:    formatScriptVersionLabel(fields, filename),
	}
}

func formatScriptVersionLabel(fields scriptHeaderFields, filename string) string {
	if fields.Supported != "" {
		return fields.Supported
	}
	if _, suffix := parseScriptFilename(filename); suffix != "" {
		return suffix
	}
	return "all"
}

type scriptHeaderFields struct {
	FileName  string
	Purpose   string
	Created   string
	Supported string
}

func extractScriptDescription(content []byte) string {
	if !utf8.Valid(content) {
		return "[binary file]"
	}
	return parseScriptHeaderFields(content).Purpose
}

func parseScriptHeaderFields(content []byte) scriptHeaderFields {
	lines := strings.Split(string(content), "\n")
	if len(lines) > scriptHeaderScanMaxLines {
		lines = lines[:scriptHeaderScanMaxLines]
	}
	var fields scriptHeaderFields
	for _, raw := range lines {
		line := stripScriptCommentLine(raw)
		if line == "" {
			continue
		}
		switch {
		case strings.HasPrefix(line, "File Name:"):
			fields.FileName = strings.TrimSpace(strings.TrimPrefix(line, "File Name:"))
		case strings.HasPrefix(line, "Purpose:"):
			fields.Purpose = normalizeScriptDescription(line)
		case strings.HasPrefix(line, "Created:"):
			fields.Created = strings.TrimSpace(strings.TrimPrefix(line, "Created:"))
		case strings.HasPrefix(line, "Supported:"):
			fields.Supported = strings.TrimSpace(strings.TrimPrefix(line, "Supported:"))
		}
	}
	return fields
}

func stripScriptCommentLine(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || strings.HasPrefix(s, "#!") {
		return ""
	}
	if strings.HasPrefix(s, "--") {
		return strings.TrimSpace(strings.TrimPrefix(s, "--"))
	}
	if strings.HasPrefix(s, "#") {
		return strings.TrimSpace(strings.TrimPrefix(s, "#"))
	}
	if strings.HasPrefix(s, "//") {
		return strings.TrimSpace(strings.TrimPrefix(s, "//"))
	}
	return ""
}

// getDescriptionFromContent extracts Purpose from script content (for tests and callers).
func getDescriptionFromContent(content []byte) string {
	return extractScriptDescription(content)
}

// normalizeScriptDescription strips the standard "Purpose:" header prefix from script comments.
func normalizeScriptDescription(line string) string {
	line = strings.TrimSpace(line)
	for strings.HasPrefix(line, "Purpose:") {
		line = strings.TrimSpace(strings.TrimPrefix(line, "Purpose:"))
	}
	return line
}

// ReadScriptContent reads and returns the content of a script file
// Returns content, isBinary flag, and error
func ReadScriptContent(filename string) (string, bool, error) {
	if isExplicitPath(filename) {
		content, err := os.ReadFile(filename)
		if err != nil {
			return "", false, fmt.Errorf("failed to read script file: %w", err)
		}
		if !utf8.Valid(content) {
			return "", true, nil
		}
		return string(content), false, nil
	}

	// Try typed loaders (embedded + filesystem scripts dir)
	if content, err := LoadScriptByName(filename); err == nil {
		if !utf8.Valid([]byte(content)) {
			return "", true, nil
		}
		return content, false, nil
	}

	// First try filesystem legacy paths
	scriptsDir, err := getScriptDir()
	if err == nil && scriptsDir != "" {
		var scriptPath string

		// Determine if it's a SQL script or OS script
		if strings.HasSuffix(filename, ".sql") {
			scriptPath = filepath.Join(scriptsDir, "sql", CurrentDBType, filename)
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
			path = "sql/" + CurrentDBType + "/" + filename
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
			scriptPath = filepath.Join("scripts", "sql", CurrentDBType, filename)
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

// SourceKind identifies compile (.c) vs interpret (.py) source execution.
type SourceKind int

const (
	SourceKindNone SourceKind = iota
	SourceKindC
	SourceKindPy
)

// FirstToken returns the first whitespace-separated token of input.
func FirstToken(input string) string {
	fields := strings.Fields(strings.TrimSpace(input))
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

// IsSQLScriptInput reports whether the first token names a SQL script (.sql).
func IsSQLScriptInput(input string) bool {
	token := FirstToken(input)
	return strings.HasSuffix(strings.ToLower(token), ".sql")
}

// SourceKindFromName returns the source kind for a filename or path.
func SourceKindFromName(name string) SourceKind {
	ext := strings.ToLower(filepath.Ext(name))
	switch ext {
	case ".c":
		return SourceKindC
	case ".py":
		return SourceKindPy
	default:
		return SourceKindNone
	}
}

// GetCSource loads a C source from os/ (embedded or filesystem) or an explicit path.
func GetCSource(name string) (string, error) {
	content, err := GetOSScript(name)
	if err != nil {
		return "", fmt.Errorf("failed to read C source %s", name)
	}
	return content, nil
}

// GetPySource loads a Python source from os/ (embedded or filesystem) or an explicit path.
func GetPySource(name string) (string, error) {
	content, err := GetOSScript(name)
	if err != nil {
		return "", fmt.Errorf("failed to read Python source %s", name)
	}
	return content, nil
}

// LoadScriptByName loads script content by filename extension (.sql or os/ including .c/.py).
func LoadScriptByName(name string) (string, error) {
	if strings.HasSuffix(strings.ToLower(name), ".sql") {
		return GetSQLScript(name)
	}
	return GetOSScript(name)
}
