.PHONY: all clean build-all build-linux build-windows build-darwin help

# Project information
BINARY_NAME=ytop
BUILD_DIR=build
VERSION=$(shell date -u '+%Y%m%d_%H%M%S')
BUILD_TIME=$(shell date -u '+%Y-%m-%d %H:%M:%S UTC')
GIT_COMMIT=$(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Go build flags for anti-decompilation and optimization
LDFLAGS=-ldflags "\
	-s -w \
	-X 'main.Version=$(VERSION)' \
	-X 'main.BuildTime=$(BUILD_TIME)' \
	-X 'main.GitCommit=$(GIT_COMMIT)'"

# Build flags
BUILDFLAGS=-trimpath

# Default target
all: clean build-all

# Help target
help:
	@echo "Available targets:"
	@echo "  make all          - Clean and build all platforms"
	@echo "  make build-all    - Build for all platforms"
	@echo "  make build-linux  - Build for Linux (amd64, arm64)"
	@echo "  make build-windows- Build for Windows (amd64, arm64)"
	@echo "  make build-darwin - Build for macOS (amd64, arm64)"
	@echo "  make clean        - Remove build directory"
	@echo ""
	@echo "Output directory: $(BUILD_DIR)/"

# Update version.go file
update-version:
	@echo "Updating version information..."
	@echo 'package main' > cmd/ytop/version.go
	@echo '' >> cmd/ytop/version.go
	@echo '// Version information' >> cmd/ytop/version.go
	@echo '// This file is automatically updated by Makefile' >> cmd/ytop/version.go
	@echo '// Last updated: $(shell date -u "+%Y-%m-%d %H:%M:%S UTC")' >> cmd/ytop/version.go
	@echo 'var (' >> cmd/ytop/version.go
	@echo '	Version   = "$(VERSION)"' >> cmd/ytop/version.go
	@echo '	BuildTime = "$(BUILD_TIME)"' >> cmd/ytop/version.go
	@echo '	GitCommit = "$(GIT_COMMIT)"' >> cmd/ytop/version.go
	@echo ')' >> cmd/ytop/version.go
	@echo "Version updated: $(VERSION)"

# Clean build directory
clean:
	@echo "Cleaning build directory..."
	@rm -rf $(BUILD_DIR)
	@echo "Clean complete"

# Create build directory
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# Build all platforms
build-all: build-linux build-windows build-darwin
	@echo ""
	@echo "=========================================="
	@echo "Build complete! Files in $(BUILD_DIR)/"
	@echo "=========================================="
	@ls -lh $(BUILD_DIR)/

# Build Linux binaries
build-linux: $(BUILD_DIR) update-version
	@echo "Building for Linux amd64..."
	@GOOS=linux GOARCH=amd64 go build $(BUILDFLAGS) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME)_linux_amd64 ./cmd/ytop
	@$(MAKE) compress-binary FILE=$(BUILD_DIR)/$(BINARY_NAME)_linux_amd64 OS=linux
	@echo "Building for Linux arm64..."
	@GOOS=linux GOARCH=arm64 go build $(BUILDFLAGS) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME)_linux_arm64 ./cmd/ytop
	@$(MAKE) compress-binary FILE=$(BUILD_DIR)/$(BINARY_NAME)_linux_arm64 OS=linux
	@echo "Linux builds complete"

# Build Windows binaries
build-windows: $(BUILD_DIR) update-version
	@echo "Building for Windows amd64..."
	@GOOS=windows GOARCH=amd64 go build $(BUILDFLAGS) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME)_windows_amd64.exe ./cmd/ytop
	@$(MAKE) compress-binary FILE=$(BUILD_DIR)/$(BINARY_NAME)_windows_amd64.exe OS=windows ARCH=amd64
	@echo "Building for Windows arm64..."
	@GOOS=windows GOARCH=arm64 go build $(BUILDFLAGS) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME)_windows_arm64.exe ./cmd/ytop
	@$(MAKE) compress-binary FILE=$(BUILD_DIR)/$(BINARY_NAME)_windows_arm64.exe OS=windows ARCH=arm64
	@echo "Windows builds complete"

