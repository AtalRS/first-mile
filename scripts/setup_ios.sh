#!/bin/sh
# One-time: create the iOS app project in ios/ and wire in the native coach.
# Needs Node.js and Xcode. Afterwards use `npm run ios` to rebuild and open Xcode.
set -e
cd "$(dirname "$0")/.."
[ -d ios ] && { echo "ios/ already exists"; exit 1; }

npm install @capacitor/core @capacitor/ios
npm install -D @capacitor/cli
npm run build
npx cap add ios --packagemanager SPM

app=ios/App/App
# Native coach plugin and audio (see native/ios/AppDelegate.swift)
cp native/ios/AppDelegate.swift "$app/AppDelegate.swift"
sed -i '' 's/CAPBridgeViewController()/CoachBridgeViewController()/' "$app/SceneDelegate.swift"
grep -q CoachBridgeViewController "$app/SceneDelegate.swift" || { echo "Could not set the view controller in SceneDelegate.swift"; exit 1; }
# Keep playing coach audio with the screen locked
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" -c "Add :UIBackgroundModes:0 string audio" "$app/Info.plist"
# App icon
cp icons/app-store-icon-1024.png "$app/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png"

npx cap sync ios
echo "Done. Run: npm run ios"
