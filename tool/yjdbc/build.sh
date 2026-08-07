#!/usr/bin/env bash
# 构建 yjdbc (Java 8 字节码), 安装到 internal/scripts/os/yjdbc.jar
# 合并 jline-2.x (行编辑/历史); 不含 JDBC 驱动
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/build/classes"
OS_DIR="$ROOT/../../internal/scripts/os"
TARGET_RELEASE="${TARGET_RELEASE:-8}"
TARGET_MAJOR=52

DEPS="$ROOT/build/deps"
mkdir -p "$DEPS"
JLINE_VER=2.14.6
JLINE_JAR="$DEPS/jline-${JLINE_VER}.jar"
if [ ! -f "$JLINE_JAR" ]; then
  URL="https://repo1.maven.org/maven2/jline/jline/${JLINE_VER}/jline-${JLINE_VER}.jar"
  echo "Fetching $URL"
  curl -fsSL -o "$JLINE_JAR" "$URL"
fi

rm -rf "$OUT"
mkdir -p "$OUT" "$ROOT/build"

SRC_LIST="$ROOT/build/sources.list"
: >"$SRC_LIST"
FILE_COUNT=0
while IFS= read -r f; do
  printf '%s\n' "$f" >>"$SRC_LIST"
  FILE_COUNT=$((FILE_COUNT + 1))
done < <(find "$SRC" -name '*.java' | LC_ALL=C sort)

if [ "$FILE_COUNT" = "0" ]; then
  echo "No Java sources under $SRC" >&2
  exit 1
fi

JAVAC="${JAVAC:-javac}"
echo "javac: $($JAVAC -version 2>&1 || true)"
echo "target: Java $TARGET_RELEASE (class major $TARGET_MAJOR)"
echo "jline: $JLINE_JAR"

CP="$JLINE_JAR"
if "$JAVAC" -help 2>&1 | grep -q -- '--release'; then
  "$JAVAC" -encoding UTF-8 --release "$TARGET_RELEASE" -cp "$CP" -d "$OUT" @"$SRC_LIST"
elif "$JAVAC" -help 2>&1 | grep -q -- '-source'; then
  "$JAVAC" -encoding UTF-8 -source "$TARGET_RELEASE" -target "$TARGET_RELEASE" -cp "$CP" -d "$OUT" @"$SRC_LIST"
else
  echo "ERROR: javac does not support --release or -source/-target" >&2
  exit 1
fi

verify_class_major() {
  local root="$1" expect="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$root" "$expect" <<'PY'
import os, struct, sys
root, expect = sys.argv[1], int(sys.argv[2])
bad = []
n = 0
for dp, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith('.class'):
            continue
        n += 1
        p = os.path.join(dp, f)
        with open(p, 'rb') as fh:
            magic, minor, major = struct.unpack('>IHH', fh.read(8))
        if magic != 0xCAFEBABE or major != expect:
            bad.append((p, major))
if bad:
    sys.stderr.write('ERROR: classfile major mismatch (expected %d):\n' % expect)
    for p, maj in bad[:10]:
        sys.stderr.write('  %s major=%s\n' % (p, maj))
    sys.exit(1)
print('Verified %d class files major=%d' % (n, expect))
PY
    return $?
  fi
  echo "WARN: skip class major verify (need python3)" >&2
  return 0
}
verify_class_major "$OUT" "$TARGET_MAJOR"
echo "Built $FILE_COUNT classes -> $OUT"

JAR="$ROOT/build/yjdbc.jar"
MF="$ROOT/build/MANIFEST.MF"
{
  echo "Manifest-Version: 1.0"
  echo "Main-Class: com.yashan.yjdbc.Main"
  echo "Created-By: yjdbc build.sh"
  echo "Build-Target-Java: $TARGET_RELEASE"
} >"$MF"

JLINE_EXT="$ROOT/build/jline-classes"
rm -rf "$JLINE_EXT"
mkdir -p "$JLINE_EXT"
(cd "$JLINE_EXT" && jar xf "$JLINE_JAR")
rm -f "$JLINE_EXT/META-INF/MANIFEST.MF"
rm -f "$JLINE_EXT"/META-INF/*.SF "$JLINE_EXT"/META-INF/*.RSA "$JLINE_EXT"/META-INF/*.DSA 2>/dev/null || true

jar cfm "$JAR" "$MF" -C "$OUT" . -C "$JLINE_EXT" .
echo "Jar (yjdbc + jline, no JDBC driver): $JAR"

if [ -d "$OS_DIR" ]; then
  cp "$JAR" "$OS_DIR/yjdbc.jar"
  echo "Installed: $OS_DIR/yjdbc.jar"
else
  echo "WARN: OS_DIR missing: $OS_DIR" >&2
fi
