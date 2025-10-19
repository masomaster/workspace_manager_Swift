# Workspace Manager

Workspace Manager is a macOS utility that allows you to save and restore your workspace by managing running applications. It uses Accessibility APIs to detect visible apps and can launch saved sets of applications for quick workspace restoration.

## Features
- Save the current workspace with running applications.
- Restore saved workspaces by launching associated apps.
- Detect visible applications using Accessibility APIs.
- Handles accessibility permission prompts and guides users to enable necessary permissions.

## Installation
1. Clone the repository:

```bash
git clone https://github.com/masomaster/workspace_manager_Swift.git
```

2. Open the project in Xcode.  
3. Build and run the app.

## Usage
1. Use the menu bar app to save your current workspace.  
2. Restore a previously saved workspace from the menu.  
3. Optionally, list all saved workspaces.

## Accessibility Permissions

This app requires Accessibility permissions to access running applications and their windows. Upon first run:

1. macOS will prompt you to grant accessibility access.  
2. Go to System Settings > Privacy & Security > Accessibility.  
3. Enable the checkbox for this app.  
4. Relaunch the app to enable full functionality.

Without these permissions, the app cannot detect visible windows or manage workspaces effectively.

## Notes
- This app is designed for personal use and does not require distribution signing.  
- Saved workspaces are stored in `~/Library/Application Support/Workspace Manager/Workspaces/` as JSON files.

## Packaging & distribution

Follow these steps to build a production-ready .app in Xcode that you (or others) can run on a Mac.

1. Ensure your target is configured
	1. In Xcode, click the project file (blue icon) in the sidebar.
	2. Under Targets, select your app (likely “Workspace Manager” or similar).
	3. In the General tab, check:
		- Display Name — the name users see in Finder and the menu bar.
		- Bundle Identifier — e.g. `com.yourname.WorkspaceManager`.
		- Team — if you don't have a developer account, you may leave this as “None”.
		- Signing Certificate — select “Sign to Run Locally” for local testing.
		- Deployment Target — choose an appropriate macOS version (e.g., macOS 14).

2. Build the app

Option A: From Xcode (recommended for a packaged .app)
	1. Product → Archive
	2. After the build finishes, the Organizer window opens.
	3. Click Distribute App → Custom → Copy App.
	4. Choose a destination (for example `~/Applications` or the Desktop).
	5. You'll find `Workspace Manager.app` ready to use.

Option B: Manual / Debug build
	1. Product → Build
	2. Product → Show Build Folder in Finder
	3. Inside `Build/Products/Release` (or `Debug`) you'll find `Workspace Manager.app`.

3. (Optional) Sign and notarize

If you only plan to run the app on your own Mac, signing isn't required. For sharing with others, Gatekeeper will block unsigned apps unless users bypass it.

To ad-hoc sign locally (useful for colleagues or personal distribution):

```bash
codesign --deep --force --verify --verbose --sign - "Workspace Manager.app"
```

Full notarization requires an Apple Developer account and additional notarization steps.

4. Add to Login Items

To launch the app automatically at login:
	1. Open System Settings → General → Login Items
	2. Click ➕ and select your `Workspace Manager.app`.

5. (Optional) Bundle cleanup

For a final release:
	- In `Info.plist`, confirm the app runs as an agent (no Dock icon):

```xml
<key>LSUIElement</key>
<true/>
```

	- Remove any development logging you no longer need.
	- Test the app on a fresh macOS user account to verify Accessibility permission prompts and menu bar behavior.

Notes
- If you distribute the app to other users, document that they must grant Accessibility permission (System Settings → Privacy & Security → Accessibility) and then relaunch the app.
- To inspect saved workspaces locally:

```bash
ls -l "~/Library/Application Support/Workspace Manager/Workspaces/"
```

App icon (.icns)

This repository includes a `WorkspaceIcon.icns` file you can use as the app icon. Two ways to apply it:

Add the icon to a built .app manually
1. If you already have a compiled `.app`:
	1. Right-click the app → Show Package Contents.
	2. Open `Contents/Resources/`.
	3. Copy `WorkspaceIcon.icns` into that folder.
	4. Open `Contents/Info.plist` and add (or update) these entries:

```xml
<key>CFBundleIconFile</key>
<string>WorkspaceIcon</string>
```

Note: the `CFBundleIconFile` value may omit the `.icns` extension.

5. Save and close the plist, then refresh Finder / the system caches by touching the .app bundle:

```bash
touch "Workspace Manager.app"
```

Assign the icon in Xcode
1. In Xcode, open your target's Asset Catalog (or create one if missing).
2. Add the `WorkspaceIcon.icns` to the AppIcon set, or use the Icon File field in the target's General → App Icons and Launch Images section.
3. Rebuild the app.

If anything looks off after replacing icons, clean the build folder (Product → Clean Build Folder) and rebuild.
