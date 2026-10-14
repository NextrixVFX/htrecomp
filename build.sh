#!/usr/bin/env bash
#
# Build Hydro Thunder Hurricane: Recompiled on macOS and Linux.
#
# Handles the parts that are easy to get wrong: the SDK clone and its patches,
# MoltenVK's dependencies, the Windows-checkout symlink problem, and the
# toolchain checks that otherwise fail deep in a build with a confusing error.
#
# Safe to re-run. Every step checks whether it has already been done.
#
#   ./build.sh                          configure and build
#   ./build.sh --package <file>         ...then unpack a game package
#   ./build.sh --clean                  wipe the build dir first
#   ./build.sh --jobs 4                 override the parallelism
#   ./build.sh --build-type Release     default is RelWithDebInfo
#   ./build.sh --skip-sdk               leave third_party/rexglue-sdk alone
#   ./build.sh --xma-patch              also apply the optional XMA patch
#
# Windows is not covered here - see BUILDING.md.

set -euo pipefail

SDK_TAG="v0.10.0"
SDK_URL="https://github.com/rexglue/rexglue-sdk"
SDK_DIR="third_party/rexglue-sdk"

BUILD_TYPE="RelWithDebInfo"
JOBS=""
PACKAGE=""
CLEAN=0
SKIP_SDK=0
XMA_PATCH=0

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"

# --- output ------------------------------------------------------------------

if [ -t 1 ]; then
    B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else
    B=""; R=""; Y=""; G=""; Z=""
fi

step() { printf '\n%s==> %s%s\n' "$B" "$1" "$Z"; }
info() { printf '    %s\n' "$1"; }
ok()   { printf '    %s%s%s\n' "$G" "$1" "$Z"; }
warn() { printf '    %swarning: %s%s\n' "$Y" "$1" "$Z" >&2; }
die()  { printf '\n%serror: %s%s\n' "$R" "$1" "$Z" >&2; exit 1; }

# --- arguments ---------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --package)    PACKAGE="${2:?--package needs a file}"; shift 2 ;;
        --jobs|-j)    JOBS="${2:?--jobs needs a number}"; shift 2 ;;
        --build-type) BUILD_TYPE="${2:?--build-type needs a value}"; shift 2 ;;
        --clean)      CLEAN=1; shift ;;
        --skip-sdk)   SKIP_SDK=1; shift ;;
        --xma-patch)  XMA_PATCH=1; shift ;;
        -h|--help)    sed -n '2,22p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
        *)            die "unknown option: $1 (try --help)" ;;
    esac
done

# --- platform ----------------------------------------------------------------

step "Platform"

UNAME="$(uname -s)"
case "$UNAME" in
    Darwin) PLATFORM="mac" ;;
    Linux)  PLATFORM="linux" ;;
    *)      die "$UNAME is not supported by this script; see BUILDING.md" ;;
esac

PRESET="${PLATFORM}-$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
BUILD_DIR="out/build/${PRESET}"
info "$UNAME $(uname -m), preset '${PRESET}'"

# --- tools -------------------------------------------------------------------

step "Toolchain"

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH. $2"; }

need git    "Install git."
need cmake  "macOS: brew install cmake   Linux: apt install cmake"
need ninja  "macOS: brew install ninja   Linux: apt install ninja-build"

PYTHON=""
for p in python3 python; do
    command -v "$p" >/dev/null 2>&1 && { PYTHON="$p"; break; }
done
[ -n "$PYTHON" ] || die "no python3 on PATH. macOS: brew install python"

# The SDK requires Clang and hard-fails on GCC. Check the version too: it wants
# Clang 18+ or AppleClang 16+ for C++23, and failing that check late in a
# configure is a confusing way to find out.
if [ "$PLATFORM" = "mac" ]; then
    # fetchDependencies shells out to xcodebuild, which needs the active
    # developer directory to be Xcode and not the Command Line Tools.
    XCPATH="$(xcode-select -p 2>/dev/null || true)"
    case "$XCPATH" in
        *CommandLineTools*)
            if [ -d /Applications/Xcode.app ]; then
                die "xcode-select points at the Command Line Tools, but Xcode is installed.
    Run:  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
            else
                warn "xcode-select points at the Command Line Tools and Xcode was not found."
                warn "MoltenVK's fetchDependencies will fail. See BUILDING.md for alternatives."
            fi
            ;;
    esac
    CC_BIN="$(xcrun -f clang 2>/dev/null || command -v clang)"
    CXX_BIN="$(xcrun -f clang++ 2>/dev/null || command -v clang++)"
    MIN_CLANG=16
