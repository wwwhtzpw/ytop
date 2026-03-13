#!/bin/bash

# Build script for ytop - Multi-platform build with anti-decompilation
# Supports: Linux (amd64, arm64), Windows (amd64, arm64), macOS (amd64, arm64)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project configuration
BINARY_NAME="ytop"
BUILD_DIR="build"
CMD_PATH="./cmd/ytop"

# Version information (China timezone)
TZ_CN="Asia/Shanghai"
VERSION=$(TZ=$TZ_CN date '+%Y%m%d_%H%M%S')
BUILD_TIME=$(TZ=$TZ_CN date '+%Y-%m-%d %H:%M:%S CST')
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# LDFLAGS for anti-decompilation and optimization
# -s: strip symbol table
# -w: strip DWARF debug info
# -X: set variable values at build time
LDFLAGS="-s -w \
    -X 'main.Version=${VERSION}' \
    -X 'main.BuildTime=${BUILD_TIME}' \
    -X 'main.GitCommit=${GIT_COMMIT}'"

# Build flags
# -trimpath: remove file system paths from binary
BUILDFLAGS="-trimpath"

# Print colored message
print_msg() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

# Print header
print_header() {
    echo ""
    print_msg "$BLUE" "=========================================="
    print_msg "$BLUE" "$@"
    print_msg "$BLUE" "=========================================="
    echo ""
}

# Build for specific platform
build_platform() {
    local os=$1
    local arch=$2
    local ext=$3

    local output_name="${BINARY_NAME}_${os}_${arch}${ext}"
    local output_path="${BUILD_DIR}/${output_name}"

    print_msg "$YELLOW" "Building ${os}/${arch}..."

    GOOS=$os GOARCH=$arch go build $BUILDFLAGS -ldflags "$LDFLAGS" -o "$output_path" $CMD_PATH

    if [ $? -eq 0 ]; then
        local size_before=$(du -h "$output_path" | cut -f1)
        print_msg "$GREEN" "✓ Built: ${output_name} (${size_before})"

        # Compress with appropriate method based on platform and architecture
        if [ "$os" = "darwin" ] && [ "$arch" = "arm64" ]; then
            # macOS ARM64: try UPX first, fallback to gzexe
            compress_macos_arm64 "$output_path"
        elif [ "$os" = "windows" ] && [ "$arch" = "arm64" ]; then
            # Windows ARM64: UPX not supported, skip compression
            print_msg "$YELLOW" "  ⚠ UPX compression not supported for Windows ARM64"
        else
            # Other platforms: use UPX
            compress_binary "$output_path" "$os"
        fi

        # Special handling for macOS ARM64 - copy to specific path if exists
        if [ "$os" = "darwin" ] && [ "$arch" = "arm64" ]; then
            local target_dir="/Users/yihan/Documents/owner/wendang/home"
            if [ -d "$target_dir" ]; then
                print_msg "$YELLOW" "Copying macOS ARM version to ${target_dir}/ytop..."
                cp "$output_path" "${target_dir}/ytop"
                if [ $? -eq 0 ]; then
                    print_msg "$GREEN" "✓ Copied to ${target_dir}/ytop"
                else
                    print_msg "$RED" "✗ Failed to copy to ${target_dir}"
                fi
            fi
        fi
    else
        print_msg "$RED" "✗ Failed to build ${os}/${arch}"
        return 1
    fi
}

# Compress binary with UPX
compress_binary() {
    local binary_path=$1
    local os=$2

    # Check if UPX is available
    if ! command -v upx &> /dev/null; then
        return 0
    fi

    local size_before=$(stat -f%z "$binary_path" 2>/dev/null || stat -c%s "$binary_path" 2>/dev/null)

    print_msg "$YELLOW" "  Compressing with UPX..."

    # For macOS, we need to handle code signing
    if [ "$os" = "darwin" ]; then
        # Remove existing signature first
        codesign --remove-signature "$binary_path" 2>/dev/null

        # Compress with UPX (use --force-macos for better compatibility)
        upx --best --lzma --force-macos "$binary_path" >/dev/null 2>&1

        local upx_result=$?

        if [ $upx_result -eq 0 ]; then
            # Ad-hoc sign the binary (allows it to run on macOS)
            codesign -s - "$binary_path" >/dev/null 2>&1

            if [ $? -eq 0 ]; then
                local size_after=$(stat -f%z "$binary_path" 2>/dev/null || stat -c%s "$binary_path" 2>/dev/null)
                local reduction=$((($size_before - $size_after) * 100 / $size_before))
                print_msg "$GREEN" "  ✓ Compressed and signed (reduced by ${reduction}%)"
            else
                print_msg "$YELLOW" "  ⚠ Compressed but signing failed"
            fi
        else
            # UPX failed, likely ARM64 not supported - skip compression
            print_msg "$YELLOW" "  ⚠ UPX compression not supported for this architecture"
        fi
    else
        # For non-macOS platforms, just compress
        upx --best --lzma "$binary_path" >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            local size_after=$(stat -f%z "$binary_path" 2>/dev/null || stat -c%s "$binary_path" 2>/dev/null)
            local reduction=$((($size_before - $size_after) * 100 / $size_before))
            print_msg "$GREEN" "  ✓ Compressed (reduced by ${reduction}%)"
        else
            print_msg "$YELLOW" "  ⚠ UPX compression failed"
        fi
    fi
}

