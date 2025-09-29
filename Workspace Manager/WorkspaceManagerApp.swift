import SwiftUI

@main
struct WorkspacesApp: App {
    var body: some Scene {
        MenuBarExtra("Workspaces", systemImage: "rectangle.grid.2x2") {
            Button("Save Workspace") {
                WorkspaceManager.saveWorkspace(name: "MyWorkspace")
            }
            Button("Load Workspace") {
                WorkspaceManager.loadWorkspace(name: "MyWorkspace")
            }
            Divider()
            Button("List Running Apps") {
                print(WorkspaceManager.listRunningApps())
            }
            Button("List Saved Workspaces") {
                WorkspaceManager.listSavedWorkspaces()
            }
            Button("Restore Workspace") {
                WorkspaceManager.restoreWorkspace(name: "MyWorkspace")
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