else
    CC_BIN="${CC:-}"; CXX_BIN="${CXX:-}"
    if [ -z "$CXX_BIN" ]; then
        # Prefer a numbered clang if the default is too old; the SDK's own CI
        # pins clang-20 on Linux.
        for v in 22 21 20 19 18; do
            if command -v "clang++-$v" >/dev/null 2>&1; then
                CC_BIN="clang-$v"; CXX_BIN="clang++-$v"; break
            fi
        done
    fi
    [ -n "$CXX_BIN" ] || { CC_BIN="clang"; CXX_BIN="clang++"; }
    command -v "$CXX_BIN" >/dev/null 2>&1 || die "clang++ not found. apt install clang-20 lld-20"
    MIN_CLANG=18
fi

CLANG_VER="$("$CXX_BIN" --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9]*\).*/\1/p')"
[ -n "$CLANG_VER" ] || die "could not determine the version of $CXX_BIN"
[ "$CLANG_VER" -ge "$MIN_CLANG" ] || \
    die "clang $CLANG_VER is too old; the SDK needs $MIN_CLANG+ for C++23 ($CXX_BIN)"
info "$("$CXX_BIN" --version | head -1)"
ok "toolchain OK"

# --- parallelism -------------------------------------------------------------

# Each generated translation unit can take 1-2 GB in the compiler and there are
# 120 of them, so an unbounded build will exhaust memory long before it runs out
# of cores. Budget ~2.5 GB per job.
if [ -z "$JOBS" ]; then
    if [ "$PLATFORM" = "mac" ]; then
        NCPU="$(sysctl -n hw.ncpu)"
        MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    else
        NCPU="$(nproc)"
        MEM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 ))
    fi
    BY_MEM=$(( MEM_GB * 10 / 25 ))
    [ "$BY_MEM" -lt 1 ] && BY_MEM=1
    JOBS=$(( NCPU < BY_MEM ? NCPU : BY_MEM ))
    info "${NCPU} cpus, ${MEM_GB} GB ram -> -j${JOBS}"
    [ "$JOBS" -lt "$NCPU" ] && info "(capped by memory, not cores; override with --jobs)"
fi

# --- sdk ---------------------------------------------------------------------

if [ "$SKIP_SDK" -eq 0 ]; then
    step "rexglue SDK ${SDK_TAG}"

    if [ ! -d "$SDK_DIR/.git" ]; then
        info "cloning (~700 MB with submodules, this takes a while)"
        git clone --recursive --depth 1 -b "$SDK_TAG" --shallow-submodules \
            "$SDK_URL" "$SDK_DIR"
        ok "cloned"
    else
        HAVE="$(git -C "$SDK_DIR" describe --tags 2>/dev/null || echo unknown)"
        info "already present at ${HAVE}"
        [ "$HAVE" = "$SDK_TAG" ] || \
            warn "expected ${SDK_TAG}; a different version may not build"
    fi

    # Git on Windows checks these out as text files holding the link target
    # unless core.symlinks=true. libmspack's are used on every platform, so a
    # tree that came from Windows fails to compile without this.
    if [ -f tools/fix_symlink_checkout.py ]; then
        if ! "$PYTHON" tools/fix_symlink_checkout.py --check >/dev/null 2>&1; then
            info "materialising symlink placeholders from a Windows checkout"
            "$PYTHON" tools/fix_symlink_checkout.py || \
                warn "fix_symlink_checkout.py failed; see BUILDING.md"
        fi
    fi

    step "SDK patches"
    PATCHES="0001-imgui-iterate-cmdlists-size.patch
0003-core-getexecutablepath-without-wpgmptr.patch
0004-vulkan-additive-draw-depth-test.patch"
    [ "$XMA_PATCH" -eq 1 ] && PATCHES="$PATCHES
