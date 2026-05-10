#!/bin/bash
# Build PyMuPDF for Android arm64-v8a.
#
# mupdfwrap.py drives the entire build:
#   action m  → builds libmupdf.so via GNU make (NDK cross-compiler)
#   action 0  → generates C++ wrapper source via libclang (host, no compilation)
#   action 1  → compiles C++ wrapper → libmupdfcpp.so (NDK cross-compiler via $CXX)
#   action 2  → generates Python SWIG source (host SWIG, no compilation)
#   action 3  → compiles SWIG output → _mupdf.so (NDK cross-compiler via $CXX)
#
set -eu

NDK_BIN="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
CROSS_CC="$NDK_BIN/aarch64-linux-android24-clang"
CROSS_CXX="$NDK_BIN/aarch64-linux-android24-clang++"
CROSS_AR="$NDK_BIN/llvm-ar"
CROSS_RANLIB="$NDK_BIN/llvm-ranlib"

# MuPDF uses $(LD) -r -b binary to embed font resources as .o files.
# The host ld produces x86_64 objects; we need aarch64.
# Create a wrapper that calls ld.lld with the correct emulation.
CROSS_LD="$(pwd)/aarch64-ld"
NDK_LLD="$NDK_BIN/ld.lld"
cat > "$CROSS_LD" << EOF
#!/bin/bash
exec "$NDK_LLD" -m aarch64linux "\$@"
EOF
chmod +x "$CROSS_LD"

MUPDF_VERSION="1.27.2"
MUPDF_URL="https://mupdf.com/downloads/archive/mupdf-${MUPDF_VERSION}-source.tar.gz"
MUPDF_DIR="$(pwd)/mupdf-${MUPDF_VERSION}-source"

# Build dir name must match what PyMuPDF setup.py constructs:
# {platform.machine()}-shared-release  (no tesseract, no bsymbolic for cross)
BUILD_DIR_NAME="$(uname -m)-shared-release"

# ── Download MuPDF source ─────────────────────────────────────────────────────
if [ ! -d "$MUPDF_DIR" ]; then
    echo "Downloading MuPDF ${MUPDF_VERSION}..."
    curl -L "$MUPDF_URL" -o mupdf-source.tar.gz
    tar -xzf mupdf-source.tar.gz
    rm mupdf-source.tar.gz
fi

# ── Install libclang into host Python env if missing ─────────────────────────
# build-python is the host (x86_64) Python in mobile-forge's PATH.
build-python -c "import clang.cindex" 2>/dev/null || \
    build-python -m pip install --quiet libclang

cd "$MUPDF_DIR"

# ── Patch pipcl.py to strip Android-incompatible link flags ──────────────────
# pipcl.PythonFlags reads ldflags from host python-config which includes
# -lpthread and -lutil. On Android these are part of libc; linking them
# explicitly causes "unable to find library" errors.
# We patch pipcl.py to filter these flags when PYMUPDF_ANDROID_BUILD is set.
build-python - << 'PYEOF'
import pathlib
p = pathlib.Path('scripts/pipcl.py')
src = p.read_text()
anchor = "                self.ldflags = ldflags2\n\n        log2"
patch = (
    "                self.ldflags = ldflags2\n"
    "            # Android: strip flags not available as separate libs\n"
    "            import os as _os\n"
    "            if _os.environ.get('PYMUPDF_ANDROID_BUILD'):\n"
    "                for _flag in ('-lpthread', '-lutil'):\n"
    "                    self.ldflags = self.ldflags.replace(' ' + _flag, '')\n"
    "\n        log2"
)
if anchor in src:
    p.write_text(src.replace(anchor, patch))
    print('pipcl.py patched for Android')
elif 'PYMUPDF_ANDROID_BUILD' in src:
    print('pipcl.py already patched')
else:
    print('WARNING: pipcl.py patch anchor not found, skipping')
PYEOF

# ── Run mupdfwrap.py: all actions with NDK cross-compiler ────────────────────
# We set CXX to the NDK cross-compiler so actions 1 and 3 use it.
# Action 0 (libclang parsing) and action 2 (SWIG) don't invoke CXX.
# Action m passes CC/CXX/AR/RANLIB/LD to make via --m-vars.
#
# We unset CFLAGS/LDFLAGS from the crossenv so MuPDF's thirdparty libs
# (which have their own build systems) don't get confused by Android flags.
# The NDK cross-compiler already targets arm64 by default.
unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS

export CC="$CROSS_CC"
export CXX="$CROSS_CXX"
export AR="$CROSS_AR"
export RANLIB="$CROSS_RANLIB"
export PYMUPDF_ANDROID_BUILD=1

build-python ./scripts/mupdfwrap.py \
    -d "build/${BUILD_DIR_NAME}" \
    -b \
    --m-vars "CC=${CROSS_CC} CXX=${CROSS_CXX} AR=${CROSS_AR} RANLIB=${CROSS_RANLIB} LD=${CROSS_LD} \
        HAVE_X11=no HAVE_GLUT=no \
        USE_TESSERACT=no USE_ZXINGCPP=no USE_LIBARCHIVE=no \
        HAVE_LIBCRYPTO=no \
        barcode=no \
        XCFLAGS=-fPIC" \
    m0123

cd ..

# ── Package with pip install ──────────────────────────────────────────────────
# PYMUPDF_SETUP_MUPDF_REBUILD=0 → skip re-running mupdfwrap.py.
# PYMUPDF_SETUP_MUPDF_BUILD    → path to mupdf source dir with pre-built libs.
export PYMUPDF_SETUP_MUPDF_REBUILD=0
export PYMUPDF_SETUP_MUPDF_BUILD="$MUPDF_DIR"
export PYMUPDF_SETUP_MUPDF_TESSERACT=0
export PYMUPDF_SETUP_FLAVOUR=pb

pip install \
    --no-build-isolation \
    --no-deps \
    .
