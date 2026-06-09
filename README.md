# LiveAudioServer

Project home: <https://github.com/dsward2/LiveAudioServer>

A zero-UI macOS command-line tool that reads **live 16-bit PCM audio from stdin or a UDP/TCP socket** and streams it simultaneously as **MP3** and **AAC/M4A** over HTTP — with no intermediate files, no third-party server, and no container process.

> ⚠️ **Experimental — use at your own risk.** This project was created with
> the help of Claude AI and is intended for hobbyist use on a private LAN.
> It has not been audited for security and has not been load-tested for
> production capacity. Do not expose it directly to the public internet
> without putting it behind an audited reverse proxy and additional
> hardening of your own.

Built entirely in Swift using:
- **libmp3lame** — MP3 encoding
- **AudioToolbox** (built into macOS) — AAC-LC encoding with ADTS framing
- **Network.framework** (built into macOS) — HTTP server

---

## Architecture

```
PCM input (raw 16-bit signed little-endian, interleaved)
  source: stdin │ UDP socket │ TCP socket
  layout: 1 or 2 channels, typically 48 kHz (configurable via --rate)
    │
    ▼
PCMReader               ← blocking read loop on a dedicated thread
    │
    ▼
PCMBroadcaster          ← fan-out: same PCM chunk → both encoders
    │                  │
    ▼                  ▼
MP3Encoder          AACEncoder
(libmp3lame)        (AudioToolbox / AudioConverter)
    │                  │
    ▼                  ▼
ChunkBroadcaster   ChunkBroadcaster
[mp3]              [m4a]
    │                  │
    └──────┬───────────┘
           ▼
      HTTPServer (NWListener)
           │
    ┌──────┴──────┐
    ▼             ▼
 /stream.mp3   /stream.m4a
 (Icecast-     (ADTS AAC,
  style MP3)    audio/aac)
```

### Key design decisions

| Concern | Approach |
|---|---|
| No file buffering | PCM chunks streamed chunk-by-chunk; clients get data as fast as it encodes |
| Multiple clients | `ChunkBroadcaster` fans each encoded chunk to all connected clients with back-pressure limiting (2 MB) |
| Seeking/scrubbing | Not applicable — this is a live stream; `Transfer-Encoding: chunked`, no `Content-Length` |
| AAC container | Raw ADTS frames (7-byte header per frame). No MP4/moov atom needed — clients decode ADTS natively |
| SIGPIPE safety | `signal(SIGPIPE, SIG_IGN)` — client disconnect never kills the server process |
| Thread model | Stdin reader: one dedicated thread. HTTP: `NWConnection` on a concurrent GCD queue. Encoders: inline on PCM reader thread |

---

## Install — pre-built binary (recommended for non-developers)

If you just want to run LiveAudioServer without installing Xcode or any
developer tools:

