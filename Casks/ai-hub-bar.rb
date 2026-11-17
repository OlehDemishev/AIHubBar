cask "ai-hub-bar" do
  version "0.11.0"
  sha256 "0ae70d8ee30ea7fe89399b7b509e43a783a96935cae97f88c531526131e48cb8"

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
