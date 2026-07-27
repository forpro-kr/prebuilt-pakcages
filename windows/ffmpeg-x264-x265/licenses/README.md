# License inputs

License text is sourced from the exact pinned source checkout, not from a manually
maintained copy:

- `build/sources/ffmpeg/COPYING.GPLv2`
- `build/sources/x264/COPYING`
- `build/sources/x265/COPYING`

Run `scripts/fetch-sources.ps1` to materialize those files. The package script
fails closed unless all three files exist and embeds them into both the binary
package and corresponding source archive.

Authoritative references:

- FFmpeg legal: https://ffmpeg.org/legal.html
- FFmpeg license: https://ffmpeg.org/doxygen/trunk/md_LICENSE.html
- x264 COPYING: https://code.videolan.org/videolan/x264/-/blob/master/COPYING
- x265 COPYING:
  https://bitbucket.org/multicoreware/x265_git/src/master/COPYING

The GPL text and component notices distributed with a binary must match its
pinned source. H.264/HEVC patent licensing is separate from these copyright
licenses.
