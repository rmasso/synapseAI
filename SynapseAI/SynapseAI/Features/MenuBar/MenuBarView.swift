//
//  MenuBarView.swift
//  SynapseAI
//

import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var nodeBridge: NodeBridgeService
    @EnvironmentObject var folderService: FolderService
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: viewModel.nodeConnected ? "network" : "exclamationmark.triangle")
                    .foregroundColor(viewModel.nodeConnected ? .green : .red)
                Text(viewModel.nodeConnected ? "Connected" : "Disconnected")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(spacing: 2) {
                Button {
                    openProject()
                } label: {
                    Label("New Project…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    if let existing = NSApp.windows.first(where: { $0.title == "Dashboard" }) {
                        existing.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "dashboard")
                    }
                } label: {
                    Label("Open Dashboard", systemImage: "macwindow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Button {
                    Task { @MainActor in
                        await SynapseAIApp.runInjection()
                    }
                } label: {
                    Label("Inject context (⌘⇧P)", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
                    .padding(.vertical, 4)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Synapse", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .padding(.vertical, 8)
        }
        .frame(width: 240)
        .onAppear {
            viewModel.refresh(from: nodeBridge)
        }
        .onChange(of: nodeBridge.isConnected) { _, _ in
            viewModel.refresh(from: nodeBridge)
        }
    }

    private func openProject() {
        guard let path = folderService.openProjectPicker() else { return }
        Task {
            _ = await nodeBridge.setProject(path)
        }
    }
}
