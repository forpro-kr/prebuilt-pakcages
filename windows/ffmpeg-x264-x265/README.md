# AirDesk Windows FFmpeg x264/x265 codec pack

## AirDesk 0.1.2 staging — 2026-10-28

현재 build lock `0.1.2`의 새 NSIS·manifest·산출물 이름은 AirDesk를 사용한다.
앱의 현재 공개 `0.1.1` pin과 기존 설치/제거 소유권은 별도로 유지한다.
loader는 새 AirDesk HKLM64 경로를 먼저 읽고, 없으면 기존 machine/user pack을 읽는다.
DLL namespace `repc-codec-*`와 GPL 라이선스·소스 커밋·GitHub 저장소 ID는 바꾸지 않는다.

`-PlanOnly`와 x64/ARM64 synthetic NSIS compile fixture는 설치 경로/제거 계약 검증이다.
fixture EXE는 실제 코덱을 담은 배포 후보가 아니므로 실행·서명·게시하지 않는다.
현재 x64 cached manifest에는 필수 `packageVersion`이 없고 ARM64 runtime cache도 없어
실제 `0.1.2` 설치기는 lock에 맞는 runtime 재빌드 후에 생성해야 한다.
캐시 manifest를 새 버전으로 relabel하거나 공개 `0.1.1` 파일을 덮어쓰지 않는다.

배포 순서: lock과 일치하는 빌드/manifest → unsigned package → hash/PE/codec 검증 →
회사 서명 및 timestamp 검증 → 대응 소스/manifest/installer 동시 게시 → 공개 bytes 검증 →
앱 다운로드 URL·설치 SHA/pin 승인 전환 → 실제 새 설치/제거 및 legacy 호환 검증.
이번 source 변경만으로 서명·배포·설치가 완료되었다고 표시하지 않는다.

## Package version

`build-lock.json`의 최상위 `version`이 x64·ARM64 codec pack 버전의 단일 원천이다.
builder는 이 값을 manifest의 `packageVersion`에 기록하고 package script는 버전을
생략하면 같은 값을 사용한다. 명시한 `-Version` 또는 build manifest 버전이 lock과
다르면 packaging을 거부하므로 오래된 CI 인자와 다른 버전의 manifest가 섞이지 않는다.
버전 변경은 이 lock을 먼저 수정하고 build manifest·설치 파일·대응 소스 ZIP을 다시
생성한다. CI도 별도 상수 대신 lock의 버전을 읽거나 package의 기본값을 사용한다.

## 2026-10-27 QSV bitrate policy

`0004-qsv-continuous-bitrate.patch` adds explicit CBR/VBR and checked continuous
rate updates to H.264/HEVC/AV1 QSV. It preserves pending output, queries sequence
continuation, verifies MFX target/peak/mode and rolls back failed resets. The x64
build and package manifest require the matching QSV patch hash. See the patch
contract and focused tests below; Intel hardware acceptance is not implied by
the injected-SDK tests or a successful Windows DLL build.

## 2026-10-18 x64 live bitrate updates

`0003-continuous-bitrate.patch` adds opt-in AMF/NVENC H.264/HEVC live updates.
AMF updates and verifies existing target/peak properties; NVENC pure decreases
preserve references without requesting reset/IDR. Vendor failures propagate and
the read-only applied bitrate reports confirmed state. Apps must detect the
option before using this contract. Patch hashing invalidates the x64 build
cache and prevents packaging a stale runtime with new corresponding sources.
See [patch contract and tests](patches/README.md) for rollback semantics and
the separate hardware acceptance requirements.

## 2026-09-10 Windows x64 확장

- x64 UCRT/GCC 팩에 FFmpeg NVENC/QSV/AMF(H.264/HEVC)를 추가했다. x264/x265는 마지막 소프트웨어 폴백이다. NVIDIA/AMD/Intel 드라이버 자체는 포함하지 않는다.
- nv-codec-headers, AMF, oneVPL 소스도 build-lock으로 고정한다. oneVPL dispatcher는 정적으로 빌드한다.
- 새 NSIS는 사용자별이 아닌 관리자 설치다: `%ProgramW6432%\AirDesk\codecs\ffmpeg\<arch>\<version>`. HKLM 64-bit view의 활성 경로를 통해 SYSTEM 서비스와 사용자 앱이 같은 팩을 찾는다. 기존 버전은 자동 삭제하지 않는다.
- `/S`로 silent 설치가 가능하며 서비스 재시작은 하지 않는다. 메인 설치기의 다운로드 체크박스는 아직 연동하지 않았다.
- `package-codec-pack.ps1 -Sign -SignToolPath <signtool.exe>`로 선택적 서명/검증 후 SHA256SUMS를 생성한다. 서명하지 않은 로컬 산출물은 공개 배포 승인으로 간주하지 않는다.
- 아래 LocalAppData/ARM64 위주 내용은 이전 버전 이력이다. x64 실기기 인코딩과 NSIS acceptance는 별도로 기록한다.

Windows 하드웨어 인코더를 사용할 수 없을 때 RePC가 선택적으로 설치하는
GPL FFmpeg software codec pack이다.

