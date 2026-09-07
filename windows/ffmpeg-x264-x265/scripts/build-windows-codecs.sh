#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: build-windows-codecs.sh <x64|arm64> <source-root> <build-root> <build-lock> <parallel> <clean>"
  exit 2
fi

architecture="$1"
source_root="$2"
build_root="$3"
build_lock="$4"
parallel="$5"
clean="$6"

case "$architecture" in
  x64)
    ffmpeg_arch="x86_64"
    x264_host="x86_64-w64-mingw32"
    ;;
  arm64)
    ffmpeg_arch="aarch64"
    x264_host="aarch64-w64-mingw32"
    ;;
  *)
    echo "unsupported architecture: $architecture"
    exit 2
    ;;
esac

for tool in clang clang++ cmake ninja make pkg-config git python tar llvm-readobj; do
  command -v "$tool" >/dev/null || {
    echo "required MSYS2 tool is missing: $tool"
    exit 3
  }
done

for source_name in ffmpeg x264 x265; do
  test -d "$source_root/$source_name/.git" || {
    echo "missing pinned source: $source_root/$source_name"
    exit 4
  }
done

if [[ "$clean" == "1" && -d "$build_root" ]]; then
  case "$build_root" in
    */build/windows-codecs/*) rm -rf -- "$build_root" ;;
    *)
      echo "refusing to clean unexpected build root: $build_root"
      exit 5
      ;;
  esac
fi

prefix="$build_root/prefix"
runtime="$build_root/runtime"
mkdir -p "$build_root" "$prefix" "$runtime"

x264_build="$build_root/x264"
if [[ ! -f "$prefix/lib/pkgconfig/x264.pc" ||
      ! -f "$prefix/lib/libx264.dll.a" ||
      -z "$(find "$prefix/bin" -maxdepth 1 -name '*x264*.dll' -print -quit)" ]]; then
  mkdir -p "$x264_build"
  pushd "$x264_build" >/dev/null
  CC=clang \
  AR=llvm-ar \
  RANLIB=llvm-ranlib \
  STRIP=llvm-strip \
  PKGCONFIG=pkg-config \
  "$source_root/x264/configure" \
    --host="$x264_host" \
    --prefix="$prefix" \
    --enable-shared \
    --disable-cli \
    --disable-opencl
  make -j"$parallel"
  make install
  popd >/dev/null
else
  echo "x264 install already present; reusing $prefix"
fi

if [[ ! -f "$prefix/lib/pkgconfig/x265.pc" ||
      ! -f "$prefix/lib/libx265.dll.a" ||
      ! -f "$prefix/bin/libx265.dll" ]]; then
  x265_source_export="$build_root/x265-source"
  rm -rf -- "$x265_source_export" "$build_root/x265"
  mkdir -p "$x265_source_export"
  git -C "$source_root/x265" archive --format=tar HEAD |
    tar -xf - -C "$x265_source_export"

  cmake -S "$x265_source_export/source" -B "$build_root/x265" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_SHARED_LINKER_FLAGS=-static-libstdc++ \
    -DENABLE_SHARED=ON \
    -DENABLE_CLI=OFF \
    -DENABLE_ASSEMBLY=ON \
    -DHIGH_BIT_DEPTH=OFF
  cmake --build "$build_root/x265" --parallel "$parallel"
  cmake --install "$build_root/x265"
else
  echo "x265 install already present; reusing $prefix"
fi

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
package_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mf_patches=("$package_root/patches/0001-mf-low-delay.patch" "$package_root/patches/0002-mf-upstream-fixes.patch")
mf_patch_hash=""
mf_configuration=""
encoder_json='"libx264", "libx265"'
if [[ "$architecture" == "arm64" ]]; then
  command -v patch >/dev/null || { echo "required MSYS2 tool is missing: patch"; exit 3; }
  # Hash ordered patch contents, not checkout-specific absolute paths.
  mf_patch_hash="$(sha256sum "${mf_patches[@]}" | cut -d' ' -f1 | sha256sum | cut -d' ' -f1)"
  mf_configuration=" --enable-mediafoundation --enable-encoder=h264_mf,hevc_mf"
  encoder_json+=', "h264_mf", "hevc_mf"'
fi
ffmpeg_namespace_ready() {
  local avcodec="$prefix/bin/repc-codec-avcodec-62.dll"
  local avutil="$prefix/bin/repc-codec-avutil-60.dll"
  local swscale="$prefix/bin/repc-codec-swscale-9.dll"
  [[ -f "$avcodec" && -f "$avutil" && -f "$swscale" ]] || return 1
  if [[ "$architecture" == "arm64" ]]; then
    [[ -f "$prefix/repc-mf-patch.sha256" ]] || return 1
    [[ "$(<"$prefix/repc-mf-patch.sha256")" == "$mf_patch_hash" ]] || return 1
  fi
  llvm-readobj --coff-imports "$avcodec" |
    grep -qi 'Name: repc-codec-avutil-60\.dll' || return 1
  llvm-readobj --coff-imports "$swscale" |
    grep -qi 'Name: repc-codec-avutil-60\.dll' || return 1
}

if ! ffmpeg_namespace_ready; then
  ffmpeg_build="$build_root/ffmpeg"
  rm -rf -- "$ffmpeg_build"
  rm -f -- \
    "$prefix"/bin/avcodec-*.dll \
    "$prefix"/bin/avutil-*.dll \
    "$prefix"/bin/swscale-*.dll \
    "$prefix"/bin/repc-codec-avcodec-*.dll \
    "$prefix"/bin/repc-codec-avutil-*.dll \
    "$prefix"/bin/repc-codec-swscale-*.dll \
    "$prefix"/lib/libavcodec.dll.a \
    "$prefix"/lib/libavutil.dll.a \
    "$prefix"/lib/libswscale.dll.a \
    "$prefix"/lib/librepc-codec-avcodec.dll.a \
    "$prefix"/lib/librepc-codec-avutil.dll.a \
    "$prefix"/lib/librepc-codec-swscale.dll.a \
    "$prefix"/lib/avcodec-*.def \
    "$prefix"/lib/avutil-*.def \
    "$prefix"/lib/swscale-*.def \
    "$prefix"/lib/repc-codec-avcodec-*.def \
    "$prefix"/lib/repc-codec-avutil-*.def \
    "$prefix"/lib/repc-codec-swscale-*.def
  mkdir -p "$ffmpeg_build"
  ffmpeg_source="$source_root/ffmpeg"
  ffmpeg_extra=()
  if [[ "$architecture" == "arm64" ]]; then
    # Export pinned source; never mutate the shared upstream checkout. This
    # patch ships in the package source archive with the build instructions.
    ffmpeg_source="$ffmpeg_build/source"
    mkdir -p "$ffmpeg_source"
    git -C "$source_root/ffmpeg" archive --format=tar HEAD | tar -xf - -C "$ffmpeg_source"
    # git apply inside a parent repository can silently skip exported paths.
    for mf_patch in "${mf_patches[@]}"; do
      patch --batch --forward -d "$ffmpeg_source" -p1 -i "$mf_patch"
    done
    grep -q '"repc_low_delay_version".*i64 = 2' "$ffmpeg_source/libavcodec/mfenc.c"
    grep -q 'IMFDXGIDeviceManager_Release(c->dxgiManager)' "$ffmpeg_source/libavcodec/mfenc.c"
    ffmpeg_extra=(--enable-mediafoundation --enable-encoder=h264_mf,hevc_mf)
  fi
  pushd "$ffmpeg_build" >/dev/null
  "$ffmpeg_source/configure" \
    --prefix="$prefix" \
    --target-os=mingw32 \
    --arch="$ffmpeg_arch" \
    --cc=clang \
    --cxx=clang++ \
    --enable-gpl \
    --enable-shared \
    --disable-static \
    --enable-libx264 \
    --enable-libx265 \
    --disable-autodetect \
    --disable-everything \
    --enable-avcodec \
    --enable-avutil \
    --enable-swscale \
    --enable-decoder=av1 \
    --enable-decoder=h264 \
    --enable-decoder=hevc \
    --enable-encoder=libx264 \
    --enable-encoder=libx265 \
    --enable-parser=av1 \
    --enable-parser=h264 \
    --enable-parser=hevc \
    --enable-d3d11va \
    --enable-dxva2 \
    --enable-hwaccel=av1_d3d11va \
    --enable-hwaccel=h264_d3d11va \
    --enable-hwaccel=hevc_d3d11va \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --extra-cflags="-I$prefix/include" \
    --extra-ldflags="-L$prefix/lib" \
    "${ffmpeg_extra[@]}"
  sed -i \
    's|^SLIBNAME_WITH_MAJOR=.*|SLIBNAME_WITH_MAJOR=repc-codec-$(FULLNAME)-$(LIBMAJOR)$(SLIBSUF)|' \
    ffbuild/config.mak
  make -j"$parallel"
  make install
  if [[ "$architecture" == "arm64" ]]; then
    printf '%s\n' "$mf_patch_hash" > "$prefix/repc-mf-patch.sha256"
  fi
  popd >/dev/null
else
  echo "FFmpeg install already present; reusing $prefix"
fi

if ! ffmpeg_namespace_ready; then
  echo "FFmpeg namespace validation failed: optional libraries must import repc-codec-avutil-60.dll"
  exit 8
fi

rm -f -- "$runtime"/*.dll
runtime_inputs=(
  "$prefix/bin/repc-codec-avcodec-62.dll"
  "$prefix/bin/repc-codec-avutil-60.dll"
  "$prefix/bin/repc-codec-swscale-9.dll"
  "$prefix/bin/libx265.dll"
)
shopt -s nullglob
x264_runtime=("$prefix"/bin/libx264-*.dll)
if [[ ${#x264_runtime[@]} -ne 1 ]]; then
  echo "expected exactly one versioned x264 runtime DLL under $prefix/bin"
  exit 6
fi
runtime_inputs+=("${x264_runtime[0]}")
for required_path in "${runtime_inputs[@]}"; do
  test -f "$required_path" || {
    echo "required RePC runtime is missing: $required_path"
    exit 7
  }
done
cp -f -- "${runtime_inputs[@]}" "$runtime/"

x264_revision="$(git -C "$source_root/x264" rev-parse HEAD)"
x265_revision="$(git -C "$source_root/x265" rev-parse HEAD)"
ffmpeg_revision="$(git -C "$source_root/ffmpeg" rev-parse HEAD)"
build_lock_python="$(cygpath -m "$build_lock")"
expected_x264="$(python -c "import json; print(json.load(open(r'$build_lock_python'))['components']['x264']['revision'])")"
expected_x265="$(python -c "import json; print(json.load(open(r'$build_lock_python'))['components']['x265']['revision'])")"
expected_ffmpeg="$(python -c "import json; print(json.load(open(r'$build_lock_python'))['components']['ffmpeg']['revision'])")"
test "$x264_revision" = "$expected_x264"
test "$x265_revision" = "$expected_x265"
test "$ffmpeg_revision" = "$expected_ffmpeg"

runtime_json=""
for dll_path in "$runtime"/*.dll; do
  dll_name="$(basename "$dll_path")"
  if [[ -n "$runtime_json" ]]; then
    runtime_json+=","
  fi
  runtime_json+="\"$dll_name\""
done

clang_version="$(clang --version | head -n 1 | sed 's/"/\\"/g')"
cmake_version="$(cmake --version | head -n 1 | sed 's/"/\\"/g')"
cat >"$runtime/repc-ffmpeg-codec-build.json" <<EOF
{
  "schema": 1,
  "architecture": "$architecture",
  "ffmpegRevision": "$ffmpeg_revision",
  "x264Revision": "$x264_revision",
  "x265Revision": "$x265_revision",
  "configuration": "--enable-gpl --enable-shared --disable-static --enable-libx264 --enable-libx265$mf_configuration",
  "encoders": [$encoder_json],
  "mfLowDelayPatchSha256": "$mf_patch_hash",
  "runtimeFiles": [$runtime_json],
  "toolchain": {
    "environment": "${MSYSTEM:-unknown}",
    "compiler": "$clang_version",
    "cmake": "$cmake_version"
  }
}
EOF

echo "codec runtime and manifest generated: $runtime"
