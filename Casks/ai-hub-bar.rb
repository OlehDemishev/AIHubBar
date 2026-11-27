cask "ai-hub-bar" do
  version "0.15.1"
  sha256 "ee7a0f8ce5051de836b656a40be255b6ffea2a0a3d8f986a742dd4ced09d4508"

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