# Compress macOS ARM64 binary using alternative methods
compress_macos_arm64() {
    local binary_path=$1
    local size_before=$(stat -f%z "$binary_path" 2>/dev/null)

    print_msg "$YELLOW" "  Compressing macOS ARM64 binary..."

    # UPX doesn't support macOS ARM64 well, use gzip wrapper directly
    if command -v gzip &> /dev/null; then
        # Create a self-extracting wrapper
        local temp_dir=$(mktemp -d)
        local compressed="${temp_dir}/payload.gz"
        local wrapper="${temp_dir}/wrapper.sh"

        # Compress the binary
        gzip -9 -c "$binary_path" > "$compressed"

        # Create wrapper script
        cat > "$wrapper" << 'WRAPPER_EOF'
#!/bin/bash
PAYLOAD_LINE=$(awk '/^__PAYLOAD_BEGIN__/ {print NR + 1; exit 0; }' "$0")
TEMP_BIN=$(mktemp)
tail -n +${PAYLOAD_LINE} "$0" | gunzip > "$TEMP_BIN"
chmod +x "$TEMP_BIN"
"$TEMP_BIN" "$@"
EXIT_CODE=$?
rm -f "$TEMP_BIN"
exit $EXIT_CODE
__PAYLOAD_BEGIN__
WRAPPER_EOF

        # Combine wrapper and compressed binary
        cat "$wrapper" "$compressed" > "${binary_path}.new"
        chmod +x "${binary_path}.new"

        # Sign the new binary
        codesign -s - "${binary_path}.new" >/dev/null 2>&1

        local size_after=$(stat -f%z "${binary_path}.new" 2>/dev/null)

        # Only replace if smaller
        if [ $size_after -lt $size_before ]; then
            mv "${binary_path}.new" "$binary_path"
            local reduction=$((($size_before - $size_after) * 100 / $size_before))
            print_msg "$GREEN" "  ✓ Compressed with gzip wrapper (reduced by ${reduction}%)"
            rm -rf "$temp_dir"
            return 0
        else
            rm -f "${binary_path}.new"
            print_msg "$YELLOW" "  ⚠ Gzip wrapper larger than original, keeping original"
        fi

        rm -rf "$temp_dir"
    else
        print_msg "$YELLOW" "  ⚠ gzip not available, keeping original binary"
    fi
}

# Clean build directory
clean_build() {
    print_msg "$YELLOW" "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    print_msg "$GREEN" "✓ Clean complete"
}

# Show help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Build ytop for multiple platforms with anti-decompilation protection.

OPTIONS:
    -h, --help          Show this help message
    -c, --clean         Clean build directory before building
    -l, --linux         Build for Linux only
    -w, --windows       Build for Windows only
    -m, --macos         Build for macOS only
    -a, --all           Build for all platforms (default)
    --current           Build for current platform only

EXAMPLES:
    $0                  # Build all platforms
    $0 --clean          # Clean and build all platforms
    $0 --linux          # Build Linux versions only
    $0 --current        # Build for current platform only

OUTPUT:
    All binaries will be placed in: ${BUILD_DIR}/
    Naming format: ${BINARY_NAME}_<os>_<arch>[.exe]

PLATFORMS:
    Linux:   amd64, arm64
    Windows: amd64, arm64
    macOS:   amd64, arm64 (Apple Silicon)

ANTI-DECOMPILATION:
    - Symbol table stripped (-s)
    - Debug info stripped (-w)
    - File paths removed (-trimpath)
    - Version info embedded

COMPRESSION:
    - UPX compression for supported platforms:
      * Linux amd64/arm64: UPX --best --lzma (~68-70% reduction)
      * Windows amd64: UPX --best --lzma (~68% reduction)
      * macOS amd64: UPX + codesign (~67% reduction)
    - Alternative compression for unsupported platforms:
      * macOS ARM64: gzip self-extracting wrapper (~59% reduction)
      * Windows ARM64: No compression (UPX not supported)

REQUIREMENTS:
    - Go 1.19+ (required)
    - upx (optional, for UPX compression)
    - gzip (optional, for macOS ARM64 compression)
    - codesign (macOS only, for signing compressed binaries)

INSTALL UPX:
    macOS:   brew install upx
    Linux:   apt-get install upx-ucl  or  yum install upx
    Windows: Download from https://upx.github.io/

EOF
}

