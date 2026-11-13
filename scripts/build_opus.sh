#!/bin/bash
set -euo pipefail
mkdir -p build/codec-sources Vendor/include/opus Vendor/lib SimpleMusic/Licenses artifacts
fetch() {
  local name="$1" url="$2" digest="$3"
  curl --fail --location --retry 3 "$url" -o "build/codec-sources/$name"
  printf '%s  %s\n' "$digest" "build/codec-sources/$name" | shasum -a 256 -c -
  tar -xzf "build/codec-sources/$name" -C build/codec-sources
}
fetch opus-1.6.1.tar.gz https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
fetch opusfile-0.12.tar.gz https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz 118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b
fetch libvorbis-1.3.7.tar.gz https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz 0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab
fetch libogg-1.3.6.tar.gz https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638
ROOT="$PWD"
for sdk in iphoneos iphonesimulator; do
  prefix="$ROOT/build/codec-$sdk/install"
  common=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF)
  cmake -S build/codec-sources/libogg-1.3.6 -B "build/codec-$sdk/ogg" "${common[@]}" -DINSTALL_DOCS=OFF -DINSTALL_PKG_CONFIG_MODULE=OFF -DINSTALL_CMAKE_PACKAGE_MODULE=OFF
  cmake --build "build/codec-$sdk/ogg" --parallel 3
  cmake --install "build/codec-$sdk/ogg"
  cmake -S build/codec-sources/opus-1.6.1 -B "build/codec-$sdk/opus" "${common[@]}" -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_DRED=OFF -DOPUS_OSCE=OFF -DOPUS_DISABLE_INTRINSICS=ON -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF
  cmake --build "build/codec-$sdk/opus" --parallel 3
  cmake --install "build/codec-$sdk/opus"
  cmake -S build/codec-sources/libvorbis-1.3.7 -B "build/codec-$sdk/vorbis" "${common[@]}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DOGG_INCLUDE_DIR="$prefix/include" -DOGG_LIBRARY="$prefix/lib/libogg.a" -DINSTALL_CMAKE_PACKAGE_MODULE=OFF
  cmake --build "build/codec-$sdk/vorbis" --parallel 3
  cmake --install "build/codec-$sdk/vorbis"
  mkdir -p "build/codec-$sdk/opusfile" "Vendor/lib/$sdk"
  sdkroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  target=arm64-apple-ios17.0
  if [ "$sdk" = iphonesimulator ]; then target=arm64-apple-ios17.0-simulator; fi
  for source in info internal opusfile stream; do
    xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sdkroot" -O2 -std=c99 -DOP_DISABLE_HTTP -DHAVE_LRINTF -DHAVE_FSEEKO \
      -I"$prefix/include" -I"$prefix/include/opus" -Ibuild/codec-sources/opusfile-0.12/include \
      -c "build/codec-sources/opusfile-0.12/src/$source.c" -o "build/codec-$sdk/opusfile/$source.o"
  done
  xcrun libtool -static -o "Vendor/lib/$sdk/libSimpleOpus.a" "$prefix/lib/libopus.a" "$prefix/lib/libvorbis.a" "$prefix/lib/libvorbisfile.a" "$prefix/lib/libogg.a" "build/codec-$sdk/opusfile/"*.o
  lipo "Vendor/lib/$sdk/libSimpleOpus.a" -verify_arch arm64
  cp -R "$prefix/include/"* Vendor/include/
done
cp build/codec-sources/opusfile-0.12/include/opusfile.h Vendor/include/opus/
python3 scripts/collect_licenses.py
printf '%s\n' 'opus=1.6.1 (SHA256-verified official source)' 'opusfile=0.12 (SHA256-verified official source)' 'ogg=1.3.6 (SHA256-verified official source)' 'vorbis=1.3.7 (SHA256-verified official source; vorbisfile/core only linked)'  'arm64 iphoneos and iphonesimulator; static; HTTP, DRED, OSCE and SIMD intrinsics disabled' > artifacts/codec-build.txt
