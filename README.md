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
- Saved workspaces are stored in `~/Workspaces/` as JSON files.
