# Windows FFmpeg patch series

## 2026-10-27 QSV CBR/VBR and continuous rate contract

After `0003`, x64 applies `0004-qsv-continuous-bitrate.patch` to the same locked
FFmpeg revision. H.264/HEVC/AV1 QSV expose explicit `repc_rate_control` (0 upstream,
1 CBR, 2 VBR), runtime `repc_continuous_bitrate`, and read-only
`repc_applied_bitrate`, `repc_applied_peak_bitrate`, `repc_applied_rc`,
`repc_bitrate_quantum` and `repc_bitrate_error`.

- Applied rates are MFX `GetVideoParam` readback in bits/second, not context
  fields or an output packet estimate. The quantum reports the driver's BRC
  multiplier. Unsupported explicit modes fail startup rather than silently
  normalizing to another mode.
- Runtime changes support existing CBR/VBR sessions only. Query verifies reset
  option support and `StartNewSequence=OFF` for the unchanged profile, geometry,
  frame rate, format and extension data. An independently owned copy is used
  for each query/reset/readback/rollback, including HDR buffers.
- Delayed packets and their PTS/bitstream/sync ownership remain in the FIFO.
  Drain/sync loops use a requested-frame-time deadline (60 and 120 FPS separately).
  Pending SDK references are retained on timeout until encoder close.
- Successful reset/readback reports accepted target/peak and leaves the coded
  sequence intact. A rejected query or verified rollback reports error 1 before
  submitting the new input, preserving the session and recovery-IDR intent.
  Unconfirmed rollback or pending GPU timeout reports applied rate -1/error -1;
  the caller must close the encoder. No context recreation is hidden in this path.
- The continuity contract applies to bitrate changes, not unrelated dynamic
  changes of geometry, GOP or QP. Missing options identify an older pack; the
  application must keep that session unchanged rather than pretending success.
- `qsvContinuousBitratePatchSha256` separately fingerprints this patch for x64
  cache reuse and packaging. The corresponding-source archive includes this
  patch. QSV AV1 is now explicitly enabled in the x64 build configuration.

Run `tests/test-qsv-continuous-bitrate.py --build-dir build/windows-codecs/x64
--compiler C:/msys64/ucrt64/bin/gcc.exe --runtime-dir
build/windows-codecs/x64/runtime` after building. It executes the actual patched
functions with injected MFX dispatch, covers CBR/VBR at 60/120, output ownership,
Query mutation, readback/rollback/timeout and independent sessions, and loads the
built DLLs to check public options without opening Intel hardware. Actual Intel
throughput, output convergence and reconnect acceptance are separate checks.

## x64 continuous bitrate contract

2026-10-31 NVENC contract version 2 extends reference-preserving rate updates
to increases as well as reductions. NVENC H.264/HEVC expose the read-only
`repc_continuous_bitrate_version=2`. An application must require version 2 for
an increase; an older pack may still force an IDR despite accepting the original
boolean option. The value is explicitly published after successful encoder init;
unopened, failed-init and closing contexts report 0. FFmpeg skips read-only
AVOptions when applying defaults, so the option's default metadata of 2 is not
used as field initialization. AMF keeps its existing contract and options.

`0003-continuous-bitrate.patch` applies only to x64 on the same pinned FFmpeg
base below. It is a local adaptation, not an upstream merge. AMF/NVENC H.264
and HEVC expose `repc_continuous_bitrate` (boolean, default 0) and read-only
`repc_applied_bitrate` (bits/second). An app may enable the option after open;
absence means an older codec pack does not support the contract.

- Set `AVCodecContext.bit_rate` and `rc_max_rate` on the encoder's owner thread.
  Changes apply before the next input is consumed. Read the applied option
  after send/receive to confirm driver acceptance; accepting an app request
  alone is not proof of applying it.
- AMF changes existing TargetBitrate and PeakBitrate, verifies GetProperty,
  and restores both on any failure. Peak is max(target, requested maximum).
  The original VBV and static properties remain unchanged. No Drain, Init,
  session recreation, or IDR is requested. CQP rejects dynamic changes.
- AMF confirmed rollback returns an error and restores AVCodecContext rates
  to previous properties. Failed rollback returns an error and sets applied
  bitrate to -1; the caller must stop using that encoder. Otherwise old applied
  bitrate remains available for recovery. Driver readback does not guarantee
  immediate encoded-output convergence.
- NVENC uses a copy of the accepted configuration. Opted-in pure rate changes,
  including target/peak/VBV increases, do not request reset/IDR. A transaction
  that also changes DAR and applications that have not opted in retain upstream
  behavior. Explicit per-frame recovery-IDR requests remain independent. The vendor call's failure
  propagates before input upload, preserves the accepted configuration, and
  keeps applied bitrate unchanged. The caller can restore prior AVCodecContext
  rates to continue the same session. Unsupported dynamic rate control fails.

