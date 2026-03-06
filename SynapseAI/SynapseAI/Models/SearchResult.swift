//
//  SearchResult.swift
//  SynapseAI
//

import Foundation

struct SearchResult: Identifiable {
    var id: String { "\(path)-\(startLine)-\(endLine)" }
    let path: String
    let startLine: Int
    let endLine: Int
    let content: String
}
