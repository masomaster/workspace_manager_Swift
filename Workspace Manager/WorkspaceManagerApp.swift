import SwiftUI
import Combine
import Carbon

class WorkspaceMenuModel: ObservableObject {
    @Published var savedWorkspaces: [String] = []
    @Published var closeOthersEnabled: Bool = false
    
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func refresh() {
        savedWorkspaces = WorkspaceManager.listSavedWorkspaces()
    }
    
    func confirmAndDeleteWorkspace(name: String) {
        let alert = NSAlert()
        alert.messageText = "Delete Workspace"
        alert.informativeText = "Are you sure you want to delete '\(name)'? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            WorkspaceManager.deleteWorkspace(name: name)
            refresh()
        }
    }
    
    func setupKeyboardShortcuts() {
        // Request accessibility permissions if needed
        let trusted = WorkspaceManager.ensureAccessibilityTrusted(prompt: true)
        
        if !trusted {
            print("⚠️ Accessibility permissions not granted. Keyboard shortcuts will not work.")
            print("Please grant accessibility permissions and restart the app.")
        }
        
        // Monitor for local keyboard events (when this app has focus)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil // Event handled, consume it
            }
            return event // Pass through
        }
        
        // Monitor for global keyboard events (when other apps have focus)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        
        print("✓ Keyboard shortcuts registered")
        print("  Save: ⌘⌥⌃S")
        print("  Restore 1-9: ⌘⌥⌃1-9")
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        
        // Cmd+Option+Control+S = Save Workspace
        if flags == [.command, .option, .control] && event.keyCode == 1 { // S key
            print("🎹 Keyboard shortcut triggered: Save Workspace")
            DispatchQueue.main.async {
                // Activate app to show dialog properly
                NSApp.activate(ignoringOtherApps: true)
                WorkspaceManager.promptAndSaveWorkspace {
                    self.refresh()
                }
            }
            return true
        }
        
        // Cmd+Option+Control+1-9 = Restore Workspace 1-9
        if flags == [.command, .option, .control] {
            let workspaceNumber = self.keyCodeToNumber(event.keyCode)
            if let num = workspaceNumber, num >= 1 && num <= 9 {
                print("🎹 Keyboard shortcut triggered: Restore Workspace \(num)")
                DispatchQueue.main.async {
                    let workspaces = self.savedWorkspaces
                    if num <= workspaces.count {
                        let workspaceName = workspaces[num - 1]
                        // No need to activate app for restore - it doesn't show UI
                        WorkspaceManager.restoreWorkspace(name: workspaceName, closeOthers: self.closeOthersEnabled)
                    } else {
                        print("⚠️ Workspace \(num) not found (only \(workspaces.count) workspaces saved)")
                    }
                }
                return true
            }
        }
        
        return false
    }
    
    private func keyCodeToNumber(_ keyCode: UInt16) -> Int? {
        // Key codes for numbers 1-9
        let numberKeyCodes: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
            22: 6, 26: 7, 28: 8, 25: 9
        ]
        return numberKeyCodes[keyCode]
    }
    
    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

@main
struct WorkspacesApp: App {
    @StateObject private var menuModel = WorkspaceMenuModel()

    var body: some Scene {
        MenuBarExtra("Workspaces", systemImage: "rectangle.grid.2x2") {
            Button("Save Workspace (⌘⌥⌃S)") {
                WorkspaceManager.promptAndSaveWorkspace {
                    menuModel.refresh()
                }
            }

            Divider()

            Menu("Restore Workspace") {
                if menuModel.savedWorkspaces.isEmpty {
                    Text("No saved workspaces")
                } else {
                    ForEach(Array(menuModel.savedWorkspaces.enumerated()), id: \.element) { index, name in
                        let shortcut = index < 9 ? " (⌘⌥⌃\(index + 1))" : ""
                        Button(name + shortcut) {
                            WorkspaceManager.restoreWorkspace(name: name, closeOthers: menuModel.closeOthersEnabled)
                        }
                    }
                }
            }
            .onAppear {
                menuModel.refresh()
                menuModel.setupKeyboardShortcuts()
            }
            
            Menu("Delete Workspace") {
                if menuModel.savedWorkspaces.isEmpty {
                    Text("No saved workspaces")
                } else {
                    ForEach(menuModel.savedWorkspaces, id: \.self) { name in
                        Button(name) {
                            menuModel.confirmAndDeleteWorkspace(name: name)
                        }
                    }
                }
            }

            Divider()
            
            Toggle("Close other apps when restoring", isOn: $menuModel.closeOthersEnabled)
            
            Divider()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
