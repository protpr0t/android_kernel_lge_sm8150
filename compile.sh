#!/usr/bin/env bash
# compile.sh - LG G8 ThinQ (alphaplus) kernel, lge-qcom-dev / lineage-24.0 (4.14, sm8150)
#
#   defconfig layers (later wins):
#     vendor/sm8150-perf_defconfig
#     vendor/lge/lge-common.config
#     vendor/alpha_lao_com-perf_defconfig
#     vendor/lge/lge-alpha.config
#   output: AnyKernel3 zip containing Image + Image.gz
#
# Needs: x86_64 Linux (Ubuntu 22.04/24.04), ~10 GB free disk, 8+ GB RAM.
# Nothing here deletes anything: old out/ dirs are moved aside, never removed.
set -Eeuo pipefail

### ------------------------------------------------------------------
### config (override any of these from the environment)
### ------------------------------------------------------------------
KERNEL_REPO=${KERNEL_REPO:-https://github.com/lge-qcom-dev/android_kernel_lge_sm8150.git}
KERNEL_BRANCH=${KERNEL_BRANCH:-lineage-24.0}

WORK=${WORK:-$HOME/kbuild}
SRC=${SRC:-$WORK/kernel}
OUT=${OUT:-$WORK/out}
DIST=${DIST:-$WORK/dist}

TC_DIR=${TC_DIR:-$HOME/toolchains}
CLANG_DIR=${CLANG_DIR:-$TC_DIR/clang-r416183b}
GCC64_DIR=${GCC64_DIR:-$TC_DIR/GCC64}
GCC32_DIR=${GCC32_DIR:-$TC_DIR/GCC32}
# used only when the dirs above do not exist yet (verify URLs if a clone fails)
CLANG_URL=${CLANG_URL:-https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b.git}
GCC64_URL=${GCC64_URL:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git}
GCC32_URL=${GCC32_URL:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9.git}

AK3_REPO=${AK3_REPO:-https://github.com/osm0sis/AnyKernel3.git}

BASE_DEFCONFIG=vendor/sm8150-perf_defconfig
FRAGMENTS=(
  vendor/lge/lge-common.config
  vendor/alpha_lao_com-perf_defconfig
  vendor/lge/lge-alpha.config
)

JOBS=${JOBS:-$(nproc)}
NO_LTO=${NO_LTO:-1}            # 1 = force LTO/CFI/ShadowCallStack off (faster, smaller Image)
CLEAN=${CLEAN:-0}              # 1 = move existing out/ aside and build from scratch
UPDATE=${UPDATE:-0}            # 1 = git pull --ff-only in an existing source tree
ZIP_KERNEL=${ZIP_KERNEL:-both} # both | gz | raw  (what goes into the AnyKernel3 zip)
DEVICECHECK=${DEVICECHECK:-1}  # 0 = skip AnyKernel3 device-name check
INSTALL_DEPS=${INSTALL_DEPS:-0}

export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-builder}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-kernel-ci}

### ------------------------------------------------------------------
### helpers
### ------------------------------------------------------------------
T0=$(date +%s)
LOG=""
ZIP_PATH=""

