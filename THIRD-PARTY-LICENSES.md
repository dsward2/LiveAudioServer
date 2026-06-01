# Third-party software included in LiveAudioServer

LiveAudioServer itself is licensed under Apache-2.0 (see [LICENSE](LICENSE)).
This file documents the third-party libraries that are statically linked into
the distributed `liveaudioserver` binary and the license terms that apply to
them.

## libmp3lame (LAME) — LGPL-2.1-or-later

LiveAudioServer bundles **LAME 3.100** for MP3 encoding. LAME is distributed
under the GNU Lesser General Public License, version 2.1 or later
(LGPL-2.1+).

- Upstream project: https://lame.sourceforge.io
- License text: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
- Source distribution used for the bundled build:
  https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
  (SHA256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`)

### LGPL compliance — re-linking against a modified libmp3lame

Section 6 of LGPL-2.1 permits static linking of LGPL libraries into otherwise
non-LGPL programs **provided** the recipient can replace the bundled
libmp3lame with a modified version and re-link.

To satisfy this requirement, LiveAudioServer ships the exact, fully
reproducible recipe used to build the bundled `libmp3lame.a`:

- [`scripts/build-mp3lame-xcframework.sh`](scripts/build-mp3lame-xcframework.sh)
  downloads LAME 3.100 from the URL above, builds it for arm64 and x86_64
  with the documented `CFLAGS`/`LDFLAGS`, and packages the result as the
  `Frameworks/Mp3Lame.xcframework` that SwiftPM consumes.

To produce a `liveaudioserver` binary linked against a *modified* LAME, edit
`LAME_VERSION` / `LAME_URL` / `LAME_SHA256` in that script (or substitute the
unpacked source tree at `.build-mp3lame/lame-${LAME_VERSION}`), then re-run:

```bash
./scripts/build-mp3lame-xcframework.sh
swift build -c release
```

The resulting `.build/release/LiveAudioServer` is statically linked against
your modified libmp3lame.

The Apache-2.0-licensed parts of LiveAudioServer (everything under
`Sources/`) remain Apache-2.0; only the bundled LAME object code is
LGPL-licensed.

## AudioToolbox, Network.framework, Foundation — Apple

LiveAudioServer dynamically links against frameworks that ship with macOS
13+. These are governed by the macOS software license and are not
redistributed by this project.