# Build macOS binaries
build-darwin: $(BUILD_DIR) update-version
	@echo "Building for macOS amd64..."
	@GOOS=darwin GOARCH=amd64 go build $(BUILDFLAGS) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME)_darwin_amd64 ./cmd/ytop
	@$(MAKE) compress-binary FILE=$(BUILD_DIR)/$(BINARY_NAME)_darwin_amd64 OS=darwin ARCH=amd64
	@echo "Building for macOS arm64..."
	@GOOS=darwin GOARCH=arm64 go build $(BUILDFLAGS) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME)_darwin_arm64 ./cmd/ytop
	@$(MAKE) compress-macos-arm64 FILE=$(BUILD_DIR)/$(BINARY_NAME)_darwin_arm64
	@echo "macOS builds complete"
	@# Copy macOS ARM version to specific path if it exists
	@if [ -d "/Users/yihan/Documents/owner/wendang/home" ]; then \
		echo "Copying macOS ARM version to /Users/yihan/Documents/owner/wendang/home/ytop..."; \
		cp $(BUILD_DIR)/$(BINARY_NAME)_darwin_arm64 /Users/yihan/Documents/owner/wendang/home/ytop; \
		echo "Copy complete"; \
	fi

# Compress binary with UPX
compress-binary:
	@if command -v upx >/dev/null 2>&1; then \
		echo "  Compressing $(FILE) with UPX..."; \
		if [ "$(OS)" = "darwin" ] && [ "$(ARCH)" = "amd64" ]; then \
			codesign --remove-signature "$(FILE)" 2>/dev/null || true; \
			upx --best --lzma --force-macos "$(FILE)" >/dev/null 2>&1 && \
			codesign -s - "$(FILE)" >/dev/null 2>&1 && \
			echo "  ✓ Compressed and signed" || echo "  ⚠ Compression failed"; \
		elif [ "$(OS)" = "windows" ] && [ "$(ARCH)" = "arm64" ]; then \
			echo "  ⚠ UPX not supported for Windows ARM64"; \
		else \
			upx --best --lzma "$(FILE)" >/dev/null 2>&1 && \
			echo "  ✓ Compressed" || echo "  ⚠ Compression failed"; \
		fi \
	fi

# Compress macOS ARM64 with gzip wrapper
compress-macos-arm64:
	@echo "  Compressing macOS ARM64 with gzip wrapper..."
	@if command -v gzip >/dev/null 2>&1; then \
		TEMP_DIR=$$(mktemp -d); \
		gzip -9 -c "$(FILE)" > "$$TEMP_DIR/payload.gz"; \
		echo '#!/bin/bash' > "$$TEMP_DIR/wrapper.sh"; \
		echo 'PAYLOAD_LINE=$$(awk '"'"'/^__PAYLOAD_BEGIN__/ {print NR + 1; exit 0; }'"'"' "$$0")' >> "$$TEMP_DIR/wrapper.sh"; \
		echo 'TEMP_BIN=$$(mktemp)' >> "$$TEMP_DIR/wrapper.sh"; \
		echo 'tail -n +$${PAYLOAD_LINE} "$$0" | gunzip > "$$TEMP_BIN"' >> "$$TEMP_DIR/wrapper.sh"; \
		echo 'chmod +x "$$TEMP_BIN"' >> "$$TEMP_DIR/wrapper.sh"; \
		echo '"$$TEMP_BIN" "$$@"' >> "$$TEMP_DIR/wrapper.sh"; \
		echo 'EXIT_CODE=$$?' >> "$$TEMP_DIR/wrapper.sh"; \
		echo 'rm -f "$$TEMP_BIN"' >> "$$TEMP_DIR/wrapper.sh"; \
		echo 'exit $$EXIT_CODE' >> "$$TEMP_DIR/wrapper.sh"; \
		echo '__PAYLOAD_BEGIN__' >> "$$TEMP_DIR/wrapper.sh"; \
		cat "$$TEMP_DIR/wrapper.sh" "$$TEMP_DIR/payload.gz" > "$(FILE).new"; \
		chmod +x "$(FILE).new"; \
		codesign -s - "$(FILE).new" >/dev/null 2>&1 || true; \
		SIZE_BEFORE=$$(stat -f%z "$(FILE)" 2>/dev/null); \
		SIZE_AFTER=$$(stat -f%z "$(FILE).new" 2>/dev/null); \
		if [ $$SIZE_AFTER -lt $$SIZE_BEFORE ]; then \
			mv "$(FILE).new" "$(FILE)"; \
			echo "  ✓ Compressed with gzip wrapper"; \
		else \
			rm -f "$(FILE).new"; \
			echo "  ⚠ Gzip wrapper larger, keeping original"; \
		fi; \
		rm -rf "$$TEMP_DIR"; \
	else \
		echo "  ⚠ gzip not available"; \
	fi

# Build current platform only
build-current: $(BUILD_DIR) update-version
	@echo "Building for current platform..."
	@go build $(BUILDFLAGS) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME) ./cmd/ytop
	@echo "Build complete: $(BUILD_DIR)/$(BINARY_NAME)"
