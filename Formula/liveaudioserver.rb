# LiveAudioServer — https://github.com/dsward2/LiveAudioServer
#
# Homebrew formula. Copy this file to your tap repository
# (e.g. github.com/dsward2/homebrew-tap/Formula/liveaudioserver.rb) and
# users can then install via:
#
#     brew install dsward2/tap/liveaudioserver
#
# At release time:
#   1. Tag the source: `git tag v0.1.0 && git push --tags`
#   2. GitHub auto-creates a tarball at the URL below.
#   3. Compute the SHA256 with:
#        curl -sL https://github.com/dsward2/LiveAudioServer/archive/refs/tags/v0.1.0.tar.gz \
#          | shasum -a 256
#   4. Update `url` and `sha256` in this file and push to the tap repo.

class Liveaudioserver < Formula
  desc "Live audio streaming server (MP3 + AAC + HLS) for macOS"
  homepage "https://github.com/dsward2/LiveAudioServer"
  url "https://github.com/dsward2/LiveAudioServer/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "fac97af57874d12984d3d428f85429f49d04f213aaa410ef0e05c9c9cec01e29"
  license "Apache-2.0"
  head "https://github.com/dsward2/LiveAudioServer.git", branch: "main"

  depends_on macos: :ventura

  def install
    # --disable-sandbox is required for SwiftPM under Homebrew, which
    # otherwise can't fetch its own toolchain cache.
    #
    # libmp3lame is vendored as Frameworks/Mp3Lame.xcframework and consumed
    # by SwiftPM as a binary target — no external `lame` dependency needed.
    system "swift", "build",
                    "--configuration", "release",
                    "--disable-sandbox"
    bin.install ".build/release/LiveAudioServer" => "liveaudioserver"
  end

  test do
    # `--version` is a self-contained command — no streaming, no ports.
    assert_match "LiveAudioServer", shell_output("#{bin}/liveaudioserver --version")
  end
end
