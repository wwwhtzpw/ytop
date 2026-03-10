# Script Path Resolution

## Overview
When pressing 's' in monitoring mode to execute SQL scripts, yastop now supports flexible path resolution:

## Path Resolution Rules

### 1. Simple Filename (Embedded Scripts)
**Input:** `we.sql`
**Behavior:** Searches in embedded `scripts/sql/` directory
**Example:**
```
Enter SQL script (.sql) or OS command: we.sql
→ Loads from embedded scripts/sql/we.sql
```

### 2. Absolute Path (Linux/Mac)
**Input:** `/home/user/scripts/my_script.sql`
**Behavior:** Reads directly from filesystem at specified absolute path
**Example:**
```
Enter SQL script (.sql) or OS command: /home/user/scripts/my_script.sql
→ Loads from /home/user/scripts/my_script.sql
```

### 3. Absolute Path (Windows)
**Input:** `D:\scripts\my_script.sql` or `D:/scripts/my_script.sql`
**Behavior:** Reads directly from filesystem at specified absolute path
**Example:**
```
Enter SQL script (.sql) or OS command: D:\scripts\my_script.sql
→ Loads from D:\scripts\my_script.sql
```

### 4. Relative Path (Current Directory)
**Input:** `./my_script.sql`
**Behavior:** Reads from current working directory
**Example:**
```
Enter SQL script (.sql) or OS command: ./my_script.sql
→ Loads from ./my_script.sql (relative to current directory)
```

### 5. Relative Path (Parent Directory)
**Input:** `../scripts/my_script.sql`
**Behavior:** Reads from parent directory path
**Example:**
```
Enter SQL script (.sql) or OS command: ../scripts/my_script.sql
→ Loads from ../scripts/my_script.sql
```

### 6. Windows Relative Path
**Input:** `..\scripts\my_script.sql` or `.\my_script.sql`
**Behavior:** Reads from relative path using Windows path separators
**Example:**
```
Enter SQL script (.sql) or OS command: .\my_script.sql
→ Loads from .\my_script.sql
```

## Implementation Details

The path resolution logic is implemented in `internal/scripts/scripts.go`:

```go
func isExplicitPath(path string) bool {
    // Absolute path (Unix: /path, Windows: C:\path or C:/path)
    if filepath.IsAbs(path) {
        return true
    }

    // Explicit relative path: ./ or ../
    if strings.HasPrefix(path, "./") || strings.HasPrefix(path, "../") {
        return true
    }

    // Windows explicit relative path: .\ or ..\
    if strings.HasPrefix(path, ".\\") || strings.HasPrefix(path, "..\\") {
        return true
    }

    return false
}
```

## Usage Examples

### Example 1: Using Embedded Script
```bash
# In monitoring mode, press 's'
Enter SQL script (.sql) or OS command: sql.sql
# Loads from embedded scripts/sql/sql.sql
```

### Example 2: Using Local Script (Relative)
```bash
# In monitoring mode, press 's'
Enter SQL script (.sql) or OS command: ./test_script.sql
# Loads from current directory
```

### Example 3: Using Local Script (Absolute)
```bash
# In monitoring mode, press 's'
Enter SQL script (.sql) or OS command: /tmp/my_query.sql
# Loads from /tmp/my_query.sql
```

### Example 4: Windows Absolute Path
```bash
# In monitoring mode, press 's'
Enter SQL script (.sql) or OS command: D:\database\scripts\report.sql
# Loads from D:\database\scripts\report.sql
```

## Variable Substitution

Scripts can contain variables using `&var` or `&&var` syntax. When such scripts are executed, yastop will prompt for values:

```sql
-- Example script with variables
SELECT * FROM users WHERE user_id = &user_id;
SELECT * FROM orders WHERE order_date > '&&start_date';
```

When executed:
```
Enter value for &user_id: 12345
Enter value for &&start_date: 2024-01-01
```

## OS Scripts

The same path resolution logic applies to OS scripts in `scripts/os/` directory:

```bash
# Simple name - searches in embedded scripts/os/
Enter SQL script (.sql) or OS command: monitor.sh

# Explicit path - reads from filesystem
Enter SQL script (.sql) or OS command: ./custom_monitor.sh
```

## Notes

- Embedded scripts are compiled into the binary at build time
- Filesystem scripts are read at runtime
- Path separators are handled cross-platform by Go's `filepath` package
- Error messages clearly indicate whether the script was searched in embedded or filesystem location
