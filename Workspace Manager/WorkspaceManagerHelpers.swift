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
    
    // MARK: — Save workspace (apps + windows + app-specific state)
        static func saveWorkspace(name: String) {
            guard promptForAccessibilityIfNeeded() else { return }

            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app -> [String: Any]? in
                    guard let name = app.localizedName,
                          let bundleID = app.bundleIdentifier else { return nil }

                    var windowData: [[String: Any]] = []

                    // Collect window frames robustly for Finder and others
                    let pid = app.processIdentifier
                    let axApp = AXUIElementCreateApplication(pid)
                    var windowsObj: AnyObject?
                    let windowResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsObj)
                    if windowResult == .success, let axWindows = windowsObj as? [AXUIElement] {
                        for (i, axWindow) in axWindows.enumerated() {
                            // For Finder and others, wrap AX queries in checks, skip unreadable windows
                            var posRef: CFTypeRef?
                            var sizeRef: CFTypeRef?
                            let posRes = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                            let sizeRes = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                            if posRes == .success, sizeRes == .success,
                               let posCF = posRef, let sizeCF = sizeRef,
                               CFGetTypeID(posCF) == AXValueGetTypeID(),
                               CFGetTypeID(sizeCF) == AXValueGetTypeID() {
                                var pos = CGPoint.zero
                                var size = CGSize.zero
                                let gotPos = AXValueGetValue(posCF as! AXValue, .cgPoint, &pos)
                                let gotSize = AXValueGetValue(sizeCF as! AXValue, .cgSize, &size)
                                if gotPos && gotSize {
                                    windowData.append([
                                        "x": pos.x,
                                        "y": pos.y,
                                        "width": size.width,
                                        "height": size.height
                                    ])
                                } else {
                                    print("AXValueGetValue failed for window \(i) of \(name)")
                                }
                            } else {
                                print("Skipping window \(i) of \(name): Could not read position/size (posRes=\(posRes.rawValue), sizeRes=\(sizeRes.rawValue))")
                                continue
                            }
                        }
                    } else if windowResult != .success {
                        print("Skipping \(name): AXUIElementCopyAttributeValue(.windows) failed with code \(windowResult.rawValue)")
                    }

                    // App-specific extras
                    var extras: [String: Any] = [:]
                    if bundleID == "com.apple.Safari" {
                        if let safariTabs = getSafariState() {
                            extras["safariTabs"] = safariTabs
                        }
                    }
                    else if bundleID.lowercased().contains("word") {
                        if let docs = getWordOpenDocs() {
                            extras["wordDocs"] = docs
                        }
                    }

                    // Combine standard + extras
                    var appEntry: [String: Any] = [
                        "name": name,
                        "bundleID": bundleID,
                        "windows": windowData
                    ]
                    // merge extras
                    for (k, v) in extras {
                        appEntry[k] = v
                    }

                    return appEntry
                }

            let workspaceData: [String: Any] = [
                "name": name,
                "created": ISO8601DateFormatter().string(from: Date()),
                "apps": apps
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: workspaceData, options: .prettyPrinted)
                try data.write(to: workspaceFile(named: name))
                print("Workspace '\(name)' saved: \(workspaceFile(named: name).path)")
            } catch {
                print("Error saving workspace: \(error)")
            }
        }

        // MARK: — Restore workspace
        static func restoreWorkspace(name: String) {
            let fileURL = workspaceFile(named: name)
            guard let data = try? Data(contentsOf: fileURL) else {
                print("Workspace '\(name)' not found")
                return
            }

            do {
                if let workspace = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let apps = workspace["apps"] as? [[String: Any]] {

                    for app in apps {
                        let appName = app["name"] as? String ?? ""
                        let bundleID = app["bundleID"] as? String ?? ""

                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            print("Launching app: \(appName) (\(bundleID))")
                            openApp(at: url)

                            // Wait a bit for the app to launch if needed
                            usleep(400_000)

                            // Restore windows positions
                            if let windows = app["windows"] as? [[String: Any]],
                               let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier {
                                let axApp = AXUIElementCreateApplication(pid)
                                var axWindowsObj: AnyObject?
                                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindowsObj) == .success,
                                   let axWindows = axWindowsObj as? [AXUIElement] {
                                    for (i, winDict) in windows.enumerated() where i < axWindows.count {
                                        let axWin = axWindows[i]
                                        if let x = winDict["x"] as? CGFloat,
                                           let y = winDict["y"] as? CGFloat,
                                           let w = winDict["width"] as? CGFloat,
                                           let h = winDict["height"] as? CGFloat {
                                            var pt = CGPoint(x: x, y: y)
                                            var sz = CGSize(width: w, height: h)
                                            if let posVal = AXValueCreate(.cgPoint, &pt) {
                                                AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posVal)
                                            }
                                            if let sizeVal = AXValueCreate(.cgSize, &sz) {
                                                AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeVal)
                                            }
                                            print("Restored window \(i+1) for \(appName) at (\(x), \(y), \(w)x\(h))")
                                        }
                                    }
                                }
                            }

                            // Handle Safari tabs if present
                            if bundleID == "com.apple.Safari",
                               let safariTabs = app["safariTabs"] as? [[String]] {
                                print("Restoring Safari tabs...")
                                restoreSafariTabs(safariTabs)
                                print("Completed Safari tab restore.")
                            }

                            // Handle Word docs if present
                            if bundleID.lowercased().contains("word"),
                               let docs = app["wordDocs"] as? [String] {
                                print("Restoring Word documents...")
                                restoreWordDocs(docs)
                                print("Completed Word document restore.")
                            }

                            print("Completed restoration for \(appName)")
                        } else {
                            print("Could not resolve app: \(app)")
                        }
                    }
                }
            } catch {
                print("Error parsing workspace JSON: \(error)")
            }
        }

        // MARK: — Safari state capture & restore

        static func getSafariState() -> [[String]]? {
            let script = """
            tell application "Safari"
                set safariState to {}
                repeat with w in windows
                    set tabURLs to {}
                    repeat with t in tabs of w
                        copy (URL of t) to end of tabURLs
                    end repeat
                    copy tabURLs to end of safariState
                end repeat
                return safariState
            end tell
            """
            if let apple = NSAppleScript(source: script) {
                var err: NSDictionary?
                let output = apple.executeAndReturnError(&err)
                if let err = err {
                    print("Safari scripting error: \(err)")
                    return nil
                }
                var result: [[String]] = []
                if let listDesc = output.coerce(toDescriptorType: typeAEList),
                   listDesc.numberOfItems > 0 {
                    for i in 1...listDesc.numberOfItems {
                        if let winDesc = listDesc.atIndex(i),
                           let winList = winDesc.coerce(toDescriptorType: typeAEList) {
                            var urls: [String] = []
                            for j in 1...winList.numberOfItems {
                                if let url = winList.atIndex(j)?.stringValue {
                                    urls.append(url)
                                }
                            }
                            result.append(urls)
                        }
                    }
                }
                return result
            }
            return nil
        }

        static func restoreSafariTabs(_ tabsList: [[String]]) {
            let nonEmptyTabSets = tabsList
                .map { $0.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
                .filter { !$0.isEmpty }
            guard !nonEmptyTabSets.isEmpty else {
                print("No Safari tabs to restore.")
                return
            }

            // 1. Get all currently open Safari tab URLs across all windows
            let getOpenTabsScript = """
            tell application "Safari"
                set allTabURLs to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        if u is not missing value and u is not "" then
                            copy u to end of allTabURLs
                        end if
                    end repeat
                end repeat
                return allTabURLs
            end tell
            """
            var openURLs: Set<String> = []
            if let apple = NSAppleScript(source: getOpenTabsScript) {
                var err: NSDictionary?
                let output = apple.executeAndReturnError(&err)
                if let err = err {
                    print("Error getting open Safari tab URLs: \(err)")
                } else if let listDesc = output.coerce(toDescriptorType: typeAEList) {
                    for i in 1...listDesc.numberOfItems {
                        if let url = listDesc.atIndex(i)?.stringValue {
                            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                openURLs.insert(trimmed)
                            }
                        }
                    }
                }
            }

            var scriptLines: [String] = []
            scriptLines.append("tell application \"Safari\"")
            scriptLines.append("activate")

            for tabSet in nonEmptyTabSets {
                // Check which URLs in tabSet are already open
                let missingURLs = tabSet.filter { !openURLs.contains($0) }
                if missingURLs.isEmpty {
                    print("Skipping Safari window/tab set: all URLs already open: \(tabSet)")
                    continue
                }
                print("Restoring Safari window with \(missingURLs.count) missing tabs (out of \(tabSet.count)): \(missingURLs)")
                let firstURL = missingURLs[0].replacingOccurrences(of: "\"", with: "\\\"")
                // Create a new window with the first missing URL
                scriptLines.append("set newWin to make new document with properties {URL:\"\(firstURL)\"}")
                scriptLines.append("delay 1") // give Safari time to create the window

                if missingURLs.count > 1 {
                    for url in missingURLs.dropFirst() {
                        let esc = url.replacingOccurrences(of: "\"", with: "\\\"")
                        scriptLines.append("""
                            tell front window
                                set t to make new tab at end of tabs
                                set URL of t to "\(esc)"
                            end tell
                            delay 0.5
                        """)
                    }
                }
                // Add these URLs to openURLs to avoid duplicating them in subsequent sets
                for url in missingURLs {
                    openURLs.insert(url)
                }
            }

            scriptLines.append("end tell")

            let script = scriptLines.joined(separator: "\n")
            if scriptLines.count <= 2 {
                print("No new Safari windows/tabs to restore (all URLs already open).")
                return
            }
            if let apple = NSAppleScript(source: script) {
                var err: NSDictionary?
                _ = apple.executeAndReturnError(&err)
                if let err = err {
                    print("Safari restore error: \(err)")
                } else {
                    print("Safari tabs restored successfully.")
                }
            }
        }

        // MARK: — Word state capture & restore

        static func getWordOpenDocs() -> [String]? {
            let script = """
            tell application "Microsoft Word"
                if it is running then
                    set docList to {}
                    set docCount to count of documents
                    if docCount = 0 then return {}

                    repeat with i from 1 to docCount
                        set doc to document i
                        if saved of doc is true then
                            if full name of doc is not "" then
                                try
                                    set end of docList to (name of doc) & ":::" & (full name of doc)
                                on error
                                    set end of docList to (name of doc) & ":::"
                                end try
                            end if
                        end if
                    end repeat
                    return docList
                end if
            end tell
            """
            if let apple = NSAppleScript(source: script) {
                var err: NSDictionary?
                let output = apple.executeAndReturnError(&err)
                if let err = err {
                    print("Word scripting error: \(err)")
                    return nil
                }
                var paths: [String] = []
                if let listDesc = output.coerce(toDescriptorType: typeAEList) {
                    let count = listDesc.numberOfItems
                    if count > 0 {
                        for i in 1...listDesc.numberOfItems {
                            if let p = listDesc.atIndex(i)?.stringValue {
                                paths.append(p)
                            }
                        }
                    }
                }
                return paths
            }
            return nil
        }

        static func restoreWordDocs(_ docs: [String]) {
            // First, get currently open Word docs (paths), so we don't re-open
            let openDocs = getWordOpenDocs() ?? []
            var openDocPaths: Set<String> = []
            for docPath in openDocs {
                let path: String
                if docPath.contains(":::") {
                    let parts = docPath.components(separatedBy: ":::")
                    path = parts.count > 1 ? parts[1] : parts[0]
                } else {
                    path = docPath
                }
                let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPath.isEmpty { openDocPaths.insert(trimmedPath) }
            }

            // For each doc to restore, skip if already open
            let fm = FileManager.default
            var openParts: [String] = []
            for docPath in docs {
                // Defensive: docPath may be "name:::fullpath" or just a full path
                let path: String
                if docPath.contains(":::") {
                    let parts = docPath.components(separatedBy: ":::")
                    path = parts.count > 1 ? parts[1] : parts[0]
                } else {
                    path = docPath
                }
                let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPath.isEmpty else {
                    print("Skipping empty Word document path")
                    continue
                }
                // If already open, skip
                if openDocPaths.contains(trimmedPath) {
                    print("Skipping already open Word doc: \(trimmedPath)")
                    continue
                }
                // Use AppleScript to convert HFS to POSIX path if needed
                var posixPath: String? = nil
                if trimmedPath.hasPrefix("/") {
                    posixPath = trimmedPath
                } else if let url = URL(string: trimmedPath), url.isFileURL {
                    posixPath = url.path
                } else {
                    // Use AppleScript to convert HFS to POSIX
                    let escPath = trimmedPath.replacingOccurrences(of: "\"", with: "\\\"")
                    let hfsScript = """
                    tell application "Finder"
                        set posixPath to POSIX path of "\(escPath)"
                    end tell
                    """
                    if let apple = NSAppleScript(source: hfsScript) {
                        var err: NSDictionary?
                        let result = apple.executeAndReturnError(&err)
                        if let err = err {
                            print("Error converting HFS to POSIX for Word doc: \(trimmedPath): \(err)")
                        }
                        if let p = result.stringValue, !p.isEmpty {
                            posixPath = p.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    // If still nil, fallback to trimmedPath
                    if posixPath == nil {
                        posixPath = trimmedPath
                    }
                }
                guard let resolvedPosix = posixPath, !resolvedPosix.isEmpty else {
                    print("Could not resolve POSIX path for Word doc: \(docPath)")
                    continue
                }
                if !fm.isReadableFile(atPath: resolvedPosix) {
                    print("Skipping Word doc \(resolvedPosix): file does not exist or is not readable")
                    continue
                }
                print("Restoring Word document: \(resolvedPosix)")
                // Wrap open in try/catch AppleScript to catch permission errors and log
                openParts.append("""
                    try
                        open POSIX file "\(resolvedPosix)"
                    on error errMsg
                        log "Failed to open \(resolvedPosix): " & errMsg
                    end try
                """)
            }
            guard !openParts.isEmpty else {
                print("No new Word documents to restore.")
                return
            }
            let scriptBase = """
            tell application "Microsoft Word"
                activate
            """
            let script = scriptBase + "\n" + openParts.joined(separator: "\n") + "\nend tell"
            if let apple = NSAppleScript(source: script) {
                var err: NSDictionary?
                _ = apple.executeAndReturnError(&err)
                if let err = err { print("Word restore error: \(err)") }
            }
        }
    
    
    static func openApp(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if let error = error {
                print("Failed to open application at \(url.path): \(error)")
            } else {
                print("App launched: \(url.lastPathComponent)")
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
    
    
    
    static func debugListWindowFrames() {
        print("starting debugListWindowFrames")
        guard promptForAccessibilityIfNeeded() else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName else { continue }
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            var windowsObj: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsObj) == .success,
               let axWindows = windowsObj as? [AXUIElement] {
                for axWindow in axWindows {
                    var posRef: CFTypeRef?
                    var sizeRef: CFTypeRef?
                   
                    let posRes = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                    let sizeRes = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)

                    if posRes == .success, sizeRes == .success,
                       let posCF = posRef, let sizeCF = sizeRef,
                       CFGetTypeID(posCF) == AXValueGetTypeID(),
                       CFGetTypeID(sizeCF) == AXValueGetTypeID() {

                        var pos = CGPoint.zero
                        var size = CGSize.zero

                        let gotPos = AXValueGetValue(posCF as! AXValue, .cgPoint, &pos)
                        let gotSize = AXValueGetValue(sizeCF as! AXValue, .cgSize, &size)

                        if gotPos && gotSize {
                            print("\(name) window at (\(pos.x), \(pos.y)) size (\(size.width)x\(size.height))")
                        } else {
                            print("AXValueGetValue failed for \(name)")
                        }
                    } else {
                        print("Could not get position/size for window of \(name). posRes=\(posRes.rawValue) sizeRes=\(sizeRes.rawValue)")
                    }
                }
            }
        }
    }
}