0002-OPTIONAL-xma-do-not-clobber-guest-read-offset.patch"

    for name in $PATCHES; do
        p="${ROOT}/patches/${name}"
        [ -f "$p" ] || { warn "missing ${name}"; continue; }
        if git -C "$SDK_DIR" apply --reverse --check "$p" >/dev/null 2>&1; then
            info "already applied  ${name%%-*} ${name#*-}"
        elif git -C "$SDK_DIR" apply --check "$p" >/dev/null 2>&1; then
            git -C "$SDK_DIR" apply "$p"
            ok "applied          ${name%%-*} ${name#*-}"
        else
            warn "could not apply ${name} - it may conflict with a newer SDK"
        fi
    done

    # MoltenVK fetches SPIRV-Cross and Vulkan-Headers with its own script
    # rather than git submodules, so --recursive does not get them and nothing
    # in the CMake does it for you.
    if [ "$PLATFORM" = "mac" ]; then
        step "MoltenVK dependencies"
        MVK="${SDK_DIR}/thirdparty/moltenvk"
        if [ -d "${MVK}/External/Vulkan-Headers" ]; then
            info "already fetched"
        elif [ -x "${MVK}/fetchDependencies" ]; then
            info "running fetchDependencies --macos (slow, clones several repos)"
            ( cd "$MVK" && ./fetchDependencies --macos ) || \
                die "fetchDependencies failed. If this is the xcodebuild error, see BUILDING.md"
            ok "fetched"
        else
            warn "no fetchDependencies script at ${MVK}"
        fi
    fi
fi

# --- generated code ----------------------------------------------------------

step "Recompiled sources"

[ -f generated/sources.cmake ] || die "generated/sources.cmake is missing.
    This tree ships the recompiled C++ - it should be in the repo.
    If you need to regenerate it, see BUILDING.md (needs game_data/default.xex)."

# The committed output must come from the v0.10.0 codegen. The 0.8.1.19 output
# defines DEFINE_REX_FUNC with __attribute__((alias)), which Mach-O rejects
# outright - 'error: aliases are not supported on darwin', once per function.
# The v0.10.0 template emits a [[clang::musttail]] thunk on Darwin instead.
if [ "$PLATFORM" = "mac" ]; then
    if ! grep -rqs "clang::musttail" generated/*.h 2>/dev/null; then
        die "generated/ is from the old (0.8.1.19) codegen and CANNOT build on macOS.
    It has no Darwin branch, so every recompiled function fails with
    'aliases are not supported on darwin'.
    Pull the regenerated sources - generated/ should hold ~250 files, not ~65.
    You currently have $(ls generated 2>/dev/null | wc -l | tr -d ' ')."
    fi
fi
info "$(ls generated | wc -l | tr -d ' ') files"
ok "recompiled sources OK"

# --- build -------------------------------------------------------------------

if [ "$CLEAN" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
    step "Cleaning"
    rm -rf "$BUILD_DIR"
    ok "removed ${BUILD_DIR}"
fi

step "Configure"
if ! cmake --preset "$PRESET" \
        -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN"; then
    die "configure failed. The log above has the reason; BUILDING.md covers the common ones."
fi
ok "configured"

step "Build (-j${JOBS})"
info "120 large translation units - expect this to take a while"
cmake --build "$BUILD_DIR" -j "$JOBS" || die "build failed"
ok "built"

# --- package import ----------------------------------------------------------

if [ -n "$PACKAGE" ]; then
    step "Importing game package"
    [ -f "$PACKAGE" ] || die "no such file: $PACKAGE"
    cmake --build "$BUILD_DIR" --target ht_import -j "$JOBS" >/dev/null || \
        die "could not build ht_import"
    "${BUILD_DIR}/ht_import" "$PACKAGE" "${BUILD_DIR}/game_data" || \
        die "import failed"
fi

# --- done --------------------------------------------------------------------

EXE="${BUILD_DIR}/hydrothunder"
step "Done"
info "executable: ${EXE}"

if [ ! -d "${BUILD_DIR}/game_data" ]; then
    cat <<EOF

    No game_data yet. Unpack your own copy of the game:

        cmake --build ${BUILD_DIR} --target ht_import
        ${BUILD_DIR}/ht_import <package-file> ${BUILD_DIR}/game_data

    The package is the file whose name is a long string of hex characters
    with no extension (~460 MB), not a default.xex.
EOF
fi

cat <<EOF

    Run it with:

        cd ${BUILD_DIR} && HT_SKIP_XEX_CHECK=1 ./hydrothunder

    HT_SKIP_XEX_CHECK=1 skips the check that demands a xextool-converted
    default.xex. xextool is Windows-only, and on SDK v0.10.0 the runtime
    decrypts and decompresses the executable itself. See BUILDING.md.

    Logs land in ${BUILD_DIR}/logs/ - rex_log.txt is always empty, ignore it.
EOF
