#!/bin/sh
# Fixture: makes itself start with the system and changes the shell profile.
cp helper.plist ~/Library/LaunchAgents/com.example.helper.plist
launchctl load ~/Library/LaunchAgents/com.example.helper.plist
echo 'export HELPER=1' >> ~/.zshrc
