# MacPorts packaging

This directory holds the canonical [MacPorts](https://www.macports.org)
[Portfile](Portfile) for LiveAudioServer. The published port lives in
[`macports/macports-ports`](https://github.com/macports/macports-ports) at
`audio/liveaudioserver/Portfile`; the copy here is the source of truth that
gets mirrored upstream at release time.

## Toolchain assumption

The build invokes `swift build`, which relies on Xcode or the Command Line
Tools being installed on the user's machine. The Swift toolchain itself is
not a MacPorts dependency, matching how other Swift CLI ports (e.g.
`swiftlint`, `swiftformat`) ship today.

## Cutting a new release

1. Tag the upstream release on GitHub:
   ```bash
   git tag v0.2.0 && git push --tags
   ```
2. Bump the version in [Portfile](Portfile) (`github.setup` line — the third
   field).
3. Recompute the distfile checksums against the new tarball. Easiest path is
   to let MacPorts do it:
   ```bash
   sudo /opt/local/bin/port clean liveaudioserver
   sudo /opt/local/bin/port -v checksum liveaudioserver
   ```
   Or hash the tarball directly:
   ```bash
   url="https://github.com/dsward2/LiveAudioServer/archive/refs/tags/v0.2.0.tar.gz"
   curl -sLo /tmp/las.tgz "$url"
   echo "size:   $(wc -c < /tmp/las.tgz | tr -d ' ')"
   echo "sha256: $(shasum -a 256 /tmp/las.tgz | awk '{print $1}')"
   echo "rmd160: $(openssl dgst -rmd160 /tmp/las.tgz | awk '{print $NF}')"
   ```
4. Paste the three values into [Portfile](Portfile) replacing the previous
   release's checksums.
5. Verify the port still builds end-to-end:
   ```bash
   sudo /opt/local/bin/port -v install liveaudioserver
   /opt/local/bin/liveaudioserver --version
   sudo /opt/local/bin/port lint --nitpick liveaudioserver
   ```

## Local-test setup (one-time)

To make `port` recognize this Portfile by name, register a local ports tree
with MacPorts. The setup is described in detail in the project root README;
the short version:

```bash
mkdir -p ~/macports-local/audio/liveaudioserver
ln -sf "$PWD/Portfile" ~/macports-local/audio/liveaudioserver/Portfile

# Add `file:///Users/<you>/macports-local` above the rsync line in
# /opt/local/etc/macports/sources.conf, then:
cd ~/macports-local && /opt/local/bin/portindex
```

The symlink means edits in this directory flow into the local ports tree
automatically — no re-copy needed when iterating.

## Submitting / updating the upstream port

The upstream copy at `macports/macports-ports` is a plain file, not a
symlink. After updating [Portfile](Portfile) here:

```bash
cd ~/macports-ports        # your fork of macports/macports-ports
git checkout -b liveaudioserver-0.2.0
cp /path/to/LiveAudioServer/MacPorts/Portfile \
   audio/liveaudioserver/Portfile
git add audio/liveaudioserver/Portfile
git commit -m "liveaudioserver: update to 0.2.0"
git push origin liveaudioserver-0.2.0
gh pr create --repo macports/macports-ports \
    --base master \
    --title "liveaudioserver: update to 0.2.0"
```

The macports-ports CI will re-run `port lint` and a sandboxed build on the PR.
