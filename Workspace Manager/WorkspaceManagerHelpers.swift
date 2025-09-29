import Foundation
import AppKit
import ApplicationServices

struct WorkspaceManager {
    // Presents a user-facing prompt to guide granting Accessibility permission
    @discardableResult
    static func promptForAccessibilityIfNeeded() -> Bool {
        // Fast path: already trusted
        if ensureAccessibilityTrusted(prompt: false) { return true }

        // Trigger the system prompt
        return ensureAccessibilityTrusted(prompt: true)
    }

    // Opens the System Settings (or System Preferences) to the Accessibility pane
    static func openAccessibilitySystemSettings() {
        // Deep link to Privacy > Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
            return
        }
        // Fallback: just open System Settings
        let fallback = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(fallback)
    }

    @discardableResult
    static func ensureAccessibilityTrusted(prompt: Bool = false) -> Bool {
        // Build options dict to optionally prompt the user
        let opts: [String: Any] = [
            (kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String): prompt
        ]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !trusted {
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This app"
            let appPath = Bundle.main.bundlePath
            print("Accessibility is not trusted for \(appName). AX calls will fail with kAXErrorAPIDisabled (-25211).")
            print("To fix: System Settings > Privacy & Security > Accessibility, enable: \(appName) (\(appPath)). Then relaunch the app.")
        }
        return trusted
    }

    static let saveDir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Workspaces")
        _ = try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    static func workspaceFile(named name: String) -> URL {
        return saveDir.appendingPathComponent("\(name).json")
    }
    
    // Get visible apps using AX API (no AppleScript)
    static func listRunningApps() -> [String] {
        guard promptForAccessibilityIfNeeded() else { return [] }
        var visibleApps: [String] = []

        let apps = NSWorkspace.shared.runningApplications

        for app in apps {
            // Skip background apps
            if app.activationPolicy != .regular { continue }

            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            var windows: AnyObject?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)

            switch result {
            case .success:
                if let windowArray = windows as? [AXUIElement], !windowArray.isEmpty {
                    visibleApps.append(app.localizedName ?? "Unknown")
                }
            case .apiDisabled:
                // Accessibility API disabled / not trusted for this process
                print("AX error: API disabled (-25211) while querying \(app.localizedName ?? "Unknown"). Ensure Accessibility is enabled for this app and relaunch.")
                return []
            default:
                // Ignore other AX errors for this app but continue scanning others
                break
            }
        }

        return visibleApps
    }
    
    static func saveWorkspace(name: String) {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> [String: String]? in
                guard let name = app.localizedName,
                      let bundleID = app.bundleIdentifier else { return nil }
                return ["name": name, "bundleID": bundleID]
            }

        let workspaceData: [String: Any] = [
            "name": name,
            "created": ISO8601DateFormatter().string(from: Date()),
            "apps": apps
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: workspaceData, options: .prettyPrinted)
            try data.write(to: workspaceFile(named: name))
            print("Workspace '\(name)' saved to \(workspaceFile(named: name).path)")
        } catch {
            print("Error saving workspace: \(error)")
        }
    }
    
    static func loadWorkspace(name: String) {
        let url = workspaceFile(named: name)
        guard let data = try? Data(contentsOf: url) else {
            print("Workspace '\(name)' not found")
            return
        }
        do {
            if let workspace = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let appURLStrings = workspace["appURLs"] as? [String] ?? []
                let bundleIDs = workspace["bundleIdentifiers"] as? [String] ?? []
                let appNames = workspace["apps"] as? [String] ?? []

                if !appURLStrings.isEmpty {
                    print("Restoring workspace '\(name)' using stored app URLs: \(appURLStrings.count) apps")
                    for urlString in appURLStrings {
                        if let appURL = URL(string: urlString) {
                            openApp(at: appURL)
                        } else {
                            print("Invalid app URL string: \(urlString)")
                        }
                    }
                } else if !bundleIDs.isEmpty {
                    print("Restoring workspace '\(name)' using bundle identifiers: \(bundleIDs)")
                    for bundleID in bundleIDs {
                        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            openApp(at: appURL)
                        } else {
                            print("Could not resolve URL for bundle identifier: \(bundleID)")
                        }
                    }
                } else if !appNames.isEmpty {
                    print("Restoring workspace '\(name)' with app names: \(appNames)")
                    for appName in appNames {
                        if let appURL = urlForApplication(named: appName) {
                            openApp(at: appURL)
                        } else {
                            print("Could not find application named: \(appName)")
                        }
                    }
                } else {
                    print("Workspace '\(name)' contained no applications to restore.")
                }
            }
        } catch {
            print("Error loading workspace: \(error)")
        }
    }
    
    static func openApp(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error {
                print("Failed to open application at \(url.path): \(error)")
            }
        }
    }

    static func urlForApplication(named name: String) -> URL? {
        // Try to resolve from currently running applications first
        if let match = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
           let url = match.bundleURL {
            return url
        }

        // Search common application directories for a matching .app bundle
        let fm = FileManager.default
        let candidateDirs: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        let appBundleName = "\(name).app"
        for dir in candidateDirs {
            let candidate = dir.appendingPathComponent(appBundleName)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
    
    static func listSavedWorkspaces() {
        let files = (try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            print("Saved: \(file.lastPathComponent)")
        }
    }
    
    static func restoreWorkspace(name: String) {
        let fileURL = workspaceFile(named: name)
        guard let data = try? Data(contentsOf: fileURL) else {
            print("Workspace '\(name)' not found")
            return
        }
        
        do {
            if let workspace = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let apps = workspace["apps"] as? [[String: String]] {
                
                for app in apps {
                    if let bundleID = app["bundleID"],
                       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        openApp(at: url)
                        print("Launched \(app["name"] ?? bundleID)")
                    } else {
                        print("Could not resolve app: \(app)")
                    }
                }
            }
        } catch {
            print("Error reading workspace JSON: \(error)")
        }
    }
}
