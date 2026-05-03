#!/bin/bash
set -eu

if [ $CROSS_VENV_SDK == "android" ]; then
    # DjVuLibre uses autoconf. Cross-compile for Android using the NDK toolchain.
    # We disable TIFF (not needed for basic DjVu rendering) and XML tools (CLI only).
    # JPEG is provided by flet-libjpeg installed in $PREFIX.

    # -fPIC is required: the static library will be linked into a Python
    # extension (.so), which is itself a shared library.
    export CFLAGS="$CFLAGS -fPIC -I$PREFIX/include"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="$LDFLAGS -L$PREFIX/lib"

    # Android NDK does not provide a ranlib that autoconf can find by name;
    # point it explicitly.
    export RANLIB="$RANLIB"

    ./configure \
        --host=$HOST_TRIPLET \
        --build=$BUILD_TRIPLET \
        --prefix=$PREFIX \
        --disable-shared \
        --enable-static \
        --disable-desktopfiles \
        --disable-xmltools \
        --without-tiff \
        JPEG_CFLAGS="-I$PREFIX/include" \
        JPEG_LIBS="-L$PREFIX/lib -ljpeg"
else
    # iOS / simulator
    export CFLAGS="$CFLAGS -I$PREFIX/include"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="$LDFLAGS -L$PREFIX/lib"

    ./configure \
        --host=$HOST_TRIPLET \
        --build=$BUILD_TRIPLET \
        --prefix=$PREFIX \
        --disable-shared \
        --enable-static \
        --disable-desktopfiles \
        --disable-xmltools \
        --without-tiff \
        JPEG_CFLAGS="-I$PREFIX/include" \
        JPEG_LIBS="-L$PREFIX/lib -ljpeg"
fi

make -j $CPU_COUNT
make install

# Remove CLI tools and docs — only the library and headers are needed
rm -rf $PREFIX/bin
rm -rf $PREFIX/share
rm -rf $PREFIX/lib/{pkgconfig,*.la}
