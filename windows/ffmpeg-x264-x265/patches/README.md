# ARM64 Media Foundation patch series

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