ARM64 팩은 추가로 `h264_mf`/`hevc_mf` 하드웨어 인코더를 포함한다. x64
구성은 바꾸지 않는다. `patches/0001-mf-low-delay.patch`는 pinned FFmpeg의
LOW_DELAY를 MF 저지연 속성/B=0에 연결하고 비동기 이벤트 크레딧과 출력
polling을 수정한다. 다음 `0002-mf-upstream-fixes.patch`는 upstream의
입력 타입 속성 및 DXGI manager 해제 수정을 backport하고 scenario를 저지연/B=0
이전에 재적용한다. `repc_low_delay_version=2`로 앱이 계약을 확인한다.
순서대로 결합한 패치 SHA-256(`mfLowDelayPatchSha256`)이 바뀌면 ARM64 FFmpeg를
다시 빌드한다. 원본 checkout은 변경하지 않으며 export에 패치한다.
두 패치는 대응 소스 ZIP에도 포함된다. 출처와 적용 순서는 [patches/README.md](patches/README.md)를 따른다.
MF 표면은 D3D11 NV12이며 CPU readback은 요구하지 않지만 드라이버 내부
복사 제거 또는 일정한 인코딩 지연은 보장하지 않는다.

## 고정 upstream

[`build-lock.json`](build-lock.json)이 다음 공식 upstream과 revision을 고정한다.

- FFmpeg: `https://git.ffmpeg.org/ffmpeg.git`
- x264: `https://code.videolan.org/videolan/x264.git`
- x265: `https://bitbucket.org/multicoreware/x265_git.git`

FFmpeg revision은 RePC 기본 decoder가 사용하는 libavcodec 62/libavutil 60/
libswscale 9 ABI와 맞춘다. 선택 팩은 앱 내장 decoder DLL과 충돌하지 않도록
`repc-codec-avcodec-62.dll`, `repc-codec-avutil-60.dll`,
`repc-codec-swscale-9.dll` 전용 namespace를 사용한다. upstream `master`로
임의 갱신하면 안 된다.

## 산출물 계약

architecture별 release에는 다음 파일을 함께 게시한다.

```text
AirDesk-ffmpeg-<arch>-<version>.zip
AirDesk-ffmpeg-<arch>-<version>-setup.exe
AirDesk-ffmpeg-<arch>-setup.exe
AirDesk-ffmpeg-<arch>-<version>-source.zip
AirDesk-ffmpeg-codec-build-<arch>.json
SHA256SUMS
```

`<arch>`는 `x64` 또는 `arm64`다. 버전 없는 setup 파일은 새 AirDesk release alias이며 내용은 같은 버전의 setup 파일과 동일해야 한다.
서명·대응 소스 게시·공개 해시 검증 후 앱의 URL/pin을 이 별칭으로 전환한다.

새 설치 경로와 활성 등록 키:

```text
%ProgramW6432%\AirDesk\codecs\ffmpeg\<arch>\<version>
HKLM64\Software\AirDesk\FFmpegCodecPack\<arch>
```

기존 서명된 `0.1.1`의 `ForPro\RePC` machine 경로/등록 키와
`%LOCALAPPDATA%\ForPro\RePC\codecs\ffmpeg\<arch>`는 앱의 읽기 전용 호환 fallback이다.
새 installer가 이 경로나 옛 uninstall entry를 수정·복사·이름 변경하지 않는다.
기존 `RePC-ffmpeg-x64-0.1.1-setup.exe`의 공개 URL·SHA-256·서명은 불변이며
AirDesk 경로를 설치하는 새 패키지라고 표기하지 않는다.

## 실행

필수 도구는 MSYS2 UCRT64/CLANGARM64의 Clang, CMake, Ninja, pkg-config와
MSYS `git`, `make`다. NSIS 설치 파일을 만들려면 별도로 `makensis.exe`가 필요하다.
현재 장비의 실제 시도와 blocker는 [`BUILD_STATUS.md`](BUILD_STATUS.md)에 기록한다.

1. 정확한 source checkout과 라이선스 원문을 준비한다.

```powershell
.\scripts\fetch-sources.ps1
```

2. MSYS2 UCRT64 또는 CLANGARM64에서 x264, x265, FFmpeg shared runtime과
   `repc-ffmpeg-codec-build.json`을 만든다.

```powershell
.\scripts\build-windows-codecs.ps1 -Architecture arm64 -Clean
```

명령 계획만 확인하려면 `-PlanOnly`를 사용한다. 실제 manifest 형식은
[`repc-ffmpeg-codec-build.example.json`](repc-ffmpeg-codec-build.example.json)을
따른다.

3. ZIP, source archive 및 NSIS 설치 파일을 만든다.

```powershell
.\scripts\package-codec-pack.ps1 `
  -Architecture arm64 `
  -RuntimeDir .\build\windows-codecs\arm64\runtime `
  -BuildManifestPath .\build\windows-codecs\arm64\runtime\repc-ffmpeg-codec-build.json `
  -SourceRoot .\build\sources `
  -NsisCompilerPath 'C:\Program Files (x86)\NSIS\makensis.exe' `
  -RequireNsis
```

현재 저장소에는 재현 입력, source fetch, MSYS2 shared build, 검증·패키징과
NSIS 설치 계약이 있다. 2026-07-27 Windows ARM64 clean build, source ZIP,
ZIP/NSIS 생성, silent install, runtime encoder 탐지와 host x264/x265 encode까지
통과했다. BUD decode/render, 설치 UI lifecycle, Authenticode와 공개 release,
Windows x64 acceptance는 남아 있다. 상세 상태는
[`BUILD_STATUS.md`](BUILD_STATUS.md)를 따른다.

## release gate

- `--enable-gpl --enable-shared --enable-libx264 --enable-libx265`
- encoder `libx264`, `libx265`
- required namespaced ABI `repc-codec-avcodec-62.dll`,
  `repc-codec-avutil-60.dll`, `repc-codec-swscale-9.dll`
- 정확한 세 component source tree와 COPYING
- NSIS `makensis.exe`
- clean Windows ARM64/x64에서 설치·실행·encode/decode acceptance
