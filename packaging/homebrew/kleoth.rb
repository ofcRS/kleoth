# Homebrew cask for Kleoth — local-first, bot-free macOS meeting recorder.
#
# This is a DRAFT until the tap repo exists. Before publishing:
#   1. Once builds are notarized, delete the `caveats` block.
#
# Typical home: a tap repo named "homebrew-kleoth", installed via
#   brew install --cask ofcRS/kleoth/kleoth
cask "kleoth" do
  version "0.1.0"
  sha256 "6028cafbbdddccadc337eb6e482b2c5ddfb0bfea9fc16c7ffed3304ceaa81641"

  url "https://github.com/ofcRS/kleoth/releases/download/v#{version}/Kleoth-#{version}.dmg",
      verified: "github.com/ofcRS/kleoth/"
  name "Kleoth"
  desc "Local-first, bot-free meeting recorder (on-device transcription + AI summaries)"
  homepage "https://github.com/ofcRS/kleoth"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma" # macOS 14.4+

  app "Kleoth.app"

  # Remove this block once notarized builds ship — until then macOS Gatekeeper
  # blocks the first launch because the app is self-signed (no Developer ID).
  caveats <<~EOS
    Kleoth is currently distributed as a self-signed (un-notarized) build.
    On first launch, macOS may say it is from an unidentified developer.
    Right-click Kleoth.app in Applications and choose "Open" (once), or run:

      xattr -dr com.apple.quarantine "#{appdir}/Kleoth.app"
  EOS

  zap trash: [
    "~/Library/Preferences/dev.kleoth.app.plist",
    "~/Library/Caches/dev.kleoth.app",
  ]
  # Note: meeting data lives in ~/Kleoth and is intentionally NOT removed by zap.
end
