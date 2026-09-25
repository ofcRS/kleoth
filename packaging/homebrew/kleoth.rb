# Homebrew cask for Kleoth — local-first dictation, meeting notes and screen recording for macOS.
# `desc`, `version` and `sha256` are written by `bun marketing/sync.ts apply` (marketing/README.md).
#
# This is a DRAFT until the tap repo exists. Before publishing:
#   1. Once builds are notarized, delete the `caveats` block.
#
# Typical home: a tap repo named "homebrew-kleoth", installed via
#   brew install --cask ofcRS/kleoth/kleoth
cask "kleoth" do
  version "0.4.0"
  sha256 "03313badda5b51e895f78f7c3d3f18c35f9f6a5f1bb120b5e6d9ff6d529d0cf6"

  url "https://github.com/ofcRS/kleoth/releases/download/v#{version}/Kleoth-#{version}.dmg",
      verified: "github.com/ofcRS/kleoth/"
  name "Kleoth"
  desc "Voice dictation, bot-free meeting notes and local screen recording"
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
    Kleoth isn't notarized yet, so macOS blocks its first launch. Allow it once:
    on macOS 15 or later, System Settings → Privacy & Security → Open Anyway;
    on macOS 14, right-click Kleoth.app in Applications and choose "Open".
    Or run:

      xattr -dr com.apple.quarantine "#{appdir}/Kleoth.app"
  EOS

  zap trash: [
    "~/Library/Preferences/dev.kleoth.app.plist",
    "~/Library/Caches/dev.kleoth.app",
  ]
  # Note: meeting data lives in ~/Kleoth and is intentionally NOT removed by zap.
end
