import SwiftUI
import Combine

class WorkspaceMenuModel: ObservableObject {
    @Published var savedWorkspaces: [String] = []

    func refresh() {
        savedWorkspaces = WorkspaceManager.listSavedWorkspaces()
    }
}

@main
struct WorkspacesApp: App {
    @StateObject private var menuModel = WorkspaceMenuModel()

    var body: some Scene {
        MenuBarExtra("Workspaces", systemImage: "rectangle.grid.2x2") {
            Button("Save Workspace") {
                WorkspaceManager.promptAndSaveWorkspace()
                menuModel.refresh() // update list after saving
            }

            Button("Debug List Window Frames") {
                WorkspaceManager.debugListWindowFrames()
            }

            Divider()
            Button("List Running Apps") {
                print(WorkspaceManager.listRunningApps())
            }

            // Restore menu section
            Menu("Restore Workspace") {
                if menuModel.savedWorkspaces.isEmpty {
                    Text("No saved workspaces")
                } else {
                    ForEach(menuModel.savedWorkspaces, id: \.self) { name in
                        Button(name) {
                            WorkspaceManager.restoreWorkspace(name: name)
                        }
                    }
                }
            }
            .onAppear {
                menuModel.refresh()
            }

            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

