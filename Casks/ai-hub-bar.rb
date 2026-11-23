cask "ai-hub-bar" do
  version "0.12.0"
  sha256 "d567da79051f99658377bbffd367056375b141af3abee849576284d073cb3073"

  url "https://github.com/OlehDemishev/AIHubBar/releases/download/v#{version}/AIHubBar-#{version}.dmg"
  name "AI Hub Bar"
  desc "Menu bar panel for Claude Code limits, agent sessions and projects"
  homepage "https://github.com/OlehDemishev/AIHubBar"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "AI Hub Bar.app"

  zap trash: [
    "~/Library/Application Support/ClaudePult",
    "~/Library/Preferences/com.demishev.claudepult.plist",
  ]
end
