#!/bin/sh
# ports/netsurf/build.sh's part in the mynos-netsurf container: NetSurf
# and its libraries built (for Linux: its build runs tools it builds),
# then the program linked again for MyNOS, and staged.
set -eu
w=/mynos/build/netsurf
ns=$w/netsurf-all-3.11
inst=$ns/inst-framebuffer
export CC=musl-gcc
# (from the environment: the Makefiles add theirs to these)
export LDFLAGS=-static
# small: a MyNOS program must fit in 4 MB (one page table); the MyNOS
# surface includes libmynos's headers
export CFLAGS="-I/mynos/mynos-lib/include -Os -fno-asynchronous-unwind-tables -fno-unwind-tables -ffunction-sections -fdata-sections"

if [ ! -f $inst/lib/libz.a ]; then
  (cd $w/zlib-1.3.1 && CC=musl-gcc CFLAGS="$CFLAGS" ./configure --static --prefix=$inst >/dev/null &&
   make -s >/dev/null && make -s install >/dev/null)
fi
# PNG and JPEG, with musl, static, into the same prefix
if [ ! -f $inst/lib/libpng16.a ]; then
  (cd $w/libpng-1.6.44 && CPPFLAGS="-I$inst/include" LDFLAGS="-static -L$inst/lib" \
   ./configure --host=i686-linux-musl --disable-shared --enable-static --prefix=$inst >/dev/null &&
   make -s >/dev/null && make -s install >/dev/null)
fi
if [ ! -f $inst/lib/libjpeg.a ]; then
  (cd $w/jpeg-9f && ./configure --host=i686-linux-musl --disable-shared --enable-static --prefix=$inst >/dev/null &&
   make -s >/dev/null && make -s install >/dev/null)
fi
# expat: XML for libdom, which libsvgtiny reads SVG with
if [ ! -f $inst/lib/libexpat.a ]; then
  (cd $w/expat-2.6.4 && ./configure --host=i686-linux-musl --disable-shared --enable-static \
     --without-docbook --without-examples --without-tests --without-xmlwf --prefix=$inst >/dev/null &&
   make -s >/dev/null && make -s install >/dev/null)
fi
rm -f $inst/build-stamp
cd $ns
make -s TARGET=framebuffer \
  NETSURF_USE_CURL=NO NETSURF_USE_OPENSSL=NO NETSURF_USE_JPEG=YES NETSURF_USE_PNG=YES \
  NETSURF_USE_WEBP=NO NETSURF_USE_JPEGXL=NO NETSURF_USE_ROSPRITE=NO NETSURF_USE_HARU_PDF=NO \
  NETSURF_FB_FONTLIB=internal NETSURF_USE_DUKTAPE=YES WITH_EXPAT_BINDING=yes \
  NETSURF_USE_NSSVG=YES > $w/build.log 2>&1 || { tail -30 $w/build.log; exit 1; }

# for MyNOS: its load address, libmynos before musl, the surface's calls
# (weak in it) kept
cd $ns/netsurf
L=$inst/lib
musl-gcc -o nsfb-mynos build/Linux-framebuffer/*.o \
  -static -Wl,-Ttext-segment=0x40000000 -Wl,-z,noseparate-code -Wl,--build-id=none -Wl,--gc-sections \
  -Wl,-u,__stdio_read -Wl,-u,__stdio_write -Wl,-u,__stdout_write -Wl,-u,__stdio_seek -Wl,-u,__stdio_close \
  -L$L -Wl,--start-group -lsvgtiny -lcss -lparserutils -lwapcaplet -ldom -lexpat -lhubbub -lnsutils -lpng16 -ljpeg -lz -lutf8proc -lnsbmp -lnsgif -lnspsl -lnslog -Wl,--end-group -lm \
  -Wl,--whole-archive -lnsfb -Wl,--no-whole-archive \
  -Wl,-u,mynos_send,-u,mynos_recv,-u,mynos_freeMsg,-u,mynos_freeChannel,-u,mynos_connectToPort \
  -Wl,-u,mynos_registryLookUp,-u,mynos_log,-u,wire_writer_init,-u,wire_writer_free,-u,wire_put_int \
  -Wl,-u,wire_put_cstring,-u,wire_put_string,-u,wire_reader_init,-u,wire_get_int,-u,wire_get_string \
  -L/mynos/mynos-lib/lib -lmynos

# the stage: the program, its resources (English only), Choices
s=$w/stage
rm -rf $s; mkdir -p $s/res $s/home/.netsurf
cp nsfb-mynos $s/nsfb && strip $s/nsfb
(cd frontends/framebuffer/res && for f in *; do
   case $f in de|fr|it|ja|nl|zh_CN) ;; *) cp -rL "$f" $s/res/ ;; esac; done)
printf 'enable_javascript:1\n' > $s/home/.netsurf/Choices