`continuousBitratePatchSha256` is the SHA-256 of patch bytes. x64 build reuse
and packaging both require the current hash. The original FFmpeg checkout stays
clean; the build exports its exact locked revision and applies the patch there.
The corresponding-source archive includes the entire package folder, this patch,
the build scripts and the locked upstream sources.

Regression command after source export/configuration (no hardware required):

```powershell
python windows/ffmpeg-x264-x265/tests/test-continuous-bitrate.py --build-dir build/windows-codecs/x64 --compiler C:/msys64/ucrt64/bin/gcc.exe
```

The harness compiles the actual update functions with vendor headers and fake
dispatch tables. It covers H.264/HEVC AMF decreases/increases, partial failure,
readback mismatch, rollback failure, legacy opt-out and CQP rejection, plus
NVENC 60/120 FPS increases/reductions, repeated requests, failure/retry, zero peak sentinel,
DAR change, unsupported capability and unchanged legacy behavior. Actual AMD
and NVIDIA throughput, output bitrate and keyframe behavior remain separate
device acceptance checks.

A portable NVENC-only harness can also run against the exported source and
the locked NVENC header directory without Windows/AMF adapters:

```sh
python windows/ffmpeg-x264-x265/tests/test-nvenc-continuous-bitrate-policy.py --source-dir <patched-ffmpeg-source> --nvcodec-include <nv-codec-headers/include> --compiler clang
```

It executes the actual patched transaction for H.264/HEVC at 60/120 FPS,
10–50 Mbps ramps, failure/rollback state, independent owners, DAR changes and
legacy opt-out. Optional `--avutil-include <include> --avutil-library <library>`
executes real libavutil defaults/get/set calls: the version stays 0 before init,
publishes 2 after the actual NVENC init body succeeds, rejects writes, and returns
to 0 after a failed re-init or at close entry. Vendor init calls are controlled;
this is not a GPU open. The runtime-option probe in `test-continuous-bitrate.py`
verifies unopened value 0, default metadata 2 and read-only flags, and rejects
writes after the new DLL has been built. Source tests do
not validate an existing DLL; rebuild and check the patch hash before packaging.

## ARM64 Media Foundation patch series

Apply only to the ARM64 exported FFmpeg source, in this order:

1. `0001-mf-low-delay.patch`: explicit encoder `VT_BOOL` low-latency/B=0, counted async events, nonblocking output polling and input surface attributes. Exposes contract version 1.
2. `0002-mf-upstream-fixes.patch`: input type geometry/FPS for strict hardware MFTs, DXGI device-manager reference release, scenario reapplication before low-latency/B=0. Raises the required contract to version 2.
3. `0005-mf-vbr-peak.patch`: verifies explicit VBR mode/target/peak SetValue and
   GetValue after Media Foundation negotiation, exposing `repc_vbr_peak_version=1`.
   The existing low-delay version 2 remains unchanged. It is ARM64-only.

Base: FFmpeg `dd00a614e16a15db0b230dfe45790e913e593695` (`n8.0-19-gdd00a614e1`). Keep the original checkout clean and the existing avcodec 62 / avutil 60 ABI. x64 does not apply this series.

Upstream provenance:

- [126671e73065: AVLowLatencyMode support](https://github.com/FFmpeg/FFmpeg/commit/126671e73065e29c9582e47bc74774af2200fc8f). Our adaptation uses `VT_BOOL` for the encoder property as specified by [Microsoft](https://learn.microsoft.com/en-us/windows/win32/medfound/codecapi-avlowlatencymode), not upstream's `VT_UI4`.
- [b2910ec92ef0: release DXGI manager](https://github.com/FFmpeg/FFmpeg/commit/b2910ec92ef0f12f2cee56be331f8ae234ead4a4).
- [9acd820732f0: set input frame attributes](https://github.com/FFmpeg/FFmpeg/commit/9acd820732f0bf738bd743bbde6a5c3eadc216c2).

The async credit/polling changes and scenario reapplication are local adaptations, not claims of upstream merge. RePC chooses Qualcomm `camera_record` to avoid VFR dropping/timestamp behavior, following [Chromium's MF encoder rationale](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/media/gpu/windows/media_foundation_video_encode_accelerator_win.cc); low latency and B=0 remain independent requirements. Runtime latency and throughput must be measured; these settings do not guarantee zero driver copies or a fixed latency.

`mfLowDelayPatchSha256` is SHA-256 of the ordered, newline-terminated individual patch SHA-256 values. Paths are excluded so source-package extraction does not change it. Include this series and upstream source/license materials in the corresponding-source package.
