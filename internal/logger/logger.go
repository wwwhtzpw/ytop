package logger

import (
	"fmt"
	"log"
	"os"
	"sync"
)

var (
	debugEnabled bool
	debugFile    *os.File
	debugLogger  *log.Logger
	mu           sync.Mutex
)

// Init initializes the logger
func Init(debug bool) error {
	mu.Lock()
	defer mu.Unlock()

	debugEnabled = debug

	if debug {
		// Create debug log file
		var err error
		debugFile, err = os.OpenFile("ytop_debug.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			return fmt.Errorf("failed to create debug log file: %w", err)
		}

		debugLogger = log.New(debugFile, "", log.LstdFlags)
	}

	return nil
}

// Close closes the logger
func Close() {
	mu.Lock()
	defer mu.Unlock()

	if debugFile != nil {
		debugFile.Close()
		debugFile = nil
	}
}

// Debug logs a debug message
func Debug(format string, args ...interface{}) {
	if !debugEnabled {
		return
	}

	mu.Lock()
	defer mu.Unlock()

	if debugLogger != nil {
		debugLogger.Printf("[DEBUG] "+format, args...)
	}
}

// Debugf is an alias for Debug
func Debugf(format string, args ...interface{}) {
	Debug(format, args...)
}
