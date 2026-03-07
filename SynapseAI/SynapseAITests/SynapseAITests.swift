//
//  SynapseAITests.swift
//  SynapseAITests
//

import Testing
import SwiftUI
import AppKit
@testable import SynapseAI

@Suite("ProcessAnimationView")
struct ProcessAnimationTests {

    @Test("ProcessAnimationView renders for buildContext flow without crashing")
    @MainActor func buildContextRenders() {
        let view = ProcessAnimationView(isSubagent: false, isOptimizing: false)
        let hosting = NSHostingController(rootView: view)
        _ = hosting.view
        // Accessing view triggers layout; Path/connection rendering is exercised
    }

    @Test("ProcessAnimationView renders for subagent flow without crashing")
    @MainActor func subagentRenders() {
        let view = ProcessAnimationView(isSubagent: true, isOptimizing: false)
        let hosting = NSHostingController(rootView: view)
        _ = hosting.view
    }

    @Test("ProcessAnimationView renders for optimizePrompt flow without crashing")
    @MainActor func optimizePromptRenders() {
        let view = ProcessAnimationView(isSubagent: false, isOptimizing: true)
        let hosting = NSHostingController(rootView: view)
        _ = hosting.view
    }
}

@Suite("NodeBridgeService")
struct NodeBridgeTests {

    @Test("NodeBridgeService shared instance exists")
    func sharedExists() async {
        let service = await NodeBridgeService.shared
        #expect(service != nil)
    }

    @Test("Ping result matches connection state")
    func pingMatchesConnection() async throws {
        let service = await NodeBridgeService.shared
        let ok = await service.ping()
        // If node script not found, isConnected is false and ping fails
        #expect(ok == service.isConnected)
    }
}

@Suite("MemoryMapView")
struct MemoryMapTests {

    @Test("Layout produces positions for 5 nodes and 3 edges")
    func layoutRendersNodes() {
        let nodes = (1...5).map { MemoryMapNode(id: "n\($0)", path: "file\($0).md") }
        let connections = [
            MemoryMapConnection(fromId: "n1", toId: "n2", type: "reference", label: "references"),
            MemoryMapConnection(fromId: "n2", toId: "n3", type: "reference", label: "references"),
            MemoryMapConnection(fromId: "n3", toId: "n4", type: "dependency", label: "depends on"),
        ]
        let positions = MemoryMapLayout.run(nodes: nodes, connections: connections, iterations: 20)
        #expect(positions.count == 5)
        for node in nodes {
            #expect(positions[node.id] != nil)
            let p = positions[node.id]!
            #expect(p.x >= 0 && p.x <= 800)
            #expect(p.y >= 0 && p.y <= 800)
        }
    }

    @Test("Layout handles empty nodes")
    func layoutEmptyNodes() {
        let positions = MemoryMapLayout.run(nodes: [], connections: [], iterations: 10)
        #expect(positions.isEmpty)
    }

    @Test("Layout handles single node")
    func layoutSingleNode() {
        let nodes = [MemoryMapNode(id: "a", path: "a.md")]
        let positions = MemoryMapLayout.run(nodes: nodes, connections: [], iterations: 10)
        #expect(positions.count == 1)
        #expect(positions["a"] != nil)
    }

    @Test("MemoryMapConnection has stable id")
    func connectionIdStable() {
        let c = MemoryMapConnection(fromId: "a", toId: "b", type: "ref", label: "refs")
        #expect(c.id == "a-b-ref")
    }
}
