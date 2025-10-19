import Foundation
import AppKit
import ApplicationServices

struct WorkspaceManager {
    /// Presents a user-facing prompt to guide granting Accessibility permission
    @discardableResult
    static func promptForAccessibilityIfNeeded() -> Bool {
        // Fast path: already trusted
        if ensureAccessibilityTrusted(prompt: false) { return true }

        // Trigger the system prompt
        return ensureAccessibilityTrusted(prompt: true)
    }

    
    /// Opens the System Settings (or System Preferences) to the Accessibility pane
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
            .appendingPathComponent("Library/Application Support/Workspace Manager/Workspaces")
        _ = try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    
    static func workspaceFile(named name: String) -> URL {
        return saveDir.appendingPathComponent("\(name).json")
    }
    
    
    /// Saves workspace (apps + windows + app-specific state)
    static func saveWorkspace(name: String) {
        // print("[WorkspaceManager] saveWorkspace(\(name)) — START")
        guard promptForAccessibilityIfNeeded() else { return }

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> [String: Any]? in
                guard let name = app.localizedName,
                      let bundleID = app.bundleIdentifier else { return nil }

                // Skip Finder entirely
                if bundleID == "com.apple.finder" {
                    return nil
                }

                var windowData: [[String: Any]] = []

                // Collect window frames robustly for Finder and others
                let pid = app.processIdentifier
                let axApp = AXUIElementCreateApplication(pid)
                var windowsObj: AnyObject?
                let windowResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsObj)
                // (Detailed window collection print statements removed)
                if windowResult == .success, let axWindows = windowsObj as? [AXUIElement] {
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
                                if size.width < 300 || size.height < 200 {
                                    continue
                                }
                                if let mainScreen = NSScreen.main {
                                    let screenFrame = mainScreen.visibleFrame
                                    let windowFrame = CGRect(origin: pos, size: size)
                                    if !screenFrame.intersects(windowFrame) {
                                        continue
                                    }
                                }
                                windowData.append([
                                    "x": pos.x,
                                    "y": pos.y,
                                    "width": size.width,
                                    "height": size.height
                                ])
                            }
                        }
                    }
                    // If this is Logos, keep only the largest window (main visible)
                    if name == "Logos" && !windowData.isEmpty {
                        if windowData.count > 1 {
                            if let largest = windowData.max(by: { (a, b) -> Bool in
                                let aw = (a["width"] as? CGFloat ?? 0) * (a["height"] as? CGFloat ?? 0)
                                let bw = (b["width"] as? CGFloat ?? 0) * (b["height"] as? CGFloat ?? 0)
                                return aw < bw
                            }) {
                                windowData = [largest]
                            }
                        }
                    }
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
        } catch {
        }
    }

    /// Deletes a saved workspace
        static func deleteWorkspace(name: String) {
            let fileURL = workspaceFile(named: name)
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("Deleted workspace: \(name)")
            } catch {
                print("Error deleting workspace \(name): \(error)")
            }
        }
        
        /// Closes all apps that are not in the given workspace
        static func closeAppsNotInWorkspace(_ workspaceApps: [[String: Any]]) {
            let workspaceBundleIDs = Set(workspaceApps.compactMap { $0["bundleID"] as? String })
            
            // System apps that should never be closed
            let protectedBundleIDs: Set<String> = [
                "com.apple.finder",
                "com.apple.systemuiserver",
                "com.apple.dock",
                "com.apple.notificationcenterui",
                "com.apple.controlcenter",
                Bundle.main.bundleIdentifier ?? ""  // Don't close ourselves
            ]
            
            let runningApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
            
            for app in runningApps {
                guard let bundleID = app.bundleIdentifier else { continue }
                
                // Skip if it's in the workspace or protected
                if workspaceBundleIDs.contains(bundleID) || protectedBundleIDs.contains(bundleID) {
                    continue
                }
                
                // Try to terminate gracefully first
                if let appName = app.localizedName {
                    print("Closing app not in workspace: \(appName)")
                }
                
                app.terminate()
                
                // If it doesn't respond to terminate, try force quit after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if app.isTerminated == false {
                        app.forceTerminate()
                    }
                }
            }
        }
        
        /// Modified restoreWorkspace function with closeOthers parameter
        static func restoreWorkspace(name: String, closeOthers: Bool = false) {
            print("Restoring workspace: \(name)")
            let fileURL = workspaceFile(named: name)
            guard let data = try? Data(contentsOf: fileURL) else {
                return
            }

            do {
                if let workspace = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let apps = workspace["apps"] as? [[String: Any]] {

                    // Close other apps first if requested
                    if closeOthers {
                        print("Closing apps not in workspace...")
                        closeAppsNotInWorkspace(apps)
                        // Wait a bit for apps to close
                        usleep(1_000_000)
                    }

                    // Then restore the workspace apps (rest of the existing code)
                    for app in apps {
                        let appName = app["name"] as? String ?? ""
                        print("Restoring app: \(appName)")
                        let bundleID = app["bundleID"] as? String ?? ""

                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            openApp(at: url)

                            let hasWindows = (app["windows"] as? [[String: Any]])?.isEmpty == false
                            if !hasWindows {
                                continue
                            }

                            usleep(400_000)

                            if let windows = app["windows"] as? [[String: Any]],
                               let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier {
                                let axApp = AXUIElementCreateApplication(pid)
                                var axWindowsObj: AnyObject?
                                var axWindows: [AXUIElement] = []
                                let maxWait: TimeInterval = 5.0
                                let pollInterval: TimeInterval = 0.2
                                let start = Date()
                                var found = false
                                repeat {
                                    let res = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindowsObj)
                                    if res == .success, let wins = axWindowsObj as? [AXUIElement], wins.count >= windows.count {
                                        axWindows = wins
                                        found = true
                                        break
                                    }
                                    usleep(useconds_t(pollInterval * 1_000_000))
                                } while Date().timeIntervalSince(start) < maxWait

                                if !found {
                                    let res2 = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindowsObj)
                                    if res2 == .success, let wins = axWindowsObj as? [AXUIElement] {
                                        axWindows = wins
                                    }
                                }

                                if !axWindows.isEmpty {
                                    let indexedWindows = axWindows.enumerated().map { (i, win) -> (Int, AXUIElement, CGFloat) in
                                        var sizeRef: CFTypeRef?
                                        var area: CGFloat = 0
                                        if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
                                           let sizeCF = sizeRef, CFGetTypeID(sizeCF) == AXValueGetTypeID() {
                                            var sz = CGSize.zero
                                            if AXValueGetValue(sizeCF as! AXValue, .cgSize, &sz) {
                                                area = sz.width * sz.height
                                            }
                                        }
                                        return (i, win, area)
                                    }
                                    let sortedIndices = indexedWindows.sorted(by: { $0.2 > $1.2 }).map { $0.0 }
                                    let sortedSaved = windows.enumerated().map { (i, win) -> (Int, [String: Any], CGFloat) in
                                        let w = (win["width"] as? CGFloat ?? 0) * (win["height"] as? CGFloat ?? 0)
                                        return (i, win, w)
                                    }.sorted(by: { $0.2 > $1.2 })
                                    let count = min(sortedIndices.count, sortedSaved.count)
                                    for n in 0..<count {
                                        let winIdx = sortedIndices[n]
                                        let axWin = axWindows[winIdx]
                                        let winDict = sortedSaved[n].1
                                        if let x = winDict["x"] as? CGFloat,
                                           let y = winDict["y"] as? CGFloat,
                                           let w = winDict["width"] as? CGFloat,
                                           let h = winDict["height"] as? CGFloat {
                                            var pt = CGPoint(x: x, y: y)
                                            var sz = CGSize(width: w, height: h)
                                            if let posVal = AXValueCreate(.cgPoint, &pt) {
                                                _ = AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posVal)
                                            }
                                            if let sizeVal = AXValueCreate(.cgSize, &sz) {
                                                _ = AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeVal)
                                            }
                                        }
                                    }
                                }
                            }

                            // Handle Safari tabs if present
                            if bundleID == "com.apple.Safari",
                               let safariTabs = app["safariTabs"] as? [[String]] {
                                print("Restoring Safari tabs...")
                                restoreSafariTabs(safariTabs)
                            }

                            // Handle Word docs if present
                            if bundleID.lowercased().contains("word"),
                               let docs = app["wordDocs"] as? [String] {
                                print("Restoring Word documents...")
                                restoreWordDocs(docs)
                            }
                        }
                    }
                }
            } catch {
            }
        }

    /// Safari state capture & restore
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
                        let tabCount = winList.numberOfItems
                        if tabCount > 0 {
                            for j in 1...tabCount {
                                if let url = winList.atIndex(j)?.stringValue {
                                    urls.append(url)
                                }
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

    
    /// Restores Safari tabs
    static func restoreSafariTabs(_ tabsList: [[String]]) {
        let nonEmptyTabSets = tabsList
            .map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }

        guard !nonEmptyTabSets.isEmpty else {
            return
        }

        // 1. Close only empty/blank Safari windows, not all
        let closeScript = """
        tell application "Safari"
            set closedWindows to {}
            set winCount to count of windows
            repeat with w from winCount to 1 by -1
                set theWin to window w
                set tabCount to count of tabs of theWin
                if tabCount = 0 then
                    close theWin
                    set end of closedWindows to "window " & w & " (no tabs)"
                else
                    set allBlank to true
                    repeat with t in tabs of theWin
                        try
                            set tabURL to (URL of t as string)
                        on error
                            set tabURL to ""
                        end try
                        if tabURL is not "" and tabURL is not "about:blank" and tabURL is not "https://www.apple.com/startpage" and tabURL is not "favorites://" then
                            set allBlank to false
                            exit repeat
                        end if
                    end repeat
                    if allBlank then
                        close theWin
                        set end of closedWindows to "window " & w & " (all blank tabs)"
                    end if
                end if
            end repeat
            return closedWindows
        end tell
        """
        if let closeApple = NSAppleScript(source: closeScript) {
            var closeErr: NSDictionary?
            let _ = closeApple.executeAndReturnError(&closeErr)
        }
        // small delay so Safari can settle
        usleep(1_000_000)

        // 2. Get currently open Safari window tab sets (order ignored for comparison)
        let getOpenTabsScript = """
        tell application "Safari"
            set allTabs to {}
            repeat with w in windows
                set tabURLs to {}
                repeat with t in tabs of w
                    copy (URL of t) to end of tabURLs
                end repeat
                copy tabURLs to end of allTabs
            end repeat
            return allTabs
        end tell
        """
        var openTabSets: [[String]] = []
        if let openTabsApple = NSAppleScript(source: getOpenTabsScript) {
            var openTabsErr: NSDictionary?
            let output = openTabsApple.executeAndReturnError(&openTabsErr)
            if let openTabsErr = openTabsErr {
                print("[restoreSafariTabs] Error getting open Safari tabs: \(openTabsErr)")
            } else if let listDesc = output.coerce(toDescriptorType: typeAEList), listDesc.numberOfItems > 0 {
                for i in 1...listDesc.numberOfItems {
                    if let winDesc = listDesc.atIndex(i),
                       let winList = winDesc.coerce(toDescriptorType: typeAEList) {
                        var urls: [String] = []
                        let tabCount = winList.numberOfItems
                        if tabCount > 0 {
                            for j in 1...tabCount {
                                if let url = winList.atIndex(j)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                                    urls.append(url)
                                }
                            }
                        }
                        if !urls.isEmpty {
                            openTabSets.append(urls)
                        }
                    }
                }
            }
        }

        // Prepare openTabSets as sets for comparison (order-insensitive)
        let openTabSetHashes: [Set<String>] = openTabSets.map { Set($0) }

        // 3. Create new Safari windows/tabs, skipping duplicates
        for (index, tabSet) in nonEmptyTabSets.enumerated() {
            let tabSetTrimmed = tabSet.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let tabSetHash = Set(tabSetTrimmed)
            var isDuplicate = false
            for existing in openTabSetHashes {
                if existing == tabSetHash {
                    isDuplicate = true
                    break
                }
            }
            if isDuplicate {
                continue
            }

            print("[restoreSafariTabs] Restoring Safari window \(index + 1) with \(tabSetTrimmed.count) tabs.")

            guard let firstURL = tabSetTrimmed.first else { continue }

            // Construct the AppleScript for this window
            var script = """
            tell application "Safari"
                activate
                make new document with properties {URL:"\(firstURL)"}
                set currentWindow to front window
            """

            if tabSetTrimmed.count > 1 {
                for tabURL in tabSetTrimmed.dropFirst() {
                    let esc = tabURL.replacingOccurrences(of: "\"", with: "\\\"")
                    script += """
                    
                    make new tab at end of tabs of currentWindow with properties {URL:"\(esc)"}
                    """
                }
            }

            script += "\nend tell"

            if let apple = NSAppleScript(source: script) {
                var err: NSDictionary?
                _ = apple.executeAndReturnError(&err)
            } else {
                print("[restoreSafariTabs] Failed to create AppleScript for Safari window \(index + 1)")
            }

            // delay between windows to avoid race conditions
            usleep(2_000_000)
        }

        print("[restoreSafariTabs] DONE restoring Safari tabs.")
    }

    
    /// Word state capture & restore
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

    
    /// Restores specific Word documents
    static func restoreWordDocs(_ docs: [String]) {
        print("[restoreWordDocs] START - docs to restore: \(docs.count)")
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
        print("[restoreWordDocs] Currently open Word docs: \(openDocPaths.count)")

        // For each doc to restore, skip if already open
        let fm = FileManager.default
        var openParts: [String] = []
        for docPath in docs {
            let path: String
            if docPath.contains(":::") {
                let parts = docPath.components(separatedBy: ":::")
                path = parts.count > 1 ? parts[1] : parts[0]
            } else {
                path = docPath
            }
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else {
                print("[restoreWordDocs] Skipping empty Word document path")
                continue
            }
            if openDocPaths.contains(trimmedPath) {
                print("[restoreWordDocs] Skipping already open Word doc: \(trimmedPath)")
                continue
            }

            // Convert HFS to POSIX if necessary via AppleScript
            var posixPath: String? = nil
            if trimmedPath.hasPrefix("/") {
                posixPath = trimmedPath
            } else if let url = URL(string: trimmedPath), url.isFileURL {
                posixPath = url.path
            } else {
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
                        print("[restoreWordDocs] Error converting HFS to POSIX for Word doc: \(trimmedPath): \(err)")
                    }
                    if let p = result.stringValue, !p.isEmpty {
                        posixPath = p.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("[restoreWordDocs] Converted to POSIX: \(posixPath ?? "")")
                    }
                }
                if posixPath == nil { posixPath = trimmedPath }
            }

            guard let resolvedPosix = posixPath, !resolvedPosix.isEmpty else {
                print("[restoreWordDocs] Could not resolve POSIX path for Word doc: \(docPath)")
                continue
            }
            if !fm.isReadableFile(atPath: resolvedPosix) {
                print("[restoreWordDocs] Skipping Word doc \(resolvedPosix): file does not exist or is not readable")
                continue
            }
            print("[restoreWordDocs] Queuing open for Word document: \(resolvedPosix)")
            openParts.append("""
                try
                    open POSIX file "\(resolvedPosix)"
                on error errMsg
                    log "Failed to open \(resolvedPosix): " & errMsg
                end try
            """)
        }

        guard !openParts.isEmpty else {
            print("[restoreWordDocs] No new Word documents to restore.")
            return
        }

        let scriptBase = """
        tell application "Microsoft Word"
            activate
        """
        let script = scriptBase + "\n" + openParts.joined(separator: "\n") + "\nend tell"
        print("[restoreWordDocs] Executing AppleScript:\n\(script)")
        if let apple = NSAppleScript(source: script) {
            var err: NSDictionary?
            _ = apple.executeAndReturnError(&err)
            if let err = err { print("[restoreWordDocs] Word restore error: \(err)") }
            else { print("[restoreWordDocs] Word restore script executed") }
        } else {
            print("[restoreWordDocs] Failed to build AppleScript for Word restore")
        }
    }
    
    
    static func openApp(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if error == nil {
                print("App launched: \(url.lastPathComponent)")
            }
        }
    }
    
    
    static func listSavedWorkspaces() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)) ?? []
        let names = files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
        return names
    }

    /// Shows an alert dialog asking the user for a workspace name, then saves the workspace with that name.
    static func promptAndSaveWorkspace(onComplete: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Enter a name for your workspace:"
        alert.alertStyle = .informational

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = inputField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                saveWorkspace(name: name)
            }
        }

        // Run the completion *after* the user’s choice is handled (this updates the workspace list in the menu bar)
        onComplete?()
    }
}