# Build all platforms
build_all() {
    print_header "Building for all platforms"

    # Linux
    build_platform "linux" "amd64" ""
    build_platform "linux" "arm64" ""

    # Windows
    build_platform "windows" "amd64" ".exe"
    build_platform "windows" "arm64" ".exe"

    # macOS
    build_platform "darwin" "amd64" ""
    build_platform "darwin" "arm64" ""
}

# Build Linux only
build_linux() {
    print_header "Building for Linux"
    build_platform "linux" "amd64" ""
    build_platform "linux" "arm64" ""
}

# Build Windows only
build_windows() {
    print_header "Building for Windows"
    build_platform "windows" "amd64" ".exe"
    build_platform "windows" "arm64" ".exe"
}

# Build macOS only
build_macos() {
    print_header "Building for macOS"
    build_platform "darwin" "amd64" ""
    build_platform "darwin" "arm64" ""
}

# Build current platform only
build_current() {
    print_header "Building for current platform"

    local current_os=$(go env GOOS)
    local current_arch=$(go env GOARCH)
    local ext=""

    if [ "$current_os" = "windows" ]; then
        ext=".exe"
    fi

    build_platform "$current_os" "$current_arch" "$ext"
}

# Show build summary
show_summary() {
    echo ""
    print_header "Build Summary"

    if [ -d "$BUILD_DIR" ]; then
        print_msg "$GREEN" "Build directory: ${BUILD_DIR}/"
        echo ""
        ls -lh "$BUILD_DIR"/ | tail -n +2 | while read -r line; do
            echo "  $line"
        done
        echo ""

        local total_size=$(du -sh "$BUILD_DIR" | cut -f1)
        print_msg "$BLUE" "Total size: ${total_size}"
    else
        print_msg "$RED" "No build directory found"
    fi

    echo ""
}

# Update version.go file with current build information
update_version_file() {
    local version_file="cmd/ytop/version.go"

    print_msg "$YELLOW" "Updating version information..."

    cat > "$version_file" << EOF
package main

// Version information
// This file is automatically updated by build.sh
// Last updated: $(TZ=$TZ_CN date '+%Y-%m-%d %H:%M:%S CST')
var (
	Version   = "${VERSION}"
	BuildTime = "${BUILD_TIME}"
	GitCommit = "${GIT_COMMIT}"
)
EOF

    if [ $? -eq 0 ]; then
        print_msg "$GREEN" "✓ Version updated: ${VERSION}"
    else
        print_msg "$RED" "✗ Failed to update version file"
        return 1
    fi
}

# Main script
main() {
    # Check if go is installed
    if ! command -v go &> /dev/null; then
        print_msg "$RED" "Error: Go is not installed"
        exit 1
    fi

    # Parse arguments
    local do_clean=false
    local build_target="all"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--clean)
                do_clean=true
                shift
                ;;
            -l|--linux)
                build_target="linux"
                shift
                ;;
            -w|--windows)
                build_target="windows"
                shift
                ;;
            -m|--macos)
                build_target="macos"
                shift
                ;;
            -a|--all)
                build_target="all"
                shift
                ;;
            --current)
                build_target="current"
                shift
                ;;
            *)
                print_msg "$RED" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Show build info
    print_header "ytop Build Script"
    print_msg "$BLUE" "Version:    ${VERSION}"
    print_msg "$BLUE" "Build Time: ${BUILD_TIME}"
    print_msg "$BLUE" "Git Commit: ${GIT_COMMIT}"
    echo ""

    # Update version.go file
    update_version_file
    echo ""

    # Copy root scripts/sql and scripts/os to internal/scripts for embedding (required for go:embed)
    if [ -d "scripts/sql" ] && [ -d "scripts/os" ]; then
        print_msg "$YELLOW" "Copying root scripts/sql and scripts/os to internal/scripts for embed..."
        rm -rf internal/scripts/sql internal/scripts/os
        cp -r scripts/sql scripts/os internal/scripts/
        print_msg "$GREEN" "✓ Scripts copied for embed"
    else
        print_msg "$RED" "✗ scripts/sql or scripts/os not found, embed may be empty"
    fi
    echo ""

    # Clean if requested
    if [ "$do_clean" = true ]; then
        clean_build
    else
        mkdir -p "$BUILD_DIR"
    fi

    # Build based on target
    case $build_target in
        all)
            build_all
            ;;
        linux)
            build_linux
            ;;
        windows)
            build_windows
            ;;
        macos)
            build_macos
            ;;
        current)
            build_current
            ;;
    esac

    # Show summary
    show_summary

    # Remove copied scripts (used only for embed during build)
    if [ -d "internal/scripts/sql" ] || [ -d "internal/scripts/os" ]; then
        rm -rf internal/scripts/sql internal/scripts/os
        print_msg "$GREEN" "✓ Removed internal/scripts/sql and internal/scripts/os"
    fi

    print_msg "$GREEN" "✓ Build process complete!"
}

# Run main function
main "$@"
