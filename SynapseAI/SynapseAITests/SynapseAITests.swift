//
//  SynapseAITests.swift
//  SynapseAITests
//

import Testing
@testable import SynapseAI

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
