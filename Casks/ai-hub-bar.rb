cask "ai-hub-bar" do
  version "0.14.0"
  sha256 "b279f557f24605f2dd92f40d350cae5b886bad188df4247d2ce08a57aa6fd2c9"

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
