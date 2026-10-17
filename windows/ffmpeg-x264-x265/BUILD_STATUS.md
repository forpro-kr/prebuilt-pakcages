# Build status

## 2026-10-18 x64 continuous bitrate validation

- Implemented opt-in `repc_continuous_bitrate` for AMF/NVENC H.264/HEVC,
  with driver-confirmed `repc_applied_bitrate` and explicit error/rollback behavior.
- Exact pinned FFmpeg export plus `0003-continuous-bitrate.patch` built with
  UCRT64 GCC 15.2.0, `build-windows-codecs.ps1 -Architecture x64 -Parallel 12`:
  **PASS**. The original `build/sources/ffmpeg` checkout remains clean.
- x64 `repc-codec-avcodec-62.dll` SHA-256:
  `c1560e7915cadc1df459fbe87515737327a5a673136c97be88938f1be7aeae31`.
  After the full build, the NVENC queue-capacity preflight was added, its object
  and DLL rebuilt incrementally, and the build script's final validation/staging
  passed again. The final runtime and manifest use this corrected patch.
- `test-continuous-bitrate.py` compiled the production update functions against
  vendor headers and passed fake-dispatch transaction/failure/rollback checks.
  NVENC policy cases include both 60 and 120 FPS buffer sizes.
- The built DLLs passed public-option probing for all four encoders, including
  rejection of writes to the applied-rate read-only option. This probe allocates
  codec contexts but does not open a hardware encoder.
- `test-package-contract.ps1`, Bash syntax and `git diff --check`: **PASS**.
- Runtime output: `build/windows-codecs/x64/runtime`. Build manifest patch hash
  is checked against patch bytes; x64 packaging rejects a stale manifest.
- RePC GPU integration on RTX 3080 (driver 32.0.16.1088): patched FFmpeg
  H.264/HEVC at both 60/120 FPS settings, 1280x720, 8 to 3 Mbps, **4/4 PASS**.
  Each run encoded and hardware-decoded 60 frames with only the initial keyframe,
  applied rate 3000 Kbps, no pending change and no bitrate recovery restart.
  Evidence: sibling `repc/build/parsec-encoder-bitrate-20261018/gpu-continuity-results.json`.
- **Runtime acceptance pending:** actual AMD hardware, sustained bitrate convergence,
  P99 frame submission time and actual two-PC simultaneous display streams.
  No service replacement, installer/source archive creation, signing or public
  release was performed by this validation.

Commands:

```powershell
python windows/ffmpeg-x264-x265/tests/test-continuous-bitrate.py --build-dir build/windows-codecs/x64 --compiler C:/msys64/ucrt64/bin/gcc.exe --runtime-dir build/windows-codecs/x64/runtime
./windows/ffmpeg-x264-x265/tests/test-package-contract.ps1
```

기준일: 2026-07-27

## 완료

- 공식 FFmpeg, x264, x265 upstream의 pinned revision checkout
- FFmpeg `LIBAVCODEC_VERSION_MAJOR 62` 확인
- 세 source tree의 `COPYING.GPLv2`/`COPYING` 존재 확인
- Windows x64/ARM64 shared build runner 구현 및 PowerShell/Bash 구문 검증
- GPL flags, revision, encoder, runtime ABI, license/source bundle fail-closed 검사
- ZIP/source archive/SHA-256/NSIS packaging과 per-user uninstall 계약
- MSYS2 `make 4.4.1`, NASM `2.16.03`, diffutils `3.12`, patch `2.7.6` 설치
- NSIS `makensis 3.12` 확인
- CLANGARM64 clean build 완료:
  - namespaced `repc-codec-avcodec-62.dll`,
    `repc-codec-avutil-60.dll`, `repc-codec-swscale-9.dll`
  - avcodec/swscale import table이 namespaced avutil만 참조하는 fail-closed 검사
  - `libx264-165.dll`, `libx265.dll`
  - 전 파일 `IMAGE_FILE_MACHINE_ARM64`
  - namespaced avcodec가 `libx264-165.dll`과 `libx265.dll`을 import
  - x265의 MSYS2 `libc++.dll` 의존성을 정적 링크로 제거
- RePC `1.0.0` ARM64 ZIP, 대응 소스 ZIP, versioned/stable NSIS installer,
  build manifest와 SHA-256 생성
- NSIS silent per-user 설치 완료 및 RePC runtime probe 통과:
  `runtime=1 x264=1 x265=1`
- 실제 encoder open/encode 확인:
  - x264 H.264 encode 5 / D3D11VA decode 5 / D3D11 render 5
  - x265 HEVC encode 5 / D3D11VA decode 5 / D3D11 render 5
  - 반복 context open 뒤 발생하던 `0xC0000005`는 namespaced ABI에서 재현되지 않음

## 남은 release / acceptance

| 항목 | 상태 | 해소 방법 |
|---|---|---|
| Authenticode | Pending | 생성한 versioned/stable NSIS installer를 ForPro release certificate로 서명한다. |
| ARM64 end-to-end | Pass with transport retry note | x264 H.264와 x265 HEVC가 각각 5프레임 encode/D3D11VA decode/D3D11 render를 완료하고 exit 0을 반환했다. 첫 runtime/x264 smoke의 BUD handshake timeout은 같은 명령 재시도에서 통과했으므로 RePC transport startup race로 별도 추적한다. |
| UI/install lifecycle | Pending | clean ARM64 장비에서 설치 전 배너/링크, 설치 후 배너 해제, upgrade/downgrade/uninstall, Squirrel update 보존을 검증한다. |
| Windows x64 | Pending | UCRT64 clean build, NSIS package, 설치 및 x264/x265 encode/decode acceptance를 수행한다. |
| Release publish | Pending | stable URL에 서명된 installer, source ZIP, build manifest, `SHA256SUMS`를 함께 게시한다. |

2026-07-27 ARM64 package는 로컬 `dist/`에 생성했다. 바이너리는 Git에 커밋하지
않으며, 서명과 공개 release 업로드 전까지 production 배포 완료로 표시하지 않는다.
media smoke에서 두 software encoder와 기본 D3D11VA decoder/render가 각각 5프레임을
end-to-end 처리했다. 이전 선택 팩과 기본 decoder의 동명 FFmpeg DLL 충돌은
`repc-codec-*` namespace로 제거했다. 다만 첫 runtime/x264 smoke의 local BUD
handshake timeout, UI lifecycle, 서명과 공개 배포가 남아 production release
완료로 표시하지 않는다.

재현 명령:

```powershell
.\scripts\build-windows-codecs.ps1 -Architecture arm64 -Clean -Parallel 12
.\scripts\package-codec-pack.ps1 `
  -Architecture arm64 `
  -Version 1.0.0 `
  -RuntimeDir .\build\windows-codecs\arm64\runtime `
  -BuildManifestPath .\build\windows-codecs\arm64\runtime\repc-ffmpeg-codec-build.json `
  -SourceRoot .\build\sources `
  -NsisCompilerPath 'C:\Program Files (x86)\NSIS\makensis.exe' `
  -RequireNsis
```
