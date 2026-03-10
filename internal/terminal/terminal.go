package terminal

import (
	"fmt"
	"os"
	"strings"
	"time"

	"golang.org/x/term"
)

// GetGlobalInputChan is set by main to provide coordinated stdin access
var GetGlobalInputChan func() <-chan byte

// WithTerminalRestore executes a function with terminal restored to normal mode
func WithTerminalRestore(oldState *term.State, fn func() error) error {
	// Restore terminal
	if err := term.Restore(int(os.Stdin.Fd()), oldState); err != nil {
		return fmt.Errorf("failed to restore terminal: %w", err)
	}

	// Drain any pending input from stdin to avoid character loss
	// Set stdin to non-blocking mode temporarily
	fd := int(os.Stdin.Fd())

	// Execute function
	err := fn()

	// Restore to raw mode
	newState, rawErr := term.MakeRaw(fd)
	if rawErr != nil {
		return fmt.Errorf("failed to set raw mode: %w", rawErr)
	}

	// Update oldState pointer
	*oldState = *newState

	return err
}

// PromptInput prompts for user input with ESC to cancel
// Assumes terminal is already in a suitable mode for input
func PromptInput(prompt string, maxLen int) string {
	fmt.Print(prompt)

	input := make([]byte, 0, maxLen)

	// Get input channel if available (for coordinated reading)
	var inputChan <-chan byte
	if GetGlobalInputChan != nil {
		inputChan = GetGlobalInputChan()
	}

	for {
		var b byte
		var err error

		if inputChan != nil {
			// Read from coordinated channel
			select {
			case b = <-inputChan:
			case <-time.After(100 * time.Millisecond):
				continue
			}
		} else {
			// Fallback: read directly from stdin
			buf := make([]byte, 1)
			_, err = os.Stdin.Read(buf)
			if err != nil {
				return ""
			}
			b = buf[0]
		}

		// Ctrl+C - exit program
		if b == 3 {
			fmt.Print("\r\n")
			os.Exit(0)
		}

		// ESC key - return empty string without message
		if b == 27 {
			fmt.Print("\r\n") // Move to next line
			return ""
		}

		// Enter key
		if b == 10 || b == 13 {
			fmt.Print("\r\n") // Move to next line in raw mode
			return strings.TrimSpace(string(input))
		}

		// Backspace
		if b == 127 || b == 8 {
			if len(input) > 0 {
				input = input[:len(input)-1]
				fmt.Print("\b \b")
			}
			continue
		}

		// Regular character
		if len(input) < maxLen && b >= 32 && b < 127 {
			input = append(input, b)
			fmt.Print(string(b))
		}
	}
}

// promptInputNormal is fallback for normal mode
func promptInputNormal(maxLen int) string {
	input := make([]byte, 0, maxLen)
	for {
		b := make([]byte, 1)
		_, err := os.Stdin.Read(b)
		if err != nil {
			return ""
		}

		// Ctrl+C - exit program
		if b[0] == 3 {
			fmt.Println()
			os.Exit(0)
		}

		// ESC key - return empty string without message
		if b[0] == 27 {
			fmt.Println()
			return ""
		}

		// Enter key
		if b[0] == 10 || b[0] == 13 {
			break
		}

		// Backspace
		if b[0] == 127 || b[0] == 8 {
			if len(input) > 0 {
				input = input[:len(input)-1]
				fmt.Print("\b \b")
			}
			continue
		}

		// Regular character
		if len(input) < maxLen {
			input = append(input, b[0])
			fmt.Print(string(b[0]))
		}
	}

	fmt.Println()
	return strings.TrimSpace(string(input))
}

// WaitForKey waits for any key press and returns true if ESC was pressed
// This function temporarily sets raw mode to capture single key
func WaitForKey(message string) bool {
	if message != "" {
		fmt.Print(message)
	}

	// Set terminal to raw mode temporarily to capture single key without Enter
	oldState, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		return false
	}
	defer term.Restore(int(os.Stdin.Fd()), oldState)

	// Read single byte only
	var b [1]byte
	_, err = os.Stdin.Read(b[:])
	if err != nil {
		return false
	}

	// Ctrl+C - exit program
	if b[0] == 3 {
		fmt.Print("\r\n")
		os.Exit(0)
	}

	// Check if ESC key was pressed
	return b[0] == 27
}
