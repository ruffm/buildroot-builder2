#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILDER_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$BUILDER_DIR/.polylinux-builder.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Run scripts/01-setup-buildroot.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$ENV_FILE"

CONFIG_ROOT="$BUILDER_DIR/config-sets"
COMMON_ROOT="$BUILDER_DIR/config-common"
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

mapfile -t CONFIG_SETS < <(find "$CONFIG_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
if [ "${#CONFIG_SETS[@]}" -eq 0 ]; then
  echo "No config sets found under $CONFIG_ROOT" >&2
  exit 1
fi

if [ "${1:-}" = "--config" ]; then
  SELECTED=${2:-}
else
  echo "Available Buildroot config sets:"
  select choice in "${CONFIG_SETS[@]}"; do
    SELECTED=$choice
    break
  done
fi

if [ -z "${SELECTED:-}" ] || [ ! -d "$CONFIG_ROOT/$SELECTED" ]; then
  echo "Unknown config set: ${SELECTED:-<empty>}" >&2
  exit 1
fi

CONFIG_DIR="$CONFIG_ROOT/$SELECTED"
DEFCONFIG="$CONFIG_DIR/defconfig"
FRAGMENT="$CONFIG_DIR/features.fragment"
BUILD_OUTPUT="$BUILD_DIR/$SELECTED"
STAMP=$(date +%Y%m%d-%H%M%S)
PACKAGE_DIR="$ARTIFACT_DIR/${SELECTED}-${STAMP}"

if [ ! -f "$DEFCONFIG" ]; then
  echo "Missing defconfig: $DEFCONFIG" >&2
  exit 1
fi

# Shared settings: config-sets/<name>/includes lists files in config-common/,
# one per line, written before the set's defconfig (so the set can override).
INCLUDE_FILES=()
if [ -f "$CONFIG_DIR/includes" ]; then
  while read -r include; do
    include=${include%%#*}
    include=$(echo "$include" | tr -d '[:space:]')
    [ -n "$include" ] || continue
    [ -f "$COMMON_ROOT/$include" ] || { echo "$CONFIG_DIR/includes: $COMMON_ROOT/$include not found" >&2; exit 1; }
    INCLUDE_FILES+=("$COMMON_ROOT/$include")
  done < "$CONFIG_DIR/includes"
fi

mkdir -p "$BUILD_OUTPUT" "$PACKAGE_DIR/images" "$PACKAGE_DIR/configs" "$PACKAGE_DIR/logs" "$PACKAGE_DIR/manifest"

FRAGMENT_FILES=()
[ ! -f "$FRAGMENT" ] || FRAGMENT_FILES=("$FRAGMENT")

: > "$BUILD_OUTPUT/.config"
for include in "${INCLUDE_FILES[@]}"; do
  cat "$include" >> "$BUILD_OUTPUT/.config"
done
cat "$DEFCONFIG" >> "$BUILD_OUTPUT/.config"
if [ -f "$FRAGMENT" ]; then
  cat "$FRAGMENT" >> "$BUILD_OUTPUT/.config"
fi
if grep -q '^BR2_DOWNLOAD_FORCE_CHECK_HASHES=y$' "$BUILD_OUTPUT/.config"; then
  echo "Removing BR2_DOWNLOAD_FORCE_CHECK_HASHES=y for custom Linux tarball compatibility."
  sed -i '/^BR2_DOWNLOAD_FORCE_CHECK_HASHES=y$/d' "$BUILD_OUTPUT/.config"
fi

echo "Running olddefconfig for $SELECTED"
make -C "$BUILDROOT_SRC" O="$BUILD_OUTPUT" olddefconfig | tee "$PACKAGE_DIR/logs/olddefconfig.log"

# olddefconfig quietly drops any option whose dependencies are not met (for
# example BR2_PACKAGE_BASH without BR2_PACKAGE_BUSYBOX_SHOW_OTHERS). Stop
# before a long build that would not contain what the config set asks for.
# ALLOW_DROPPED_OPTIONS=1 continues anyway (for experiments).
dropped=()
while read -r option; do
  [ -n "$option" ] || continue
  [ "$option" != "BR2_DOWNLOAD_FORCE_CHECK_HASHES=y" ] || continue
  grep -qxF "$option" "$BUILD_OUTPUT/.config" || dropped+=("$option")
done < <(
  # The set's own =y lines, plus shared (includes) =y lines the set does not override.
  cat "$DEFCONFIG" "${FRAGMENT_FILES[@]}" | tr -d '\r' | grep -E '^BR2_[A-Z0-9_]+=y$'
  if [ "${#INCLUDE_FILES[@]}" -gt 0 ]; then
    overridden=$(cat "$DEFCONFIG" "${FRAGMENT_FILES[@]}" | grep -oE 'BR2_[A-Z0-9_]+' | sort -u)
    cat "${INCLUDE_FILES[@]}" | tr -d '\r' | grep -E '^BR2_[A-Z0-9_]+=y$' |
      while read -r line; do grep -qxF "${line%%=*}" <<< "$overridden" || echo "$line"; done
  fi | sort -u
)
if [ "${#dropped[@]}" -gt 0 ]; then
  echo "Buildroot dropped ${#dropped[@]} option(s) that $SELECTED asks for (a dependency is not enabled):" >&2
  printf '  %s\n' "${dropped[@]}" >&2
  echo "Packages that duplicate BusyBox applets (bash, coreutils, grep, sed, ...) need BR2_PACKAGE_BUSYBOX_SHOW_OTHERS=y." >&2
  if [ "${ALLOW_DROPPED_OPTIONS:-0}" != 1 ]; then
    exit 1
  fi
  echo "ALLOW_DROPPED_OPTIONS=1: continuing anyway." >&2
fi

echo "Building $SELECTED with JOBS=$JOBS"
make -C "$BUILDROOT_SRC" O="$BUILD_OUTPUT" -j"$JOBS" 2>&1 | tee "$PACKAGE_DIR/logs/build.log"

BZIMAGE="$BUILD_OUTPUT/images/bzImage"
ROOTFS="$BUILD_OUTPUT/images/rootfs.cpio.gz"
if [ ! -f "$BZIMAGE" ] || [ ! -f "$ROOTFS" ]; then
  echo "Build completed, but expected images were not found under $BUILD_OUTPUT/images" >&2
  exit 1
fi

# Every command the config set promises must be in the built rootfs.
COMMANDS_NOTE="no required-commands.txt"
if [ -f "$CONFIG_DIR/required-commands.txt" ]; then
  missing=()
  count=0
  while read -r cmd; do
    cmd=${cmd%%#*}
    cmd=$(echo "$cmd" | tr -d '[:space:]')
    [ -n "$cmd" ] || continue
    count=$((count + 1))
    found=no
    for dir in bin sbin usr/bin usr/sbin; do
      if [ -e "$BUILD_OUTPUT/target/$dir/$cmd" ] || [ -L "$BUILD_OUTPUT/target/$dir/$cmd" ]; then
        found=yes
        break
      fi
    done
    [ "$found" = yes ] || missing+=("$cmd")
  done < "$CONFIG_DIR/required-commands.txt"
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Required commands missing from the $SELECTED rootfs: ${missing[*]}" >&2
    exit 1
  fi
  COMMANDS_NOTE="all $count commands in required-commands.txt are present"
  echo "Command check: $COMMANDS_NOTE"
fi

cp "$BZIMAGE" "$PACKAGE_DIR/images/bzImage"
cp "$ROOTFS" "$PACKAGE_DIR/images/rootfs.cpio.gz"
cp "$BZIMAGE" "$PACKAGE_DIR/images/${SELECTED}-bzImage"
cp "$ROOTFS" "$PACKAGE_DIR/images/${SELECTED}-rootfs.cpio.gz"
cp "$BUILD_OUTPUT/.config" "$PACKAGE_DIR/configs/final-buildroot.config"
cp "$DEFCONFIG" "$PACKAGE_DIR/configs/starting.defconfig"
for include in "${INCLUDE_FILES[@]}"; do
  mkdir -p "$PACKAGE_DIR/configs/common"
  cp "$include" "$PACKAGE_DIR/configs/common/"
done
[ ! -f "$FRAGMENT" ] || cp "$FRAGMENT" "$PACKAGE_DIR/configs/features.fragment"
[ ! -f "$CONFIG_DIR/required-commands.txt" ] || cp "$CONFIG_DIR/required-commands.txt" "$PACKAGE_DIR/manifest/required-commands.txt"

(
  cd "$PACKAGE_DIR/images"
  sha256sum bzImage rootfs.cpio.gz "${SELECTED}-bzImage" "${SELECTED}-rootfs.cpio.gz"
) > "$PACKAGE_DIR/manifest/artifact-sha256.txt"

cat > "$PACKAGE_DIR/manifest/validation-notes.md" <<EOF
# Validation Notes

- Buildroot version: $BUILDROOT_VERSION
- Config set: $SELECTED
- Build output: $BUILD_OUTPUT
- Config check: every BR2_*=y option in the config set survived olddefconfig.
- Command check: $COMMANDS_NOTE.
- Boot validation: not run by this script.

Run v86 boot validation before publishing this baseline.
EOF

echo "Baseline package written to $PACKAGE_DIR"
echo "Use this package with scripts/03-package-payload.sh --baseline $PACKAGE_DIR ..."
