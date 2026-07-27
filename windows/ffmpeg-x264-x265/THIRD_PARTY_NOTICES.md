# Third-party notices

This package definition builds and redistributes the following upstream projects.

| Component | Upstream | Pinned license input |
|---|---|---|
| FFmpeg | https://git.ffmpeg.org/ffmpeg.git | `COPYING.GPLv2` from the pinned source |
| x264 | https://code.videolan.org/videolan/x264.git | `COPYING` from the pinned source |
| x265 | https://bitbucket.org/multicoreware/x265_git.git | `COPYING` from the pinned source |

The release packaging script copies those exact files into the binary package as
`licenses/FFmpeg-COPYING.GPLv2.txt`, `licenses/x264-COPYING.txt`, and
`licenses/x265-COPYING.txt`.

The package is intentionally treated as GPL software because FFmpeg is configured
with `--enable-gpl`, `--enable-libx264`, and `--enable-libx265`. Review the
complete corresponding source and license files distributed with each release.
This notice is not a substitute for the license text and is not legal advice.
