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
            .appendingPathComponent("Library/Application Support/Workspace Manager/Workspaces")
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
        print("[WorkspaceManager] saveWorkspace(\(name)) — START")
        guard promptForAccessibilityIfNeeded() else { print("[WorkspaceManager] Accessibility required — abort save"); return }

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> [String: Any]? in
                guard let name = app.localizedName,
                      let bundleID = app.bundleIdentifier else { return nil }

                // 🚫 Skip Finder entirely
                if bundleID == "com.apple.finder" {
                    print("[saveWorkspace] Skipping Finder")
                    return nil
                }
                
                print("[saveWorkspace] Processing app: \(name) (\(bundleID))")

                var windowData: [[String: Any]] = []

                // Collect window frames robustly for Finder and others
                let pid = app.processIdentifier
                let axApp = AXUIElementCreateApplication(pid)
                var windowsObj: AnyObject?
                let windowResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsObj)
                print("[saveWorkspace] AX windows result for \(name): \(windowResult.rawValue)")

                if windowResult == .success, let axWindows = windowsObj as? [AXUIElement] {
                    print("[saveWorkspace] Found \(axWindows.count) AX windows for \(name)")
                    for (index, axWindow) in axWindows.enumerated() {
                        print("[saveWorkspace] -> AX window index: \(index)")
                        var posRef: CFTypeRef?
                        var sizeRef: CFTypeRef?
                        let posRes = AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                        let sizeRes = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                        print("[saveWorkspace] ---- posRes=\(posRes.rawValue) sizeRes=\(sizeRes.rawValue)")

                        if posRes == .success, sizeRes == .success,
                           let posCF = posRef, let sizeCF = sizeRef,
                           CFGetTypeID(posCF) == AXValueGetTypeID(),
                           CFGetTypeID(sizeCF) == AXValueGetTypeID() {

                            var pos = CGPoint.zero
                            var size = CGSize.zero
                            let gotPos = AXValueGetValue(posCF as! AXValue, .cgPoint, &pos)
                            let gotSize = AXValueGetValue(sizeCF as! AXValue, .cgSize, &size)

                            print("[saveWorkspace] ---- AXValueGetValue gotPos=\(gotPos) gotSize=\(gotSize) for \(name)")

                            if gotPos && gotSize {
                                print("[saveWorkspace] ---- window frame for \(name): (\(pos.x), \(pos.y)) size (\(size.width)x\(size.height))")

                                // Filter small/hidden windows
                                if size.width < 300 || size.height < 200 {
                                    print("[saveWorkspace] ---- Skipping small window for \(name) (\(size.width)x\(size.height))")
                                    continue
                                }

                                // Filter offscreen windows
                                if let mainScreen = NSScreen.main {
                                    let screenFrame = mainScreen.visibleFrame
                                    let windowFrame = CGRect(origin: pos, size: size)
                                    if !screenFrame.intersects(windowFrame) {
                                        print("[saveWorkspace] ---- Skipping offscreen window for \(name)")
                                        continue
                                    }
                                }

                                windowData.append([
                                    "x": pos.x,
                                    "y": pos.y,
                                    "width": size.width,
                                    "height": size.height
                                ])
                            } else {
                                print("[saveWorkspace] ---- AXValueGetValue failed to extract point/size for \(name)")
                            }
                        } else {
                            print("[saveWorkspace] ---- Could not get pos/size CF values for \(name)")
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
                                print("[saveWorkspace] Logos: selecting largest window only: \(largest)")
                                windowData = [largest]
                            }
                        }
                    }

                    print("[saveWorkspace] Collected \(windowData.count) windows for \(name)")
                } else if windowResult != .success {
                    print("[saveWorkspace] Skipping \(name): AXUIElementCopyAttributeValue(.windows) failed with code \(windowResult.rawValue)")
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

                print("[saveWorkspace] Finished processing app: \(name)")
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
            print("[WorkspaceManager] saveWorkspace(\(name)) — SAVED to \(workspaceFile(named: name).path)")
        } catch {
            print("[WorkspaceManager] Error saving workspace: \(error)")
        }
    }

        // MARK: — Restore workspace
    static func restoreWorkspace(name: String) {
        print("[WorkspaceManager] restoreWorkspace(\(name)) — START")
        let fileURL = workspaceFile(named: name)
        guard let data = try? Data(contentsOf: fileURL) else {
            print("[WorkspaceManager] Workspace '\(name)' not found at \(fileURL.path)")
            return
        }

        do {
            if let workspace = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let apps = workspace["apps"] as? [[String: Any]] {

                for app in apps {
                    let appName = app["name"] as? String ?? ""
                    let bundleID = app["bundleID"] as? String ?? ""
                    print("[restoreWorkspace] App entry: \(appName) (\(bundleID))")

                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        print("[restoreWorkspace] Resolved app URL: \(url.path)")
                        print("[restoreWorkspace] Launching app: \(appName)")
                        openApp(at: url)
                        
                        // If app has no saved windows, don’t try to manipulate AX windows
                        let hasWindows = (app["windows"] as? [[String: Any]])?.isEmpty == false
                        if !hasWindows {
                            print("[restoreWorkspace] \(appName) has no saved windows; launching only.")
                            continue
                        }

                        // Wait a bit for the app to launch if needed
                        usleep(400_000)

                        // Restore windows positions with polling and largest-first logic
                        if let windows = app["windows"] as? [[String: Any]],
                           let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier {
                            print("[restoreWorkspace] Need to restore \(windows.count) windows for \(appName)")
                            let axApp = AXUIElementCreateApplication(pid)
                            var axWindowsObj: AnyObject?
                            var axWindows: [AXUIElement] = []
                            let maxWait: TimeInterval = 5.0
                            let pollInterval: TimeInterval = 0.2
                            let start = Date()
                            var found = false
                            var attempts = 0
                            repeat {
                                attempts += 1
                                let res = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindowsObj)
                                print("[restoreWorkspace] Poll attempt \(attempts): AX windows res=\(res.rawValue)")
                                if res == .success, let wins = axWindowsObj as? [AXUIElement], wins.count >= windows.count {
                                    axWindows = wins
                                    found = true
                                    break
                                }
                                usleep(useconds_t(pollInterval * 1_000_000))
                            } while Date().timeIntervalSince(start) < maxWait

                            // One last try if not found
                            if !found {
                                let res2 = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindowsObj)
                                print("[restoreWorkspace] Final AX try res=\(res2.rawValue)")
                                if res2 == .success, let wins = axWindowsObj as? [AXUIElement] {
                                    axWindows = wins
                                }
                            }

                            print("[restoreWorkspace] Found \(axWindows.count) AX windows for \(appName)")

                            if !axWindows.isEmpty {
                                // Calculate areas for windows discovered
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
                                // Sort saved windows largest-first too
                                let sortedSaved = windows.enumerated().map { (i, win) -> (Int, [String: Any], CGFloat) in
                                    let w = (win["width"] as? CGFloat ?? 0) * (win["height"] as? CGFloat ?? 0)
                                    return (i, win, w)
                                }.sorted(by: { $0.2 > $1.2 })

                                print("[restoreWorkspace] Applying frames to min(\(sortedIndices.count), \(sortedSaved.count)) windows")
                                let count = min(sortedIndices.count, sortedSaved.count)
                                for n in 0..<count {
                                    let winIdx = sortedIndices[n]
                                    let axWin = axWindows[winIdx]
                                    let winDict = sortedSaved[n].1
                                    print("[restoreWorkspace] Restoring saved window index \(sortedSaved[n].0) -> AX window index \(winIdx)")
                                    if let x = winDict["x"] as? CGFloat,
                                       let y = winDict["y"] as? CGFloat,
                                       let w = winDict["width"] as? CGFloat,
                                       let h = winDict["height"] as? CGFloat {
                                        var pt = CGPoint(x: x, y: y)
                                        var sz = CGSize(width: w, height: h)
                                        if let posVal = AXValueCreate(.cgPoint, &pt) {
                                            let posSet = AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posVal)
                                            print("[restoreWorkspace] -> set position result: \(posSet.rawValue)")
                                        }
                                        if let sizeVal = AXValueCreate(.cgSize, &sz) {
                                            let sizeSet = AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeVal)
                                            print("[restoreWorkspace] -> set size result: \(sizeSet.rawValue)")
                                        }
                                        print("[restoreWorkspace] Restored window \(n+1) for \(appName) at (\(x), \(y)) size (\(w)x\(h))")
                                    }
                                }
                            } else {
                                print("[restoreWorkspace] No AX windows available to restore for \(appName)")
                            }
                        } else {
                            print("[restoreWorkspace] No windows to restore for \(appName) or app not running yet")
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
                        print("[restoreWorkspace] Could not resolve app for entry: \(app)")
                    }
                }
            }
        } catch {
            print("[WorkspaceManager] Error parsing workspace JSON: \(error)")
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

    static func restoreSafariTabs(_ tabsList: [[String]]) {
        print("[restoreSafariTabs] START - tab sets to restore: \(tabsList.count)")

        // debugPrintSafariTabs()
        
        let nonEmptyTabSets = tabsList
            .map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }

        guard !nonEmptyTabSets.isEmpty else {
            print("[restoreSafariTabs] No Safari tabs to restore.")
            return
        }

        // 1️⃣ Close only empty/blank Safari windows, not all
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
        print("[restoreSafariTabs] Closing empty or blank Safari windows...")
        if let closeApple = NSAppleScript(source: closeScript) {
            var closeErr: NSDictionary?
            let result = closeApple.executeAndReturnError(&closeErr)
            if let e = closeErr {
                print("[restoreSafariTabs] Error closing Safari windows: \(e)")
            } else {
                // Print which windows were closed and why
                if let desc = result.coerce(toDescriptorType: typeAEList), desc.numberOfItems > 0 {
                    for i in 1...desc.numberOfItems {
                        if let msg = desc.atIndex(i)?.stringValue {
                            print("[restoreSafariTabs] Closed \(msg)")
                        }
                    }
                } else {
                    print("[restoreSafariTabs] No empty or blank Safari windows needed closing.")
                }
            }
        }
        // small delay so Safari can settle
        usleep(1_000_000)

        // 2️⃣ Get currently open Safari window tab sets (order ignored for comparison)
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

        // 3️⃣ Create new Safari windows/tabs, skipping duplicates
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
                print("[restoreSafariTabs] Skipping Safari window \(index + 1): tab set already open (\(tabSetTrimmed.count) tabs).")
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

            print("[restoreSafariTabs] Executing AppleScript for window \(index + 1):\n\(script)")

            if let apple = NSAppleScript(source: script) {
                var err: NSDictionary?
                _ = apple.executeAndReturnError(&err)
                if let err = err {
                    print("[restoreSafariTabs] Safari restore error (window \(index + 1)): \(err)")
                } else {
                    print("[restoreSafariTabs] Successfully restored Safari window \(index + 1)")
                }
            } else {
                print("[restoreSafariTabs] Failed to create AppleScript for Safari window \(index + 1)")
            }

            // delay between windows to avoid race conditions
            usleep(2_000_000)
        }

        print("[restoreSafariTabs] DONE restoring Safari tabs.")
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

        // Run the completion *after* the user’s choice is handled
        onComplete?()
    }

    /// Shows an alert dialog with a dropdown of saved workspaces, and restores the selected one.
    static func chooseWorkspaceToRestore() {
        DispatchQueue.main.async {
            let names = listSavedWorkspaces()
            guard !names.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "No Saved Workspaces"
                alert.informativeText = "There are no saved workspaces to restore."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Restore Workspace"
            alert.informativeText = "Choose a workspace to restore:"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            popup.addItems(withTitles: names)
            alert.accessoryView = popup

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let selected = popup.selectedItem?.title ?? ""
                if !selected.isEmpty {
                    restoreWorkspace(name: selected)
                }
            }
        }
    }
    
    
    
    static func debugListWindowFrames() {
        print("starting debugListWindowFrames")
        var windowData: [[String: Any]] = []
        guard promptForAccessibilityIfNeeded() else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName else { continue }
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            var windowsObj: AnyObject?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsObj) == .success,
               let axWindows = windowsObj as? [AXUIElement] {
                for (_, axWindow) in axWindows.enumerated() {
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
                            // Filter small/hidden windows
                            if size.width < 300 || size.height < 200 {
                                print("Skipping small window for \(name) at (\(pos.x), \(pos.y)) size (\(size.width)x\(size.height))")
                                continue
                            }

                            // Filter offscreen windows
                            if let mainScreen = NSScreen.main {
                                let screenFrame = mainScreen.visibleFrame
                                let windowFrame = CGRect(origin: pos, size: size)
                                if !screenFrame.intersects(windowFrame) {
                                    print("Skipping offscreen window for \(name)")
                                    continue
                                }
                            }
                            
                            // Keep only the largest Logos window
                            if name == "Logos", windowData.count > 1 {
                                if let largest = windowData.max(by: {
                                    ($0["width"] as! CGFloat) * ($0["height"] as! CGFloat)
                                    < ($1["width"] as! CGFloat) * ($1["height"] as! CGFloat)
                                }) {
                                    windowData = [largest]
                                    print("Reduced Logos windowData to main visible window: \(largest)")
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
            }
        }
        print ("\(windowData)")
    }
    
    static func debugPrintSafariTabs() {
        let script = """
        tell application "Safari"
            set allTabs to {}
            repeat with w in windows
                set tabURLs to {}
                repeat with t in tabs of w
                    try
                        copy (URL of t as string) to end of tabURLs
                    on error
                        copy "ERROR" to end of tabURLs
                    end try
                end repeat
                copy tabURLs to end of allTabs
            end repeat
            return allTabs
        end tell
        """
        
        if let apple = NSAppleScript(source: script) {
            var err: NSDictionary?
            let output = apple.executeAndReturnError(&err)
            if let err = err {
                print("[debugPrintSafariTabs] AppleScript error: \(err)")
                return
            }
            
            if let listDesc = output.coerce(toDescriptorType: typeAEList), listDesc.numberOfItems > 0 {
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
                        print("[debugPrintSafariTabs] Window \(i) URLs: \(urls)")
                    }
                }
            } else {
                print("[debugPrintSafariTabs] No windows found")
            }
        }
    }
}

