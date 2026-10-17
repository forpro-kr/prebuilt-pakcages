# Windows FFmpeg patch series

## x64 continuous bitrate contract

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
- NVENC uses a copy of the accepted configuration. A pure rate reduction with
  no DAR change or peak/VBV increase does not request reset/IDR. Increases and
  format-related changes retain upstream behavior. The vendor call's failure
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
NVENC 60/120 FPS decreases, repeated requests, failure/retry, zero peak sentinel,
DAR change, unsupported capability and unchanged legacy behavior. Actual AMD
and NVIDIA throughput, output bitrate and keyframe behavior remain separate
device acceptance checks.

## ARM64 Media Foundation patch series

Apply only to the ARM64 exported FFmpeg source, in this order:

1. `0001-mf-low-delay.patch`: explicit encoder `VT_BOOL` low-latency/B=0, counted async events, nonblocking output polling and input surface attributes. Exposes contract version 1.
2. `0002-mf-upstream-fixes.patch`: input type geometry/FPS for strict hardware MFTs, DXGI device-manager reference release, scenario reapplication before low-latency/B=0. Raises the required contract to version 2.

Base: FFmpeg `dd00a614e16a15db0b230dfe45790e913e593695` (`n8.0-19-gdd00a614e1`). Keep the original checkout clean and the existing avcodec 62 / avutil 60 ABI. x64 does not apply this series.

Upstream provenance:

- [126671e73065: AVLowLatencyMode support](https://github.com/FFmpeg/FFmpeg/commit/126671e73065e29c9582e47bc74774af2200fc8f). Our adaptation uses `VT_BOOL` for the encoder property as specified by [Microsoft](https://learn.microsoft.com/en-us/windows/win32/medfound/codecapi-avlowlatencymode), not upstream's `VT_UI4`.
- [b2910ec92ef0: release DXGI manager](https://github.com/FFmpeg/FFmpeg/commit/b2910ec92ef0f12f2cee56be331f8ae234ead4a4).
- [9acd820732f0: set input frame attributes](https://github.com/FFmpeg/FFmpeg/commit/9acd820732f0bf738bd743bbde6a5c3eadc216c2).

The async credit/polling changes and scenario reapplication are local adaptations, not claims of upstream merge. RePC chooses Qualcomm `camera_record` to avoid VFR dropping/timestamp behavior, following [Chromium's MF encoder rationale](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/media/gpu/windows/media_foundation_video_encode_accelerator_win.cc); low latency and B=0 remain independent requirements. Runtime latency and throughput must be measured; these settings do not guarantee zero driver copies or a fixed latency.

`mfLowDelayPatchSha256` is SHA-256 of the ordered, newline-terminated individual patch SHA-256 values. Paths are excluded so source-package extraction does not change it. Include this series and upstream source/license materials in the corresponding-source package.
