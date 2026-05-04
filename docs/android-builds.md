# Building Android wheels with mobile-forge

This document describes how to set up mobile-forge for Android and how to
build the two DjVu recipes (`flet-libdjvulibre` and `python-djvulibre`)
that the `doc-layout` app depends on.

---

## Prerequisites

### 1. Android NDK

Install the Android NDK.  Download the Linux zip from the
[NDK releases page](https://github.com/android/ndk/releases), unpack it,
and set `NDK_HOME` to its root directory.  For example, with r27d unpacked
to `$HOME/ndk/r27d`:

```bash
export NDK_HOME=$HOME/ndk/r27d
```

mobile-forge uses `NDK_HOME` to locate the correct `clang` compiler when
creating cross-compilation environments.  Without it the compiler path
baked into the Python-for-Android support package (which points at the CI
runner that built it) will be used, and the build will fail on a local
machine.

### 2. Python-for-Android support package

mobile-forge needs pre-built Python binaries for the Android target
architectures.  These can be obtained by building
[flet-dev/python-for-android](https://github.com/flet-dev/python-for-android)
from source.  For `doc-layout`, Python 3.12.12 was built locally and the
result placed at `$HOME/projects/python-build/android/`:

```bash
export MOBILE_FORGE_ANDROID_SUPPORT_PATH=$HOME/projects/python-build/android
```

Alternatively, some versions are published as release archives on that
repository's releases page — check there for a pre-built zip if you do not
want to build from source.

Download and unpack the support package for the Python version you need
(3.12 for `doc-layout`):

```bash
# example — check the releases page for the current URL
wget https://github.com/flet-dev/python-for-android/releases/download/3.12.8/python-3.12.8-android.zip
unzip python-3.12.8-android.zip -d $HOME/projects/python-build/android
export MOBILE_FORGE_ANDROID_SUPPORT_PATH=$HOME/projects/python-build/android
```

The directory must contain:

```
$MOBILE_FORGE_ANDROID_SUPPORT_PATH/
  install/android/
    arm64-v8a/python-3.12.x/bin/python3.12
    x86_64/python-3.12.x/bin/python3.12
    armeabi-v7a/python-3.12.x/bin/python3.12   # 3.12 only
    x86/python-3.12.x/bin/python3.12            # 3.12 only
```

### 3. Clone and activate mobile-forge

```bash
git clone https://github.com/beeware/mobile-forge.git
cd mobile-forge
source setup.sh 3.12
```

`setup.sh` will:
- Download a standalone CPython build for the host (Linux x86-64)
- Create a virtualenv `venv3.12/` and install mobile-forge into it
- Build the small platform-dependency wheels (`make_dep_wheels.py`)
- Print example `forge` commands

After sourcing, your shell is inside the `venv3.12` virtualenv.

---

## Building a single recipe

The general form is:

```bash
forge android:<api_level>:<arch> <recipe-name>
```

For `doc-layout` we target **API 24, arm64-v8a**:

```bash
forge android:24:arm64-v8a flet-libdjvulibre
forge android:24:arm64-v8a python-djvulibre
```

Successful wheels land in `dist/`:

```
dist/
  flet_libdjvulibre-3.5.29-0-py3-none-android_24_arm64_v8a.whl
  python_djvulibre-0.8.8-cp312-cp312-android_24_arm64_v8a.whl
```

Build logs go to `logs/`, failure logs to `errors/`.

---

## Recipe reference

### `flet-libdjvulibre` — DjVuLibre C library

| Field | Value |
|-------|-------|
| Recipe dir | `recipes/flet-libdjvulibre/` |
| Library version | 3.5.29 |
| Source | SourceForge tarball |
| Output | static `libdjvu.a` + headers, packaged as a wheel |
| Depends on | `flet-libjpeg` |

This is a **non-Python recipe** — it has a `build.sh` instead of a Python
package.  `build.sh` runs the standard autoconf cross-compile:

```bash
./configure --host=$HOST_TRIPLET --build=$BUILD_TRIPLET \
    --prefix=$PREFIX \
    --disable-shared --enable-static \
    --disable-desktopfiles --disable-xmltools --without-tiff \
    JPEG_CFLAGS="-I$PREFIX/include" JPEG_LIBS="-L$PREFIX/lib -ljpeg"
make -j $CPU_COUNT && make install
```

The result is installed into `$PREFIX` (which maps to `opt/` inside the
wheel's site-packages).  CLI tools and docs are stripped; only the library
and headers are kept.

**Why static?**  The `.a` is linked directly into the `python-djvulibre`
Cython extension (`.so`).  Android does not allow loading chains of shared
libraries from app-private directories, so bundling everything into one
`.so` is the safe approach.

### `python-djvulibre` — Cython bindings

| Field | Value |
|-------|-------|
| Recipe dir | `recipes/python-djvulibre/` |
| Package version | 0.8.8 |
| Source | GitHub fork (`ssppkenny/python-djvulibre`, `master` branch) |
| Output | `python_djvulibre-0.8.8-cp312-cp312-android_24_arm64_v8a.whl` |
| Depends on | `flet-libdjvulibre 3.5.29`, `flet-libcpp-shared` |

**Why the GitHub fork instead of PyPI?**  The PyPI 0.8.8 tarball still
contains Python 2/3 compatibility shims (`IF PY3K`, `PyInt_Check`,
`PyString_Check`) that do not compile with Cython 3 + Python 3.12.  The
fork has these removed.

#### Patches

Two patches are applied before the build:

**`cython3-compat.patch`** — fixes `djvu/common.pxi`:

Cython 3 no longer allows `cimport` aliases to be called as functions.
The patch replaces the aliased imports of `PyLong_Check`, `PyUnicode_Check`,
etc. with `cdef inline` wrapper functions:

```cython
# before (Cython 2 style)
from cpython cimport PyLong_Check as is_int

# after (Cython 3 compatible)
from cpython cimport PyLong_Check
cdef inline bint is_int(object o):
    return PyLong_Check(o)
```

**`cross-compile.patch`** — fixes `setup.py` for cross-compilation:

1. **Bypasses `pkg-config`** — `pkg-config` cannot query the target
   (Android) sysroot from the host.  The patch makes
   `pkgconfig_build_flags()` check for `DJVULIBRE_INCLUDE_DIR` /
   `DJVULIBRE_LIB_DIR` env vars first and return the flags directly.

2. **Bypasses `pkg-config` for version detection** — `get_djvulibre_version()`
   is patched to read `DJVULIBRE_VERSION` from the environment instead of
   calling `pkg-config --modversion ddjvuapi`.

3. **Preserves `CFLAGS`** — the original `setup.py` calls
   `os.environ.pop('CFLAGS', None)` as a workaround for a CPython bug.
   This must be disabled for cross-compilation because mobile-forge injects
   the NDK sysroot and include paths via `CFLAGS`.

4. **`HAVE_LANGINFO_H`** — Android Bionic does not provide `langinfo.h`.
   The patch reads `HAVE_LANGINFO_H` from the environment (set to `False`
   in `meta.yaml`) instead of assuming `os.name == 'posix'` means it is
   available.

#### `meta.yaml` `script_env`

The recipe injects these environment variables into the build:

```yaml
build:
  script_env:
    DJVULIBRE_INCLUDE_DIR: '{platlib}/opt/include'
    DJVULIBRE_LIB_DIR:     '{platlib}/opt/lib'
    DJVULIBRE_VERSION:     '3.5.29'
    HAVE_LANGINFO_H:       'False'
```

`{platlib}` is expanded by mobile-forge to the cross-venv's
site-packages directory, where `flet-libdjvulibre` is unpacked.

---

## Adding a new recipe

### Pure-Python package (no C extensions)

Create `recipes/<name>/meta.yaml`:

```yaml
package:
  name: my-package
  version: 1.2.3
```

That is often sufficient.  Run:

```bash
forge android:24:arm64-v8a my-package
```

### Python package with C extensions

Same `meta.yaml`, but you may need patches if:

- The build calls `pkg-config` for a system library → bypass with env vars
  (see `cross-compile.patch` above as a template)
- `setup.py` has `if sys.platform == ...` guards that miss Android
- The package uses `CFLAGS` stripping or other host-only assumptions

Put patches in `recipes/<name>/patches/` and list them in `meta.yaml`:

```yaml
patches:
  - my-fix.patch
```

Declare host (Android-side) library dependencies:

```yaml
requirements:
  build:
    - cython >=3.0      # runs on the host machine during build
  host:
    - flet-libjpeg 3.0.90   # installed into the cross-venv site-packages
```

### Non-Python C/C++ library (`build.sh` recipe)

Use this when you need to cross-compile a C library and package it as a
wheel so Python packages can depend on it.

```
recipes/my-lib/
  meta.yaml
  build.sh
```

`meta.yaml`:

```yaml
package:
  name: my-lib
  version: 1.0.0

source:
  url: https://example.com/my-lib-1.0.0.tar.gz

build:
  number: 0

requirements:
  host:
    - flet-libjpeg 3.0.90   # if your lib needs jpeg
```

`build.sh` — key environment variables available:

| Variable | Description |
|----------|-------------|
| `CC` | C compiler (NDK clang, targeting the Android arch) |
| `CXX` | C++ compiler |
| `AR` | Archiver |
| `RANLIB` | Ranlib |
| `CFLAGS` | Compiler flags including NDK sysroot and `$PREFIX/include` |
| `CXXFLAGS` | Same for C++ |
| `LDFLAGS` | Linker flags including `$PREFIX/lib` |
| `PREFIX` | Install destination — content here becomes the wheel |
| `HOST_TRIPLET` | e.g. `aarch64-linux-android` |
| `BUILD_TRIPLET` | e.g. `x86_64-unknown-linux-gnu` |
| `CPU_COUNT` | Number of CPUs for parallel make |
| `CROSS_VENV_SDK` | `android` (or `ios`) |

Install into `$PREFIX` — mobile-forge wraps the contents into a wheel.
Headers end up at `opt/include/`, libraries at `opt/lib/` inside the
wheel's site-packages, and these paths are automatically added to
`CFLAGS`/`LDFLAGS` for any package that lists your lib as a host
requirement.

Minimal `build.sh` for an autoconf library:

```bash
#!/bin/bash
set -eu

export CFLAGS="$CFLAGS -fPIC"   # required: .a will be linked into a .so
export CXXFLAGS="$CFLAGS"

./configure \
    --host=$HOST_TRIPLET \
    --build=$BUILD_TRIPLET \
    --prefix=$PREFIX \
    --disable-shared \
    --enable-static

make -j $CPU_COUNT
make install

# strip anything not needed at runtime
rm -rf $PREFIX/bin $PREFIX/share $PREFIX/lib/pkgconfig $PREFIX/lib/*.la
```

### Custom source URL

If the package is not on PyPI, set `source.url` in `meta.yaml`.
`{version}` and `{build}` are interpolated:

```yaml
source:
  url: https://github.com/org/repo/archive/refs/heads/master.tar.gz
```

or with version interpolation:

```yaml
source:
  url: https://example.com/pkg-{version}.tar.gz
```

---

## Troubleshooting

**`crossenv` uses wrong compiler path**
Set `NDK_HOME` before sourcing `setup.sh`.  mobile-forge passes `--cc` to
crossenv only when `NDK_HOME` is present.

**`pkg-config` not found / returns wrong flags**
Expected for cross-compilation.  Bypass it with env vars in `script_env`
and a patch to `setup.py` (see `cross-compile.patch`).

**`langinfo.h` not found**
Android Bionic omits this header.  Set `HAVE_LANGINFO_H: 'False'` in
`script_env` and patch the source to read it from the environment.

**Cython 3 compile errors (`cimport` alias called as function)**
Wrap the aliased imports in `cdef inline` functions (see
`cython3-compat.patch`).

**Build log location**
- Success: `logs/<package>-<platform>.log`
- Failure: `errors/<package>-<platform>.log`
