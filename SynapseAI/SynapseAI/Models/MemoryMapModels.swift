//
//  MemoryMapModels.swift
//  SynapseAI
//

import Foundation

enum MemoryMapNodeType: String, Codable {
    case file
    case chunk
}

struct MemoryMapNode: Identifiable {
    let id: String
    let path: String
    let type: MemoryMapNodeType
    /// For chunks: the document path this chunk belongs to.
    let documentPath: String?

    init(id: String, path: String, type: MemoryMapNodeType = .file, documentPath: String? = nil) {
        self.id = id
        self.path = path
        self.type = type
        self.documentPath = documentPath
    }

    /// Display label: for skill.md use folder name; otherwise last path component.
    var displayLabel: String {
        let name = (path as NSString).lastPathComponent
        if name.lowercased() == "skill.md" {
            let dir = (path as NSString).deletingLastPathComponent
            return (dir as NSString).lastPathComponent
        }
        return name
    }
}

struct MemoryMapConnection: Identifiable {
    var id: String { "\(fromId)-\(toId)-\(type)" }
    let fromId: String
    let toId: String
    let type: String
    let label: String
}