say()     { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()     { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
elapsed() { local s=$(( $(date +%s) - T0 )); printf '%dm%02ds' $((s/60)) $((s%60)); }

on_fail() {
  local rc=$? line=$1
  set +e
  say "FAILED after $(elapsed) (exit $rc, line $line)"
  [[ -n $LOG && -f $LOG ]] && { echo "--- last 40 log lines ($LOG) ---"; tail -n 40 "$LOG"; }
  exit "$rc"
}
trap 'on_fail $LINENO' ERR

### ------------------------------------------------------------------
### steps
### ------------------------------------------------------------------
step_deps() {
  [[ $INSTALL_DEPS = 1 ]] || return 0
  say "Installing host packages"
  local SUDO=""; [[ $EUID -ne 0 ]] && SUDO=sudo
  $SUDO apt-get update -qq
  $SUDO apt-get install -y --no-install-recommends \
    git ca-certificates zip unzip make bc bison flex gcc g++ \
    libssl-dev libelf-dev libncurses-dev python3 device-tree-compiler \
    cpio lz4 xz-utils zstd ccache
}

step_toolchains() {
  say "Toolchains"
  mkdir -p "$TC_DIR"
  [[ -d $CLANG_DIR ]] || git clone --depth=1 "$CLANG_URL" "$CLANG_DIR"
  [[ -d $GCC64_DIR ]] || git clone --depth=1 "$GCC64_URL" "$GCC64_DIR"
  [[ -d $GCC32_DIR ]] || git clone --depth=1 "$GCC32_URL" "$GCC32_DIR"
  export PATH="$CLANG_DIR/bin:$GCC64_DIR/bin:$GCC32_DIR/bin:$PATH"
  command -v clang  >/dev/null || die "clang not found in $CLANG_DIR/bin"
  command -v dtc    >/dev/null || die "dtc missing (apt install device-tree-compiler)"
  clang --version | head -n1
}

step_source() {
  say "Source: $KERNEL_REPO @ $KERNEL_BRANCH"
  mkdir -p "$WORK"
  if [[ -d $SRC/.git ]]; then
    [[ $UPDATE = 1 ]] && git -C "$SRC" pull --ff-only
  else
    git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$SRC"
  fi
  KREV=$(git -C "$SRC" rev-parse --short HEAD)
  KVER=$(make -s -C "$SRC" kernelversion)
  echo "HEAD $KREV, kernel $KVER"
}

kmake() {
  make -C "$SRC" -j"$JOBS" O="$OUT" ARCH=arm64 SUBARCH=arm64 \
    CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf \
    CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android- \
    CROSS_COMPILE_ARM32=arm-linux-androideabi- DTC_EXT=dtc "$@"
}

step_config() {
  say "Config: $BASE_DEFCONFIG + ${FRAGMENTS[*]}"
  if [[ $CLEAN = 1 && -d $OUT ]]; then
    mv "$OUT" "$OUT.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  mkdir -p "$OUT"

  local f frags=()
  for f in "$BASE_DEFCONFIG" "${FRAGMENTS[@]}"; do
    [[ -f $SRC/arch/arm64/configs/$f ]] || {
      ls "$SRC"/arch/arm64/configs/vendor/ 2>/dev/null | head -n 40
      die "missing arch/arm64/configs/$f"
    }
  done
  for f in "${FRAGMENTS[@]}"; do frags+=("$SRC/arch/arm64/configs/$f"); done

  kmake "$BASE_DEFCONFIG"
  ( cd "$SRC" && ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" "${frags[@]}" ) \
    | grep -vE '^(#|Using|Value of|$)' || true

  if [[ $NO_LTO = 1 ]]; then
    "$SRC/scripts/config" --file "$OUT/.config" \
      -d LTO_CLANG -d CFI_CLANG -d CFI_PERMISSIVE -d SHADOW_CALL_STACK -d THINLTO
  fi
  "$SRC/scripts/config" --file "$OUT/.config" -d DEBUG_INFO   # avoids huge objects / assembler errors
  kmake olddefconfig
  grep -E '^(CONFIG_LTO|CONFIG_CFI|CONFIG_DEBUG_INFO|# CONFIG_LTO_CLANG)' "$OUT/.config" || true
}

step_build() {
  LOG="$WORK/build-$(date +%Y%m%d-%H%M%S).log"
  say "Building Image + Image.gz with -j$JOBS (log: $LOG)"
  kmake Image.gz Image 2>&1 | tee "$LOG"
  local b="$OUT/arch/arm64/boot"
  [[ -f $b/Image && -f $b/Image.gz ]] || die "Image / Image.gz not produced"
  ls -lh "$b/Image" "$b/Image.gz"
  local sz; sz=$(stat -c %s "$b/Image")
  (( sz > 50*1024*1024 )) && echo "WARNING: Image is $((sz/1024/1024)) MB (> 50 MB). Check LTO is really off."
  return 0
}

step_package() {
  say "AnyKernel3 package"
  mkdir -p "$DIST"
  local b="$OUT/arch/arm64/boot" stage
  stage=$(mktemp -d)
  git clone --depth=1 "$AK3_REPO" "$stage/ak3"
  cat > "$stage/ak3/anykernel.sh" <<'EOF'
### AnyKernel3 Ramdisk Mod Script
properties() { '
kernel.string=LG G8 ThinQ (alphaplus) - @KSTR@
do.devicecheck=@DEVCHECK@
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=alphaplus
device.name2=alpha
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

dump_boot;
write_boot;
EOF
  sed -i "s|@KSTR@|${KERNEL_BRANCH} ${KVER} (${KREV})|; s|@DEVCHECK@|${DEVICECHECK}|" "$stage/ak3/anykernel.sh"

  case $ZIP_KERNEL in
    both) cp "$b/Image.gz" "$b/Image" "$stage/ak3/" ;;
    gz)   cp "$b/Image.gz" "$stage/ak3/" ;;
    raw)  cp "$b/Image" "$stage/ak3/" ;;
    *)    die "ZIP_KERNEL must be both|gz|raw" ;;
  esac

  ZIP_PATH="$DIST/alphaplus-${KERNEL_BRANCH}-${KVER}-${KREV}-$(date +%Y%m%d-%H%M).zip"
  ( cd "$stage/ak3" && zip -r9q "$ZIP_PATH" . -x '.git/*' '.github/*' 'README.md' '*placeholder' )
  ls -lh "$ZIP_PATH"
}

### ------------------------------------------------------------------
step_deps
step_toolchains
step_source
step_config
step_build
step_package
say "Done in $(elapsed): $ZIP_PATH"
