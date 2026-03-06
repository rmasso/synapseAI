//
//  SynapseProject.swift
//  SynapseAI
//
//  Persistent, codable model for a single Cursor workspace managed by Synapse.
//  Stored as a JSON array in UserDefaults under "synapse.projects".
//

import Foundation

struct SynapseProject: Identifiable, Codable, Equatable {
    let id: UUID
    /// Display name — last path component of the workspace root (e.g. "Synapse").
    var name: String
    /// Absolute path to the workspace root (e.g. "/Users/dev/Synapse").
    var path: String
    /// Security-scoped bookmark so the app can re-access the folder across launches.
    var bookmarkData: Data

    init(id: UUID = UUID(), name: String, path: String, bookmarkData: Data) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmarkData = bookmarkData
    }
}
