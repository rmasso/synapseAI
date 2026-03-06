//
//  MenuBarViewModel.swift
//  SynapseAI
//

import Foundation

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var statusText: String = "Checking..."
    @Published var nodeConnected: Bool = false

    func refresh(from nodeBridge: NodeBridgeService) {
        nodeConnected = nodeBridge.isConnected
        statusText = nodeBridge.isConnected ? "Status: Connected" : (nodeBridge.lastError ?? "Disconnected")
    }
}
