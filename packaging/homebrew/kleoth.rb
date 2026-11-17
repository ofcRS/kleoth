# Homebrew cask for Kleoth — local-first dictation, meeting notes and screen recording for macOS.
# `desc`, `version` and `sha256` are written by `bun marketing/sync.ts apply` (marketing/README.md).
#
# This is a DRAFT until the tap repo exists. Before publishing:
#   1. Once builds are notarized, delete the `caveats` block.
#
# Typical home: a tap repo named "homebrew-kleoth", installed via
#   brew install --cask ofcRS/kleoth/kleoth
cask "kleoth" do
  version "0.5.6"
  sha256 "e76de8a81a7b4959cf45dac25f6ec5a195562eaf16a125c0ebd5e09819c58ced"

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
