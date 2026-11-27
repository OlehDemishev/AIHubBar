cask "ai-hub-bar" do
  version "0.15.0"
  sha256 "e1da9c77e1851d013af1a3d8608f415b7f43dd79dc77cf8f061a91adf4782399"

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
