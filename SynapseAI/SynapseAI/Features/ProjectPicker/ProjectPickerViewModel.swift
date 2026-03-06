//
//  ProjectPickerViewModel.swift
//  SynapseAI
//

import Foundation

@MainActor
final class ProjectPickerViewModel: ObservableObject {
    @Published var selectedPath: String?
}