1. Go to the [Releases page](https://github.com/dsward2/LiveAudioServer/releases)
   and download the latest `LiveAudioServer-vX.Y.Z-macos-universal.zip`.
2. Unzip it (Finder will do this when you double-click).
3. Open the unzipped folder and **right-click `Start LiveAudioServer.command`
   → Open** (see "First-launch Gatekeeper note" below — this only matters
   the first time). A Terminal window opens, the server starts with
   defaults tuned for the Gqrx + RTL-SDR use case, and prints the LAN URL
   you can open from another device on the network.
4. Press Control-C in that window (or close it) to stop the server.

On every subsequent run, you can simply double-click the launcher.

To change defaults (UDP input port, sample rate, channels, Bonjour name),
open `Start LiveAudioServer.command` in TextEdit and edit the `LAS_*`
variables near the top.

### First-launch Gatekeeper note

The `liveaudioserver` binary inside the zip *is* signed with an Apple
Developer ID and fully notarized — Gatekeeper accepts it without any
prompts. The wrapper that's still flagged is `Start LiveAudioServer.command`,
which is a plain shell script. macOS doesn't support notarizing shell
scripts, so the first time you run it from a downloaded zip you'll see:

> "Apple could not verify '\<name\>' is free of malware…"

This is a one-time prompt. To get past it:

**macOS 13–14** — In Finder, **right-click** (or Control-click)
`Start LiveAudioServer.command` and choose **Open**. A second dialog
appears with an actual **Open** button — click it. The script runs and
macOS remembers your choice for future launches.

**macOS 15 (Sequoia) and later** — Apple removed the right-click bypass.
Instead:

1. Double-click `Start LiveAudioServer.command` once (it'll get blocked).
2. Open **System Settings → Privacy & Security**, scroll to the **Security**
   section near the bottom.
3. You'll see "`Start LiveAudioServer.command` was blocked to protect your
   Mac." Click **Open Anyway**.
4. Confirm with your password / Touch ID.

After that one-time approval, the launcher opens normally on every
subsequent run.

> A future release will replace this loose-script launcher with a proper
> notarized `.app` bundle so the first-launch prompt goes away entirely.

### Typical setup: Gqrx → LiveAudioServer → iPhone

1. In **Gqrx**, enable *Remote Control → Network → UDP output* (default port
   `7355`, 48 kHz, stereo).
2. Double-click `Start LiveAudioServer.command`.
3. On your iPhone (same Wi-Fi), open Safari and go to
   `http://<your-mac-name>.local:8080/`. The status page has an embedded
   player — tap **Play**.

---

## Use as a Swift Package

LiveAudioServer also ships as a SwiftPM library product so a host macOS app
(SwiftUI, AppKit, whatever) can start and stop the server in-process without
spawning the CLI. Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/dsward2/LiveAudioServer.git", from: "0.1.3"),
],
targets: [
    .target(
        name: "YourHostApp",
        dependencies: [
            .product(name: "LiveAudioServerCore", package: "LiveAudioServer"),
        ]
    ),
]
```

Then build a config, install a logger (or skip — the library defaults to
silent), and drive the lifecycle from Swift Concurrency:

```swift
import LiveAudioServerCore

// Optional: see library log lines. Default is a SilentLogger so library
// consumers never get unexpected stderr output.
LiveAudioServerLogging.logger = StderrLogger()  // or your own LiveAudioServerLogger

var cfg = LiveAudioServerConfig()    // = ServerConfig — CLI-default values
cfg.port           = 9000
cfg.bindHost       = "127.0.0.1"
cfg.inputSource    = .udp(port: 7355)   // Gqrx UDP, for example
cfg.fillerMode     = .tone
cfg.bonjourName    = "My Radio"
// …override any other fields here

let server = LiveAudioServer(config: cfg)
try await server.start()
// /stream.mp3, /stream.m4a, /hls/index.m3u8, and / are live until stop()
// returns. start() throws LiveAudioServerError on synchronous setup failures
// (bind, TLS load, encoder init).

// Later, when the user toggles the off switch:
await server.stop()
```

The same package vends both products, so depending on the library does not
pull in or build the executable.

Notes for integrators:

- Multiple `LiveAudioServer` instances can coexist in one process, but they
  share one global logger sink (`LiveAudioServerLogging.logger`).
- `signal(SIGPIPE, SIG_IGN)` is set inside `start()` so a client disconnect
  won't kill the host process.
- Encoder lifecycle: do not call `start()` then `stop()` without the server
  having processed at least some PCM. `lame_encode_flush` asserts internally
  when the session received no audio. In practice this only matters for
  unit tests; live PCM always produces frames before shutdown.
- `LiveAudioServerCore` is `import`able from any module that depends on the
  library product. `import LiveAudioServer` (the executable target) is not
  meant for external consumption.

---

## Build from source

### Requirements

- macOS 13 (Ventura) or later
- Xcode 15.4+ / Swift 5.10+ (uses the [Swift Testing](https://github.com/apple/swift-testing) framework for unit tests)

No external package manager required. `libmp3lame` ships pre-built as a
universal (arm64 + x86_64) static XCFramework at
[`Frameworks/Mp3Lame.xcframework`](Frameworks/Mp3Lame.xcframework) and is
consumed by SwiftPM as a binary target.

```bash
cd LiveAudioServer
swift build -c release
```

The binary will be at `.build/release/LiveAudioServer`.

### Rebuilding the vendored libmp3lame (maintainers)

`Frameworks/Mp3Lame.xcframework` is checked into the repo and is the only
form of libmp3lame the project consumes. If you need to bump the LAME version
or reproduce the framework from source, run:

```bash
./scripts/build-mp3lame-xcframework.sh
```

The script downloads LAME 3.100, builds arm64 and x86_64 static slices,
`lipo`s them into a universal `libmp3lame.a`, and packages the result as
`Frameworks/Mp3Lame.xcframework` via `xcodebuild -create-xcframework`. Only
re-run when changing the LAME version — day-to-day development does not need
to touch it.

Optionally install system-wide:

```bash
cp .build/release/LiveAudioServer /usr/local/bin/
```

### Install via Homebrew tap

A Homebrew formula lives at [`Formula/liveaudioserver.rb`](Formula/liveaudioserver.rb).
Once a tap repository is published (see "Publishing a tap" below), users can
install with:

```bash
brew install dsward2/tap/liveaudioserver
```

`--HEAD` is also supported (builds from `main` instead of the released tag):

```bash
brew install --HEAD dsward2/tap/liveaudioserver
```

#### Publishing a tap

The formula in this repo is the canonical source. To make `brew install
dsward2/tap/liveaudioserver` work for users, you need a *tap repository*:

1. Create a public GitHub repo named `homebrew-tap` under your account
   (`github.com/dsward2/homebrew-tap`). The `homebrew-` prefix is required.
2. Copy `Formula/liveaudioserver.rb` from this repo into
   `Formula/liveaudioserver.rb` in the tap repo.
3. Tag a release here: `git tag v0.1.0 && git push --tags`.
4. Compute the release tarball's SHA256:
   ```bash
   curl -sL https://github.com/dsward2/LiveAudioServer/archive/refs/tags/v0.1.0.tar.gz \
     | shasum -a 256
   ```
5. Update `url` and `sha256` in the tap repo's copy of the formula. Push.
6. Users can now `brew install dsward2/tap/liveaudioserver`.

Subsequent releases: bump the tag, recompute SHA256, update the tap formula.

### Cutting a signed, notarized release

[`scripts/release.sh`](scripts/release.sh) builds a universal binary, signs
it with a Developer ID, submits it to Apple's notary service, staples the
ticket, and packages the result as a zip ready to upload to a GitHub
release. The zip contains the binary, the double-click launcher, the
license, and the third-party license disclosure.

One-time setup on your release machine:

```bash
# Store notarization credentials in the keychain (uses an app-specific
# password generated at https://appleid.apple.com).
xcrun notarytool store-credentials LiveAudioServer-notary \
    --apple-id you@example.com \
    --team-id  TEAMIDXXXX \
    --password APP-SPECIFIC-PASSWORD
```

Per-release:

```bash
export DEVELOPER_ID='Developer ID Application: Douglas Ward (XXXXXXXXXX)'
export NOTARY_PROFILE='LiveAudioServer-notary'
./scripts/release.sh
```

Output is written to
`build/release/LiveAudioServer-vX.Y.Z-macos-universal.zip` along with its
SHA256.

### Tests

```bash
swift test
```

The unit tests use [Swift Testing](https://github.com/apple/swift-testing) and
cover ADTS frame headers, HLS playlist generation, CLI parsing, the
now-playing store, and PCM input source formatting.

---

## Usage

```
LiveAudioServer [options]

Options:
  -p, --port <port>         HTTP port (default: 8080)
  -r, --rate <hz>           Input sample rate in Hz (default: 48000)
  -c, --channels <n>        Input channels: 1=mono, 2=stereo (default: 2)
  --mp3-bitrate <kbps>      MP3 output bitrate in kbps (default: 128)
  --aac-bitrate <kbps>      AAC output bitrate in kbps (default: 128)
  --mp3-mount <path>        HTTP mount point for MP3 (default: /stream.mp3)
  --m4a-mount <path>        HTTP mount point for M4A/AAC (default: /stream.m4a)
  --hls-mount <path>        HTTP mount point for HLS playlist (default: /hls/index.m3u8)
  --chunk-frames <n>        PCM frames per stdin read (default: 4096)
  --udp-input-port <port>   Receive PCM from UDP on the given port instead of stdin
  --tcp-input-port <port>   Receive PCM from TCP on the given port instead of stdin
  --outputs <list>          Comma-separated streaming outputs to enable from:
                            mp3, aac, hls (default: mp3,aac,hls). Encoders for
                            disabled outputs are skipped to save CPU.
  --tls-port <port>         If set, also listen for HTTPS on this port (in
                            addition to plain HTTP on --port). Requires
                            --tls-identity.
  --tls-identity <path>     Path to a PKCS#12 (.p12) file containing the TLS
                            certificate and private key.
  --tls-password <value>    Passphrase for --tls-identity. Note: mkcert -pkcs12
                            uses the password "changeit" by default.
  --tls-password-env <var>  Read the --tls-identity passphrase from the named
                            environment variable instead of the command line.
  --bind <host>             Restrict HTTP/HTTPS listeners to this address
                            (default: all interfaces). Use 127.0.0.1 for
                            IPv4 localhost only, ::1 for IPv6 localhost
                            only, or an explicit LAN address.
  --allow-ip <list>         Allow HTTP/HTTPS connections only from these
                            source IPs. Comma-separated list of single IPs
                            or CIDR ranges, e.g.
                            "127.0.0.1,192.168.0.0/24,::1". Default: allow
                            everyone (filtering is applied AFTER --bind).
  --bonjour <name>          Advertise HTTP/HTTPS listeners on the LAN via
                            Bonjour (mDNS) under this name, e.g.
                            "Studio Audio". Default: disabled.
  --bonjour-inputs          Also advertise the active UDP / TCP input port
                            via Bonjour (custom service type
                            _liveaudio-pcm). Requires --bonjour.
  --stats-interval <secs>   Emit a one-line stats summary to stderr every
                            <secs> seconds (default: 0 = disabled). A good
                            starting value is 60 for long-running sessions.
  --record-mp3 <path>       Also append the encoded MP3 stream to this file
                            while streaming. Requires mp3 in --outputs.
  --record-aac <path>       Also append the encoded ADTS AAC stream to this
                            file while streaming. Requires aac in --outputs.
  --auth-user <name>        Require HTTP Basic authentication on every
                            request. Must be paired with --auth-password
                            (or --auth-password-env). Credentials are
                            base64-encoded on the wire — pair with
                            --tls-port for non-localhost use.
  --auth-password <value>   Password for --auth-user.
  --auth-password-env <var> Read the auth password from the named env var
                            instead of the command line.
  --auth-realm <name>       Realm name shown in the browser login dialog
                            (default: "LiveAudioServer").
  --config <path>           Read defaults from a JSON config file. Any CLI
                            flag passed alongside it overrides the file's
                            value. See "Configuration file" below.
  --keep-alive              Keep HTTP outputs available after stdin reaches EOF.
                            If stdin is a FIFO (mkfifo), the reader also
                            re-opens it on EOF so a new producer can attach;
                            gaps between producers are filled with silence so
                            encoders / HLS stay live.
  --no-fifo-reopen          Disable the FIFO re-open behaviour above; the
                            reader will silence-fill after EOF instead.
  --silence-dither          Inject inaudible TPDF dither (±1 LSB) once a run
                            of digitally-silent samples crosses
                            --silence-dither-ms. Applies to stdin, UDP, and
                            TCP input alike. Prevents downstream tools from
                            treating the stream as dead.
  --silence-dither-ms <n>   Milliseconds of pure-silence before dither kicks
                            in (default: 500).
  --filler-mode <mode>      What to broadcast during the keep-alive
                            silence-fill window after stdin EOF.
                            "silence" (default) emits digital zero
                            (optionally TPDF-dithered via --silence-dither).
                            "tone" emits a continuous sine wave at
                            --filler-tone-hz so listeners hear an audible
                            "dead-air" placeholder. Only effective with
                            --keep-alive.
  --filler-tone-hz <hz>     Frequency of the sine-tone filler in Hz
                            (default: 1000). Ignored unless --filler-mode tone.
  --filler-after-ms <n>     Milliseconds of consecutive UDP/TCP input absence
                            before the filler kicks in (default: 500). Brief
                            network jitter passes through unaltered; longer
                            gaps switch to filler.
  -V, --verbose             Verbose logging
  -v, --version             Print version string and exit
  -h, --help                Show this help
```

---

## Examples

### Test with a file (no hardware needed)

```bash
# Pipe a WAV/FLAC/MP3 file through ffmpeg and into the server. The
# -stream_loop -1 flag loops the file indefinitely, so the stream
# keeps running for as long as the server is up.
ffmpeg -stream_loop -1 -i input.wav -f s16le -ar 44100 -ac 2 - \
  | .build/release/LiveAudioServer
```

Then open `http://localhost:8080/` in a browser to listen.

### Microphone (macOS built-in or external)

```bash
# List available devices
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "AVFoundation audio"

# Capture from device index 0 (usually built-in mic)
ffmpeg -f avfoundation -i ":0" \
       -f s16le -ar 44100 -ac 1 - \
  | .build/release/LiveAudioServer --channels 1
```

### System audio via BlackHole

```bash
# Install: brew install blackhole-2ch  (or download from Existential Audio)
ffmpeg -f avfoundation -i "BlackHole 2ch" \
       -f s16le -ar 48000 -ac 2 - \
  | .build/release/LiveAudioServer --rate 48000
```

### System audio via VB-CABLE

```bash
# Install: download the macOS package from https://vb-audio.com/Cable/
# (no Homebrew formula). The capture endpoint shows up in ffmpeg's
# avfoundation device list as "VB-Cable".
ffmpeg -f avfoundation -i "VB-Cable" \
       -f s16le -ar 48000 -ac 2 - \
  | .build/release/LiveAudioServer --rate 48000
```

### Gqrx UDP audio feed

**Configure Gqrx first.** In Gqrx, click the **UDP** button in the *Audio*
section. In *Audio Options → Network*, set **UDP host** to `localhost`,
**UDP port** to `7355`, and tick the **Stereo** checkbox. (Gqrx will start
streaming as soon as LiveAudioServer is listening on that port.)

Then start LiveAudioServer:

```bash
# Gqrx sends 48 kHz 16-bit stereo PCM to UDP port 7355 by default — read it
# directly without any external resampler. Basic-auth gates the HTTP routes,
# --silence-dither keeps downstream tools alive between transmissions, and
# --keep-alive holds the stream open across gaps in the upstream feed.
.build/release/LiveAudioServer \
    --udp-input-port 7355 \
    --auth-user alice \
    --auth-password s3cret \
    --silence-dither \
    --keep-alive
```

A few notes about this example:

- **Don't put the password on the command line in production** — it shows up
  in `ps` output and shell history. Use `--auth-password-env` instead:
  ```bash
  export LIVEAUDIO_AUTH_PW=s3cret
  .build/release/LiveAudioServer --udp-input-port 7355 \
      --auth-user alice --auth-password-env LIVEAUDIO_AUTH_PW \
      --silence-dither --keep-alive
  ```
- Basic auth gates **every** HTTP route, including the status page at `/`.
  The first time you open `http://<mac>.local:8080/` on iPhone Safari you'll
  see a credential dialog — enter `alice` / `s3cret` (Safari can remember
  them in the keychain).
- For anything beyond loopback, pair Basic auth with `--tls-port` so
  credentials don't ride in plaintext on the LAN (see "Native HTTPS" below).

### RTL-SDR via `rtl_fm` (mono)

```bash
# rtl_fm commonly emits mono 16-bit PCM to stdout, so LiveAudioServer must use --channels 1.
rtl_fm -f 162.55M -M fm -s 48k -r 48k -E deemp \
  | .build/release/LiveAudioServer --rate 48000 --channels 1
```

### High-quality radio stream

```bash
ffmpeg -i input.flac -f s16le -ar 44100 -ac 2 - \
  | .build/release/LiveAudioServer \
      --port 8080 \
      --mp3-bitrate 320 \
      --aac-bitrate 256
```

### 48 kHz mono podcast feed

```bash
ffmpeg -f avfoundation -i ":1" \
       -f s16le -ar 48000 -ac 1 - \
  | .build/release/LiveAudioServer \
      --rate 48000 \
      --channels 1 \
      --mp3-bitrate 96 \
      --aac-bitrate 96 \
      -p 9000
```

---

## Listening to the Stream

### Browser

Open `http://localhost:8080/` — the built-in status page has embedded `<audio>` players for both streams.

### VLC

```bash
vlc http://localhost:8080/stream.mp3
vlc http://localhost:8080/stream.m4a
```

### ffplay

```bash
ffplay http://localhost:8080/stream.mp3
ffplay http://localhost:8080/stream.m4a
```

### mpv

```bash
mpv http://localhost:8080/stream.mp3
```

### Re-encode the stream (recording)

```bash
ffmpeg -i http://localhost:8080/stream.mp3 -c copy recording.mp3
```

---

## HTTP Endpoints

| Path | Method | Description |
|---|---|---|
| `/` | GET | Status page with embedded players; polls `/status.json` every 5s to refresh listener counts and now-playing in place |
| `/status.json` | GET | JSON document with current listener counts and now-playing record (`{"mp3Clients":N,"m4aClients":N,"nowPlaying":{...}}`) |
| `/api/now-playing` | GET | Returns the current now-playing record as JSON |
| `/api/now-playing` | POST | Replaces the now-playing record with the JSON body (see below) |
| `/api/recorder` | GET | Returns recorder status for each enabled format as JSON |
| `/api/recorder/{mp3\|aac}/start` | POST | Begins recording to `path` from JSON body |
| `/api/recorder/{mp3\|aac}/pause` | POST | Pauses recording (file stays open) |
| `/api/recorder/{mp3\|aac}/resume` | POST | Resumes a paused recording |
| `/api/recorder/{mp3\|aac}/stop` | POST | Stops recording and closes the file |
| `/stream.mp3` | GET | Continuous MP3 bitstream (Icecast-compatible) |
| `/stream.m4a` | GET | Continuous ADTS-framed AAC bitstream (`audio/aac`) |
| `/hls/index.m3u8` | GET | Live HLS playlist backed by AAC segments |

Routes for disabled outputs return `404` (see `--outputs`).

### Now-playing metadata

An external process can publish "now playing" metadata that the status page
displays. Posting any combination of fields replaces the current record; the
server adds a server-side `updated` timestamp. Empty strings clear the field.
Post `{}` to clear all fields.

```bash
curl -X POST http://localhost:8080/api/now-playing \
     -H "Content-Type: application/json" \
     -d '{"title":"Symphony No. 9","artist":"Beethoven","station":"WCRB","note":"Live from Symphony Hall"}'
```

Response:
```json
{"title":"Symphony No. 9","artist":"Beethoven","station":"WCRB","note":"Live from Symphony Hall","updated":"2026-05-19T18:00:00Z"}
```

The status page polls `/status.json` every 5 seconds and shows a "Now Playing"
card whenever any field is non-empty.

**Security**: this endpoint inherits the same protection as every other
route. If LiveAudioServer is started with `--auth-user`/`--auth-password`,
callers must present HTTP Basic credentials (see "HTTP Basic authentication"
below); otherwise it's open. The recommended deployment is `--bind 127.0.0.1`
(or a LAN address behind your firewall) so only trusted local processes can
reach the endpoint.

### Recorder control

Each enabled output format (`mp3`, `aac`) has a state-machine recorder
controllable at runtime. States are `idle`, `recording`, and `paused`.

```bash
# Status of all enabled recorders
curl http://localhost:8080/api/recorder

# Start recording the MP3 stream to a file
curl -X POST http://localhost:8080/api/recorder/mp3/start \
     -H "Content-Type: application/json" \
     -d '{"path":"/tmp/show.mp3"}'

# Pause / resume mid-show
curl -X POST http://localhost:8080/api/recorder/mp3/pause
curl -X POST http://localhost:8080/api/recorder/mp3/resume

# Rotate to a new file (closes the previous one)
curl -X POST http://localhost:8080/api/recorder/mp3/start \
     -H "Content-Type: application/json" \
     -d '{"path":"/tmp/show-2.mp3"}'

# Stop recording and close the file
curl -X POST http://localhost:8080/api/recorder/mp3/stop
```

Every POST returns the current recorder envelope (same shape as the GET).
Status shape:

```json
{"mp3":{"format":"mp3","state":"recording","path":"/tmp/show.mp3","bytesWritten":4096},
 "aac":{"format":"m4a","state":"idle","bytesWritten":0}}
```

Calling `/api/recorder/{format}/start` while already recording rotates to the
new path (previous file is closed). The recorder for a format is only
available if that format is in `--outputs`; otherwise the route returns `409`.

**Security**: same protection as every other route — gate the whole server
with `--auth-user`/`--auth-password` and/or restrict the listening interface
with `--bind 127.0.0.1`.

---

## Using Caddy in front (optional)

The built-in `--tls-port` listener (next section) handles most HTTPS needs. A
reverse proxy like [Caddy](https://caddyserver.com) is still the right tool
for two cases:

- **Publicly-trusted certificates**: Caddy automates Let's Encrypt for
  internet-exposed deployments (requires a public DNS name on the host).
- **HSTS and HTTP→HTTPS redirects**: Caddy emits both by default; the native
  TLS listener does not.

Minimal Caddyfile that proxies the streams without buffering them:

```caddy
example.com {
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1   # essential - keeps live MP3/AAC chunks streaming
    }
}
```

Then `caddy run --config /path/to/Caddyfile`.

---

## Native HTTPS (no proxy)

LiveAudioServer can also terminate TLS itself via macOS's Network.framework, so
the binary serves both `http://` and `https://` without a sidecar process.

### Generate a PKCS#12 with mkcert

```bash
mkdir -p ~/.config/liveaudioserver && cd ~/.config/liveaudioserver
mkcert -pkcs12 localhost 127.0.0.1 ::1
# produces:  localhost+2.p12
```

`mkcert -pkcs12` sets the passphrase to **`changeit`** (industry-standard
placeholder). You'll need to pass it via `--tls-password` or
`--tls-password-env`.

(If you haven't already run `mkcert -install` for your machine, do that first —
see the Caddy section above for details.)

### Run with TLS

```bash
.build/release/LiveAudioServer \
    --udp-input-port 7355 \
    --tls-port 8443 \
    --tls-identity ~/.config/liveaudioserver/localhost+2.p12 \
    --tls-password changeit
```

Plain HTTP stays on `--port` (default 8080); HTTPS is added on `--tls-port`.
Both serve the same status page, JSON polling endpoint, and streams.

Alternative — read the passphrase from the environment so it doesn't appear in
`ps`/argv:

```bash
export LIVEAUDIO_TLS_PW=changeit
.build/release/LiveAudioServer \
    --udp-input-port 7355 \
    --tls-port 8443 \
    --tls-identity ~/.config/liveaudioserver/localhost+2.p12 \
    --tls-password-env LIVEAUDIO_TLS_PW
```

### Notes

- **TLS minimum**: enforced at TLS 1.2.
- **Cert renewal**: replace the `.p12` and restart LiveAudioServer. No hot reload.
- **Listener semantics**: both listeners share the same request handler, so all
  routes (`/`, `/status.json`, `/stream.mp3`, `/stream.m4a`, `/hls/index.m3u8`,
  HLS segments) are reachable on both schemes.
- **HSTS / HTTP→HTTPS redirect**: not emitted. If you want those, use the Caddy
  reverse-proxy setup above instead.

---

## Network access control

Two complementary mechanisms keep the streams from being trivially reachable
by anything that happens to share the network:

1. **`--bind <host>`** controls the kernel-level *listening interface*.
   Binding to `127.0.0.1` means the OS refuses any packet not from loopback;
   nothing on the LAN can connect at all.

2. **`--allow-ip <list>`** is a post-accept source-IP filter applied to
   HTTP/HTTPS connections. Comma-separated list of single IPs and/or CIDR
   ranges (IPv4 or IPv6). A connection whose source address doesn't match any
   entry is cancelled before the request is read.

Typical recipes:

```bash
# Loopback only — same machine, both IPv4 and IPv6.
LiveAudioServer --bind 127.0.0.1
LiveAudioServer --bind ::1

# Listen on all interfaces, but only let your home LAN connect.
LiveAudioServer --allow-ip 192.168.1.0/24,127.0.0.1,::1

# Multiple subnets (IPv4 + IPv6).
LiveAudioServer --allow-ip 10.0.0.0/8,fd00::/8,127.0.0.1,::1

# Combine — bind to a specific LAN IP and further restrict the source.
LiveAudioServer --bind 192.168.1.5 --allow-ip 192.168.1.0/24
```

Notes:

- The PCM input sources (`--udp-input-port`, `--tcp-input-port`) are *not*
  filtered by `--allow-ip`; that flag governs HTTP/HTTPS only. If you want to
  lock those down, put them behind a firewall or use `--bind`-equivalent host
  selection at the network layer.
- `--allow-ip` matches the connecting client's address — IPv4-mapped IPv6
  addresses (`::ffff:a.b.c.d`) are normalized to their underlying IPv4 form
  before comparison, so an IPv4 entry like `127.0.0.1` matches both true IPv4
  connections and v4-mapped ones from a dual-stack socket.
- Rejected connections are logged when running with `-V` (verbose).

---

## HTTP Basic authentication

A realm-style login gate can be enabled on every HTTP/HTTPS route — streams,
status page, JSON polling, recorder API, and the now-playing endpoint all
share one realm. Browsers pop a credential dialog; CLI clients send
`Authorization: Basic <base64>`.

```bash
# Require credentials on every request.
.build/release/LiveAudioServer --auth-user alice --auth-password s3cret

# Read the password from an env var so it doesn't appear in `ps`/argv.
export LIVEAUDIO_AUTH_PW=s3cret
.build/release/LiveAudioServer --auth-user alice --auth-password-env LIVEAUDIO_AUTH_PW

# Custom realm name (default: "LiveAudioServer").
.build/release/LiveAudioServer --auth-user alice --auth-password s3cret \
                               --auth-realm "Studio"
```

Test it from the command line:

```bash
curl -i http://localhost:8080/                # → 401 Unauthorized + WWW-Authenticate
curl -i -u alice:s3cret http://localhost:8080/ # → 200 OK
```

Notes:

- **Pair with TLS.** HTTP Basic credentials travel base64-encoded, not
  encrypted. For anything beyond loopback, also enable `--tls-port` so the
  Authorization header rides inside TLS. Startup logs a ⚠ warning when auth
  is configured without TLS.
- **All routes, one credential.** There is no "anonymous streams +
  authenticated admin" mode — auth either applies to everything or to
  nothing.
- **Constant-time comparison** is used on the username and password so an
  attacker can't time-attack the credentials.
- **Config-file equivalents**: `authUser`, `authPassword`, `authRealm`.

---

## Bonjour discovery

LiveAudioServer can publish its outputs (and optionally its inputs) over
Bonjour / DNS-SD so other devices on the LAN can find them by name instead of
IP address.

```bash
# Advertise HTTP (and HTTPS, if --tls-port is set) on the LAN.
LiveAudioServer --bonjour "Studio Audio"

# Also advertise the configured UDP/TCP input port so producers can find it.
LiveAudioServer --udp-input-port 7355 --bonjour "Studio Audio" --bonjour-inputs
```

Published service types:

| Service type             | What it represents                                                    |
|--------------------------|------------------------------------------------------------------------|
| `_http._tcp.`            | The plain-HTTP listener on `--port`                                    |
| `_https._tcp.`           | The TLS listener on `--tls-port` (if enabled)                          |
| `_liveaudio._tcp.`       | Custom output service on the HTTP port with rich TXT metadata          |
| `_liveaudio-pcm._tcp.`   | The TCP PCM input port (with `--bonjour-inputs`)                       |
| `_liveaudio-pcm._udp.`   | The UDP PCM input port (with `--bonjour-inputs`)                       |

The `_http._tcp.` service carries a TXT record advertising the active stream
paths and version. `path=/` is the conventional Safari Bonjour-bookmark key;
`status=/` is the same path under an explicit name for non-Safari clients:

```
ver=0.1.3
path=/
status=/
mp3=/stream.mp3
aac=/stream.m4a
hls=/hls/index.m3u8
```

The `_liveaudio._tcp.` custom service carries everything above *plus* config
details, so a LiveAudioServer-aware client can enumerate all streams in a
single Bonjour lookup without hitting `/status.json`:

```
ver=0.1.3
path=/
status=/
rate=48000
channels=2
mp3=/stream.mp3
mp3-bitrate=128
aac=/stream.m4a
aac-bitrate=128
hls=/hls/index.m3u8
tls-port=8443
```

You can browse from the command line:

```bash
dns-sd -B _http._tcp local.            # list all HTTP services on the LAN
dns-sd -L "Studio Audio" _http._tcp local.   # resolve one to host/port + TXT
```

Safari (with Bonjour bookmarks enabled in Preferences → Advanced) will also
list the service.

**Note**: Bonjour multicast happens on the LAN interface(s) the kernel
considers reachable. Combining `--bonjour` with `--bind 127.0.0.1` will
register a service that only resolves to the loopback address, which other
devices on the LAN can't reach — pair Bonjour with a LAN-routable bind
address (or leave `--bind` at its default).

---

## Configuration file

Instead of (or in addition to) CLI flags, you can put settings in a JSON
config file and pass `--config <path>`. Every key is optional — only include
what you want to override. **Precedence**: built-in defaults < config file <
CLI flags.

Example `server.json`:

```json
{
  "port": 8080,
  "bind": "127.0.0.1",
  "rate": 48000,
  "channels": 2,
  "mp3Bitrate": 192,
  "aacBitrate": 192,
  "outputs": ["mp3", "aac", "hls"],
  "udpInputPort": 7355,
  "tlsPort": 8443,
  "tlsIdentity": "/Users/me/.config/liveaudioserver/localhost+2.p12",
  "tlsPassword": "changeit",
  "statsInterval": 60,
  "recordMP3": null,
  "recordAAC": null,
  "mountMP3": "/stream.mp3",
  "mountM4A": "/stream.m4a",
  "mountHLS": "/hls/index.m3u8",
  "chunkFrames": 4096,
  "keepAlive": false,
  "reopenFIFO": true,
  "silenceDither": false,
  "silenceDitherMs": 500,
  "fillerMode": "silence",
  "fillerToneHz": 1000,
  "fillerAfterMs": 500,
  "verbose": false,
  "authUser": "alice",
  "authPassword": "s3cret",
  "authRealm": "LiveAudioServer"
}
```

```bash
# Use the file as the base; CLI flags override
.build/release/LiveAudioServer --config server.json
.build/release/LiveAudioServer --config server.json --port 9000
```

Notes:

- `mp3Bitrate` / `aacBitrate` are in **kbps** (matching the CLI flags).
- `outputs` is an array of any subset of `"mp3"`, `"aac"`, `"hls"`.
- `udpInputPort` and `tcpInputPort` set the input source (last one wins if
  both appear). Omitting both keeps the default `stdin` input.
- Unknown keys are silently ignored; an unknown `outputs` token (e.g.
  `"opus"`) is rejected at startup.

---

## PCM Input Format

The server reads raw **little-endian signed 16-bit PCM** from stdin, UDP, or TCP:

- **Encoding**: `s16le` (signed 16-bit little-endian integers)
- **Layout**: Interleaved samples (for stereo: L₀ R₀ L₁ R₁ …)
- **Channels**: 1 (mono) or 2 (stereo) — set with `--channels`
- **Sample rate**: Any standard rate — set with `--rate`

This is what `ffmpeg -f s16le` produces, which is the standard raw PCM format.

### Stream robustness

Four options help the stream survive upstream hiccups:

- **`--keep-alive`** — after stdin EOF, hold the HTTP outputs open and feed
  the encoders silence (paced at sample-rate) so listeners aren't disconnected.
- **FIFO re-open** — if stdin is a named pipe (`mkfifo`), the reader
  re-`open()`s it on EOF so a new producer can attach mid-stream. Disable
  with `--no-fifo-reopen`. Anonymous shell pipes can't be reopened and will
  silence-fill instead.
- **`--silence-dither`** — when the *signal itself* is digitally silent
  (all-zero samples) for longer than `--silence-dither-ms` (default 500 ms),
  the broadcaster substitutes inaudible TPDF dither (±1 LSB, ≈-90 dBFS), so
  downstream tools that flag pure-silence don't treat the stream as dead.
  Applies equally to stdin, UDP, and TCP input.
- **`--filler-mode tone`** — replaces the silence emitted during input gaps
  with an audible sine wave at `--filler-tone-hz` (default 1000 Hz, -20 dBFS).
  Useful when listeners need a positive signal that the stream is up but the
  producer is between sources, rather than just hearing dead air. The phase
  accumulator carries across chunks so the tone has no audible clicks at
  chunk boundaries.

  Triggers in three scenarios:
  - **stdin EOF + `--keep-alive`** (legacy behavior).
  - **UDP input idle**: no packets for `--filler-after-ms` (default 500 ms).
  - **TCP input idle**: connected client stops sending for `--filler-after-ms`.

  ```bash
  # Gqrx → LiveAudioServer; if you mute Gqrx's UDP output, listeners hear a
  # 1 kHz tone after 500 ms instead of dead air, until Gqrx resumes.
  .build/release/LiveAudioServer \
      --udp-input-port 7355 \
      --filler-mode tone \
      --filler-tone-hz 1000 \
      --keep-alive
  ```

---

## Troubleshooting

### Browser plays MP3 but not M4A (or vice versa)

- Safari natively supports ADTS AAC (`audio/aac`)
- Chrome/Firefox support MP3 natively
- VLC supports both

### No audio / silent stream

Verify ffmpeg is sending PCM:

```bash
ffmpeg -i input.wav -f s16le -ar 44100 -ac 2 - | xxd | head
# You should see non-zero bytes
```

### High latency

Reduce `--chunk-frames`:

```bash
... | LiveAudioServer --chunk-frames 1024
```

Lower values reduce latency but increase CPU overhead. For broadcast use, 4096 is a reasonable default.

---

## File Structure

```
LiveAudioServer/
├── Package.swift                         # SPM manifest
├── Frameworks/
│   └── Mp3Lame.xcframework               # Vendored universal libmp3lame static lib
├── scripts/
│   ├── build-mp3lame-xcframework.sh      # Rebuilds Mp3Lame.xcframework from source
│   ├── release.sh                        # Universal build + sign + notarize + zip
│   └── templates/
│       └── Start LiveAudioServer.command # Double-click launcher bundled in release zips
├── THIRD-PARTY-LICENSES.md               # LGPL compliance for bundled libmp3lame
├── Sources/
│   └── LiveAudioServer/
│       ├── main.swift                    # Entry point, arg parsing, pipeline wiring
│       ├── Config.swift                  # ServerConfig, shared types
│       ├── PCMSource.swift               # Stdin / UDP / TCP PCM reader + broadcaster
│       ├── MP3Encoder.swift              # libmp3lame encoder
│       ├── AACEncoder.swift              # AudioToolbox AAC encoder + ADTS framing
│       ├── ChunkBroadcaster.swift        # Per-format encoded chunk fan-out
│       ├── HLSSegmenter.swift            # In-memory AAC HLS segmenter
│       └── HTTPServer.swift              # NWListener HTTP server + status page
└── README.md
```

---

## License

Apache-2.0. See the `LICENSE` file for the full license text.

This project was developed with assistance from AI coding tools, including Claude,
for code generation, debugging, and testing support.
