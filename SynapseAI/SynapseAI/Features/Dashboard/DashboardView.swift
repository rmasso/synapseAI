//
//  DashboardView.swift
//  SynapseAI
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Markdown text view (preview-optimized)

private struct MarkdownTextView: View {
    let text: String
    var font: Font = .body
    var lineSpacing: CGFloat = 4

    private static let markdownOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    var body: some View {
        Group {
            if let attr = try? AttributedString(markdown: text, options: Self.markdownOptions) {
                Text(attr)
            } else {
                Text(text)
            }
        }
        .font(font)
        .lineSpacing(lineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

// MARK: - Debug (filter console with "[MemoryMap]")
private func memoryMapTabLog(_ msg: String) {
    print("[MemoryMap] \(msg)")
}

// MARK: - DashboardView (TabView shell)

struct DashboardView: View {
    @EnvironmentObject var nodeBridge: NodeBridgeService
    @EnvironmentObject var folderService: FolderService
    @StateObject private var memoryMapCacheStore = MemoryMapCacheStore()
    @State private var selectedProjectId: UUID? = nil

    // Add-project sheet state (lives here so the + tab can show the sheet from DashboardView level)
    @State private var showAddProjectSheet = false
    @State private var addProjectSheetPath: String? = nil
    @State private var addProjectExtraFolderSuccess: String? = nil
    @State private var addProjectExtraFolderError: String? = nil
    @State private var addProjectIndexAll = true
    @State private var addProjectIndexComplete = false
    @State private var isIndexing = false
    @State private var isSelfSynapsing = false
    @State private var selfSynapseSuccess: String?
    @State private var selfSynapseError: String?
    @State private var addProjectMemoryPromptCopied = false
    @State private var showDeleteAlert = false
    @State private var projectToDelete: SynapseProject? = nil
    @State private var currentAddProjectStep = 1
    @AppStorage("synapse.onboardingCompleted") private var onboardingCompleted = false
    @AppStorage("synapse.grokApiKey") private var grokApiKey = ""

    var body: some View {
        VStack(spacing: 0) {
            customTabBar
            projectTabView
                .environmentObject(memoryMapCacheStore)
        }
        .frame(minWidth: 500, minHeight: 640)
        .onDisappear {
            NotificationCenter.default.post(name: NSNotification.Name("reopenDashboard"), object: nil)
        }
        .onAppear {
            selectedProjectId = folderService.activeProjectId
            memoryMapTabLog("Dashboard onAppear selectedId=\(selectedProjectId?.uuidString ?? "nil") activeId=\(folderService.activeProjectId?.uuidString ?? "nil") projectPath=\((folderService.projectPath as NSString?)?.lastPathComponent ?? "nil")")
            if folderService.projectPath != nil {
                Task { _ = await nodeBridge.setProject(folderService.projectPath) }
            }
        }
        .onChange(of: folderService.activeProjectId) { _, newId in
            if selectedProjectId != newId {
                selectedProjectId = newId
                memoryMapTabLog("Dashboard sync from folderService activeId=\(newId?.uuidString ?? "nil") → selectedId=\(selectedProjectId?.uuidString ?? "nil")")
            }
        }
        .sheet(isPresented: $showAddProjectSheet) {
            addProjectSheet
        }
        .alert("Delete Project?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                removeProjectToDelete()
            }
            Button("Cancel", role: .cancel) {
                projectToDelete = nil
                showDeleteAlert = false
            }
        } message: {
            Text(projectToDelete.map { "This will remove the project '\($0.name)' from Synapse. The .synapse folder and database remain on disk. This action cannot be undone." } ?? "")
        }
    }

    /// Single content per selected project. MemoryMapCacheStore persists map per path across tab switches.
    @ViewBuilder
    private var projectTabView: some View {
        Group {
            if folderService.projects.isEmpty {
                ProjectDashboardContent(project: nil, isTabSelected: true)
            } else {
                ProjectDashboardContent(
                    project: folderService.projects.first { $0.id == selectedProjectId } ?? folderService.projects.first!,
                    isTabSelected: true
                )
                .id(selectedProjectId?.uuidString ?? "none")
            }
        }
        .onChange(of: selectedProjectId) { oldId, newId in
            memoryMapTabLog("Tab change old=\(oldId?.uuidString ?? "nil") new=\(newId?.uuidString ?? "nil")")
            guard let newId,
                  let project = folderService.projects.first(where: { $0.id == newId }),
                  folderService.activeProjectId != newId else { return }
            memoryMapTabLog("Activating project name=\(project.name) path=\((project.path as NSString).lastPathComponent)")
            folderService.activateProject(project)
            Task { _ = await nodeBridge.setProject(project.path) }
        }
    }

    private func runSelfSynapseFromView() async {
        selfSynapseError = nil
        selfSynapseSuccess = nil
        isSelfSynapsing = true
        nodeBridge.clearSelfSynapseProgress()
        defer { isSelfSynapsing = false }
        switch await nodeBridge.selfSynapse(apiKey: grokApiKey) {
        case .success(let out):
            let count = out.filesUpdated.count
            selfSynapseSuccess = "Updated \(count) file\(count == 1 ? "" : "s")"
        case .failure(let err):
            selfSynapseError = err.localizedDescription
        }
    }

    private var customTabBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if folderService.projects.isEmpty {
                        tabPill(
                            title: "Synapse",
                            systemImage: "brain.head.profile",
                            isSelected: true,
                            showClose: false,
                            onSelect: {},
                            onClose: nil
                        )
                        tabPill(
                            title: "Add",
                            systemImage: "plus",
                            isSelected: false,
                            showClose: false,
                            onSelect: { showAddProjectSheet = true },
                            onClose: nil
                        )
                    } else {
                        ForEach(folderService.projects) { project in
                            let stale = folderService.isIndexStale(for: project.id)
                            tabPill(
                                title: project.name,
                                systemImage: stale ? "exclamationmark.triangle" : "folder",
                                isSelected: selectedProjectId == project.id,
                                showClose: true,
                                projectPath: project.path,
                                onSelect: { selectedProjectId = project.id },
                                onClose: {
                                    projectToDelete = project
                                    showDeleteAlert = true
                                }
                            )
                        }
                        tabPill(
                            title: "Add",
                            systemImage: "plus",
                            isSelected: false,
                            showClose: false,
                            onSelect: { showAddProjectSheet = true },
                            onClose: nil
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(Color(NSColor.windowBackgroundColor))
            Divider()
        }
    }

    @ViewBuilder
    private func tabPill(
        title: String,
        systemImage: String,
        isSelected: Bool,
        showClose: Bool,
        projectPath: String? = nil,
        onSelect: @escaping () -> Void,
        onClose: (() -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            if let path = projectPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if projectPath == nil {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, projectPath == nil ? 12 : 6)
                .padding(.trailing, showClose ? 6 : 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showClose, let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove project from Synapse")
            }
        }
        .padding(.horizontal, 8)
        .background(isSelected ? Color(NSColor.selectedContentBackgroundColor).opacity(0.8) : Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func removeProjectToDelete() {
        guard let p = projectToDelete else { return }
        folderService.removeProject(id: p.id)
        Task { _ = await nodeBridge.setProject(folderService.projectPath) }
        projectToDelete = nil
        showDeleteAlert = false
    }

    // MARK: - Add Project sheet (wizard-style, one step per screen)

    private var addProjectSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Project")
                        .font(.title.weight(.bold))
                    HStack(spacing: 8) {
                        Text("Step \(currentAddProjectStep) of 6")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        addProjectStepDots
                    }
                }
                Spacer()
                Button("Cancel") {
                    showAddProjectSheet = false
                    currentAddProjectStep = 1
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Step content (single screen at a time)
            ZStack {
                addProjectStepContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: currentAddProjectStep)

            Divider()

            // Footer navigation
            HStack {
                if currentAddProjectStep > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentAddProjectStep -= 1
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if currentAddProjectStep < 6 {
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentAddProjectStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentAddProjectStep == 1 && addProjectSheetPath == nil)
                } else {
                    AnimatedActionButton(action: {
                        onboardingCompleted = true
                        showAddProjectSheet = false
                        currentAddProjectStep = 1
                    }, delayAction: true) { isSuccess in
                        HStack(spacing: 6) {
                            if isSuccess {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .transition(.scale.combined(with: .opacity))
                            }
                            Text("Done")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 480)
        .onAppear { currentAddProjectStep = 1 }
    }

    private var addProjectStepDots: some View {
        HStack(spacing: 6) {
            ForEach(1...6, id: \.self) { step in
                Circle()
                    .fill(step == currentAddProjectStep ? Color.accentColor : (step < currentAddProjectStep ? Color.green.opacity(0.6) : Color.primary.opacity(0.15)))
                    .frame(width: 6, height: 6)
                    .scaleEffect(step == currentAddProjectStep ? 1.2 : 1)
            }
        }
    }

    @ViewBuilder
    private var addProjectStepContent: some View {
        switch currentAddProjectStep {
        case 1:
            addProjectWizardStep(
                icon: "folder.badge.gear",
                iconColor: .accentColor,
                title: "Select project folder",
                description: "Synapse creates a .synapse memory folder (projectbrief, activeContext, progress, thoughts, learnings, codebase). This becomes your project's searchable memory."
            ) {
                if let path = addProjectSheetPath {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((path as NSString).lastPathComponent)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("Project folder selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Change…") {
                            if let newPath = folderService.openProjectPicker() {
                                addProjectSheetPath = newPath
                                Task { _ = await nodeBridge.setProject(newPath) }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Button {
                        if let newPath = folderService.openProjectPicker() {
                            addProjectSheetPath = newPath
                            Task { _ = await nodeBridge.setProject(newPath) }
                        }
                    } label: {
                        Label("Select folder…", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))
        case 2:
            addProjectWizardStep(
                icon: "doc.text.magnifyingglass",
                iconColor: .blue,
                title: "Project Type",
                description: "Is this a code project or a markdown folder? Synapse can index your full code for deeper agent context, or just .md files for pure knowledge bases."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Project Type", selection: Binding(
                        get: { folderService.indexFullProject ? "code" : "md" },
                        set: { _ = folderService.setIndexFullProject($0 == "code") }
                    )) {
                        Text("Code Project (Full Index)").tag("code")
                        Text("Knowledge Base (.md only)").tag("md")
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .padding(16)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))
        case 3:
            addProjectWizardStep(
                icon: "folder.badge.plus",
                iconColor: .purple,
                title: "Add skills folder",
                description: "Optional: index another folder (e.g. .Cursor) so its .md skills and knowledge files are searchable. Run Index All after adding."
            ) {
                VStack(spacing: 12) {
                    if let rel = folderService.additionalIndexFolderPath {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                            Text(rel)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") {
                                folderService.writeAdditionalIndexFolder(nil)
                                addProjectExtraFolderSuccess = nil
                            }
                            .foregroundStyle(.red)
                            .buttonStyle(.bordered)
                        }
                        .padding(16)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Button {
                            addProjectExtraFolderError = nil
                            addProjectExtraFolderSuccess = nil
                            if let rel = folderService.openAdditionalIndexFolderPicker() {
                                addProjectExtraFolderSuccess = "Added: \(rel)"
                            } else if folderService.projectPath != nil {
                                addProjectExtraFolderError = "Folder must be inside the project folder."
                            }
                        } label: {
                            Label("Select folder…", systemImage: "folder.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(addProjectSheetPath == nil && folderService.projectPath == nil)
                        Text("Optional")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let msg = addProjectExtraFolderSuccess {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let err = addProjectExtraFolderError {
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))
        case 4:
            addProjectWizardStep(
                icon: "magnifyingglass",
                iconColor: .orange,
                title: "Index your memory",
                description: "Build the search index from your project. You must run this before using Self Synapse."
            ) {
                HStack(spacing: 16) {
                    Button {
                        Task {
                            isIndexing = true
                            _ = await nodeBridge.indexAll()
                            if let pid = folderService.activeProjectId { folderService.recordIndexTime(for: pid) }
                            if let path = folderService.projectPath {
                                NotificationCenter.default.post(name: .indexAllCompleted, object: path)
                            }
                            addProjectIndexComplete = true
                            isIndexing = false
                        }
                    } label: {
                        Label("Index All", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(addProjectSheetPath == nil || isIndexing)
                    if isIndexing {
                        ProgressView()
                            .scaleEffect(0.9)
                    }
                    if addProjectIndexComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))
        case 5:
            addProjectWizardStep(
                icon: "brain",
                iconColor: .indigo,
                title: "Self Synapse (Optional)",
                description: "Let Grok automatically read your indexed files and write your initial project memory. Requires an API key and a built index."
            ) {
                VStack(spacing: 16) {
                    if grokApiKey.isEmpty {
                        SecureField("Paste Grok API key…", text: $grokApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                    }
                    HStack(spacing: 12) {
                        Button("Run Self Synapse") {
                            Task { await runSelfSynapseFromView() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isSelfSynapsing || addProjectSheetPath == nil || grokApiKey.isEmpty || !addProjectIndexComplete)
                        if isSelfSynapsing {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text(nodeBridge.selfSynapseProgress ?? "Preparing...")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .contentTransition(.numericText())
                                    .animation(.easeInOut(duration: 0.2), value: nodeBridge.selfSynapseProgress)
                            }
                        }
                    }
                    if let msg = selfSynapseSuccess {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    if let err = selfSynapseError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))
        case 6:
            addProjectWizardStep(
                icon: "doc.on.clipboard",
                iconColor: .blue,
                title: "Remind Cursor to update memory",
                description: "Paste this into Cursor so the agent knows to refresh your memory files after setup."
            ) {
                HStack(spacing: 12) {
                    Text("Update my .synapse memory folder (projectbrief, activeContext, progress, codebase).")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("Update my .synapse memory folder (projectbrief, activeContext, progress, codebase).", forType: .string)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            addProjectMemoryPromptCopied = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            addProjectMemoryPromptCopied = false
                        }
                    } label: {
                        Image(systemName: addProjectMemoryPromptCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.title2)
                            .foregroundStyle(addProjectMemoryPromptCopied ? .green : .secondary)
                            .scaleEffect(addProjectMemoryPromptCopied ? 1.15 : 1)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func addProjectWizardStep<A: View>(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        @ViewBuilder content: () -> A
    ) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            .padding(.top, 32)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
                .padding(.top, 8)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 24)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SplitHalfButtonStyle

private struct SplitHalfButtonStyle: ButtonStyle {
    let isDisabled: Bool
    let isLeft: Bool
    
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Rectangle()
                    .fill(Color.white.opacity(
                        isDisabled ? 0 : (configuration.isPressed ? 0.2 : (isHovered ? 0.1 : 0))
                    ))
                    // When disabled, use a slightly darker hover state on the light background
                    .overlay(
                        Rectangle()
                            .fill(Color.black.opacity(
                                isDisabled && isHovered && !configuration.isPressed ? 0.05 : 0
                            ))
                    )
            )
            .clipShape(
                .rect(
                    topLeadingRadius: isLeft ? 18 : 0,
                    bottomLeadingRadius: isLeft ? 18 : 0,
                    bottomTrailingRadius: isLeft ? 0 : 18,
                    topTrailingRadius: isLeft ? 0 : 18
                )
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - SendMenuItemView

private struct SendMenuItemView: View {
    let mode: SendMenuMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .frame(width: 24, alignment: .center)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text(mode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer(minLength: 8)
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color(NSColor.selectedControlColor).opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - SendMenuMode

private enum SendMenuMode: String, CaseIterable {
    case prompt
    case subagent
    case chat

    var iconName: String {
        switch self {
        case .prompt: return "paperplane.fill"
        case .subagent: return "person.2.fill"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    var title: String {
        switch self {
        case .prompt: return "Prompt"
        case .subagent: return "Subagent"
        case .chat: return "Chat"
        }
    }

    var subtitle: String {
        switch self {
        case .prompt: return "Skill-format prompt for Cursor"
        case .subagent: return "Memory-heavy package for parallel agent"
        case .chat: return "Natural chat — Grok can search your project"
        }
    }

    var helpText: String {
        switch self {
        case .prompt: return "Send — skill-format prompt for Cursor"
        case .subagent: return "Subagent context — memory-heavy package for parallel agent"
        case .chat: return "Chat — natural conversation; Grok can search files and memory"
        }
    }

    /// Next mode when cycling (prompt → subagent → chat → prompt).
    var next: SendMenuMode {
        let all = Self.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

// MARK: - ProjectDashboardContent

/// Full per-project dashboard content. Each tab gets its own instance with an isolated DashboardViewModel.
private struct ProjectDashboardContent: View {
    /// The project this content represents. nil = no project selected (onboarding state).
    let project: SynapseProject?
    /// True when this tab is the selected one (visible in ZStack). Used for debug logging.
    var isTabSelected: Bool = true

    @EnvironmentObject var nodeBridge: NodeBridgeService
    @EnvironmentObject var folderService: FolderService
    @EnvironmentObject var memoryMapCacheStore: MemoryMapCacheStore
    @StateObject private var viewModel = DashboardViewModel()
    @AppStorage("synapse.grokApiKey") private var grokApiKey = ""
    @State private var isSettingsExpanded = false
    @State private var isHowItWorksExpanded = false
    @State private var isCursorInstructionsExpanded = false
    @State private var isConnectionDebugExpanded = false
    @State private var isMemoryAndThoughtsExpanded = false
    @State private var isLearningsExpanded = false
    @State private var isGrokApiExpanded = false
    @State private var showOnboardingSheet = false
    @State private var fullscreenMessage: ChatMessage? = nil
    @State private var isPromptCopied = false
    @State private var showMemoryMap = false
    @AppStorage("synapse.showMemoryMapInChat") private var showMemoryMapInChat = false
    /// Tick updated every 60 s so `isStale` re-evaluates without any user interaction.
    @State private var now = Date()
    /// Send bar: selected mode (prompt / subagent / chat) and whether the mode menu is open.
    @State private var sendMenuMode: SendMenuMode = .prompt
    @State private var sendMenuPresented = false

    private static let cursorInstructionsPrompt = """
        This project uses a .synapse memory folder. Use it to keep and share context across sessions.

        - .synapse/projectbrief.md — Goals, scope, key requirements. Read at start; update when scope changes.
        - .synapse/activeContext.md — Current focus, key decisions, open questions. Update as you work.
        - .synapse/progress.md — What's done, what's next, phases. Update after meaningful progress.
        - .synapse/thoughts.md — Append-only internal log. Append brief notes when useful.
        - .synapse/learnings.md — Per-project learnings (conventions, decisions, gotchas). Use Dashboard "Update learnings" to append from memory.
        - .synapse/codebase.md — Code map (key files, symbols, UI controls). Index for accurate skill prompts; keep concise.

        When starting or continuing work: read these files first, then update them so the next session (and Synapse ⌘⇧P injection) has up-to-date context. Keep entries concise.
        """

    var body: some View {
        VStack(spacing: 0) {
            compactStatusBar
            if isStale {
                staleBanner
            }
            Divider()
            chatArea
            Divider()
            promptInputBar
            settingsToggleBar
            if isSettingsExpanded {
                Divider()
                settingsForm
            }
        }
        .onAppear {
            if let p = project {
                memoryMapTabLog("ProjectDashboardContent onAppear project=\(p.name) path=\((p.path as NSString).lastPathComponent) isTabSelected=\(isTabSelected) activeId=\(folderService.activeProjectId?.uuidString ?? "nil")")
            }
            viewModel.clearChatHistory()
            viewModel.refresh(from: nodeBridge)
            viewModel.refreshFolderContent(folderService: folderService)
            Task {
                await SynapseAIApp.restoreProjectInNodeIfNeeded()
                await viewModel.refreshStats(nodeBridge: nodeBridge)
            }
        }
        // Re-fresh when this tab's project is activated (user switches to this tab).
        .onChange(of: folderService.activeProjectId) { _, newActiveId in
            guard let project, newActiveId == project.id else { return }
            memoryMapTabLog("ProjectDashboardContent ACTIVATED project=\(project.name) path=\((project.path as NSString).lastPathComponent)")
            viewModel.clearChatHistory()
            viewModel.refresh(from: nodeBridge)
            viewModel.refreshFolderContent(folderService: folderService)
            Task { await viewModel.refreshStats(nodeBridge: nodeBridge) }
        }
        .onChange(of: nodeBridge.isConnected) { _, connected in
            viewModel.refresh(from: nodeBridge)
            if connected {
                Task {
                    await SynapseAIApp.restoreProjectInNodeIfNeeded()
                    await viewModel.refreshStats(nodeBridge: nodeBridge)
                }
            }
        }
        .onChange(of: nodeBridge.lastFileChange) { _, _ in
            viewModel.refreshFolderContent(folderService: folderService)
            viewModel.lastInjectionDate = nodeBridge.lastInjectionDate
        }
        .onChange(of: nodeBridge.lastInjectionDate) { _, _ in
            viewModel.lastInjectionDate = nodeBridge.lastInjectionDate
        }
        .sheet(isPresented: $showOnboardingSheet) {
            onboardingSheet
        }
        .sheet(isPresented: $showMemoryMap) {
            MemoryMapView(viewModel: viewModel, projectPath: project?.path)
                .environmentObject(nodeBridge)
                .environmentObject(folderService)
                .environmentObject(memoryMapCacheStore)
        }
        .sheet(item: $fullscreenMessage) { msg in
            FullscreenMessageSheet(message: msg)
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
        .onReceive(NotificationCenter.default.publisher(for: .cycleSendMode)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                sendMenuMode = sendMenuMode.next
            }
        }
        .overlay {
            if sendMenuPresented {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7, blendDuration: 0)) {
                                sendMenuPresented = false
                            }
                        }
                        .ignoresSafeArea()
                    sendMenuPopupContent
                        .padding(.trailing, 18)
                        .padding(.bottom, 55)
                }
            }
        }
    }

    // MARK: - Stale index warning

    private func chunkCountColor(_ delta: Int?) -> Color {
        guard let d = delta else { return Color.primary.opacity(0.55) }
        if d > 0 { return .green }
        if d < 0 { return .red }
        return Color.primary.opacity(0.55)
    }

    private var isStale: Bool {
        _ = now  // force re-evaluation when timer ticks
        guard let pid = project?.id else { return false }
        return folderService.isIndexStale(for: pid)
    }

    private var staleBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Memory may be stale — update your .synapse files before querying.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Index Now") {
                    Task { await viewModel.indexAll(nodeBridge: nodeBridge, folderService: folderService, projectId: project?.id) }
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                Text("Ask your AI: \"Update my .synapse memory folder (projectbrief, activeContext, progress, codebase).\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    let prompt = "Update my .synapse memory folder (projectbrief, activeContext, progress, codebase)."
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                        isPromptCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            isPromptCopied = false
                        }
                    }
                } label: {
                    Image(systemName: isPromptCopied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline)
                        .foregroundStyle(isPromptCopied ? .green : .secondary)
                        .scaleEffect(isPromptCopied ? 1.1 : 1.0)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Status bar

    private var compactStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.nodeConnected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            if let path = folderService.projectPath {
                Text((path as NSString).lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("No project")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if viewModel.isIndexing {
                Text("·")
                    .foregroundStyle(.tertiary)
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("Indexing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let stats = viewModel.dbStats {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(stats.chunkCount) chunks · \(formatByteCount(stats.dbSizeBytes))")
                    .font(.caption)
                    .foregroundStyle(chunkCountColor(viewModel.chunkCountDelta))
                    .animation(.easeInOut(duration: 0.35), value: viewModel.chunkCountDelta)
            }
            Text("·")
                .foregroundStyle(.tertiary)
            if let lastTime = folderService.lastIndexTime(for: project?.id) {
                Text("Last indexed: \(formattedDate(from: lastTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not indexed yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if folderService.projectPath == nil {
                Button("Set up…") { showOnboardingSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.accentColor)
            }
            Button("Index All") {
                Task { await viewModel.indexAll(nodeBridge: nodeBridge, folderService: folderService, projectId: project?.id) }
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .help({
                if let pid = project?.id, folderService.isIndexStale(for: pid) {
                    return "Stale index — last updated over 20 minutes ago"
                }
                return "Re-index all .synapse and extra folder files"
            }())
            if let count = viewModel.indexCount {
                Text("\(count) indexed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Chat area

    private var chatArea: some View {
        ZStack(alignment: .topTrailing) {
            if viewModel.isBuildingContext || viewModel.isBuildingSubagentContext || viewModel.isBuildingChat || viewModel.isOptimizingPrompt {
                // Large centered loading animation (project-specific memory map when available)
                VStack {
                    Spacer()
                    ProcessAnimationView(
                        isSubagent: viewModel.isBuildingSubagentContext,
                        isChat: viewModel.isBuildingChat,
                        isOptimizing: viewModel.isOptimizingPrompt,
                        memoryMapCache: viewModel.memoryMapCache,
                        projectPath: folderService.projectPath
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                Group {
                    if viewModel.chatMessages.isEmpty, showMemoryMapInChat, project?.path != nil {
                        MemoryMapView(viewModel: viewModel, embedInChat: true, projectPath: project?.path, isTabSelected: isTabSelected)
                            .environmentObject(nodeBridge)
                            .environmentObject(folderService)
                            .environmentObject(memoryMapCacheStore)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if viewModel.chatMessages.isEmpty {
                                        chatEmptyState
                                    }
                                    ForEach(viewModel.chatMessages) { msg in
                                        chatMessageView(msg)
                                    }
                                    Color.clear.frame(height: 1).id("chatBottom")
                                }
                                .padding(.vertical, 12)
                                .padding(.top, viewModel.chatMessages.isEmpty ? 0 : 28)
                            }
                            .onChange(of: viewModel.chatMessages.count) { _, _ in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("chatBottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .transition(.opacity)

                if !viewModel.chatMessages.isEmpty {
                    AnimatedActionButton(action: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.clearChatHistory()
                        }
                    }) { isSuccess in
                        Label(isSuccess ? "Cleared" : "Clear", systemImage: isSuccess ? "checkmark" : "trash")
                            .font(.caption)
                            .foregroundStyle(isSuccess ? .green : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .padding(.trailing, 14)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.isBuildingContext || viewModel.isBuildingSubagentContext || viewModel.isBuildingChat || viewModel.isOptimizingPrompt)
    }

    private var chatEmptyState: some View {
        VStack(spacing: 12) {
            if folderService.projectPath == nil {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No project selected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Set up your project to start using Synapse memory injection.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button("Set up project…") { showOnboardingSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 4)
            } else {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
                
                Text("Ask about your project")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "paperplane.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Generate Skill Prompt")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Creates a focused, actionable directive for Cursor to execute a specific task.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "person.2.fill")
                            .font(.title2)
                            .foregroundStyle(Color.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Subagent Context")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Builds a memory-heavy knowledge package to spin up a new parallel agent.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.title2)
                            .foregroundStyle(Color.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chat")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Natural conversation about your project; Grok can search files and memory as needed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .font(.title2)
                            .foregroundStyle(Color.purple)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Refine Prompt")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Press **Shift+Return** to have a senior engineer AI sharpen your prompt first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func chatMessageView(_ msg: ChatMessage) -> some View {
        switch msg.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                MarkdownTextView(text: msg.text, font: .body, lineSpacing: 4)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 14)

        case .hit(let path, let startLine, let endLine):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\((path as NSString).lastPathComponent)  ·  L\(startLine)–\(endLine)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    AnimatedCopyButton(textToCopy: msg.text, style: .iconOnly)
                        .help("Copy chunk")
                    Button { fullscreenMessage = msg } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("View full content")
                }
                MarkdownTextView(text: msg.text, font: .caption, lineSpacing: 4)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14)

        case .block(let count, let total, let savedTokens, let inputTokens, let outputTokens):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skill prompt · \(count) of \(total) chunk\(total == 1 ? "" : "s") selected · copied to clipboard")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                        HStack(spacing: 8) {
                            if inputTokens > 0 || outputTokens > 0 {
                                Text("\(formattedTokens(inputTokens)) in / \(formattedTokens(outputTokens)) out")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if savedTokens > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption2)
                                    Text("~\(formattedTokens(savedTokens)) tokens saved vs. full context")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    Spacer()
                    Button { fullscreenMessage = msg } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("View full content")
                    AnimatedCopyButton(textToCopy: msg.text, style: .prominent(nil))
                }
                MarkdownTextView(text: msg.text, font: .caption2, lineSpacing: 4)
                    .foregroundStyle(.secondary)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 14)

        case .assistant(let inputTokens, let outputTokens):
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(Color.blue)
                            .font(.caption)
                        Text("\(formattedTokens(inputTokens)) in / \(formattedTokens(outputTokens)) out")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { fullscreenMessage = msg } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("View full content")
                        AnimatedCopyButton(textToCopy: msg.text, style: .prominent(.blue))
                    }
                    MarkdownTextView(text: msg.text, font: .body, lineSpacing: 6)
                        .foregroundStyle(.primary)
                }
                .padding(12)
                .background(Color.blue.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.25), lineWidth: 1))
                Spacer(minLength: 80)
            }
            .padding(.horizontal, 14)

        case .subagentContext(let inputTokens, let outputTokens):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(Color.orange)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Subagent context · copied to clipboard")
                            .font(.caption.bold())
                            .foregroundStyle(Color.orange)
                        Text("\(formattedTokens(inputTokens)) in / \(formattedTokens(outputTokens)) out")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { fullscreenMessage = msg } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("View full content")
                    AnimatedCopyButton(textToCopy: msg.text, style: .prominent(.orange))
                }
                MarkdownTextView(text: msg.text, font: .caption2, lineSpacing: 4)
                    .foregroundStyle(.secondary)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.orange.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 14)

        case .optimized(let inputTokens, let outputTokens):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(Color.purple)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prompt refined · prompt field updated")
                            .font(.caption.bold())
                            .foregroundStyle(Color.purple)
                        Text("\(formattedTokens(inputTokens)) in / \(formattedTokens(outputTokens)) out")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { copyText(msg.text) } label: {
                        Label("Copy", systemImage: "doc.on.clipboard.fill").font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.purple)
                }
                MarkdownTextView(text: msg.text, font: .caption2, lineSpacing: 4)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.purple.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 14)

        case .error:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(msg.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(.horizontal, 14)
        }
    }

    // MARK: - Prompt input bar

    private var promptInputBar: some View {
        VStack(spacing: 6) {
            if !nodeBridge.lastInjectedBlock.isEmpty, let target = nodeBridge.lastTargetApp {
                HStack(spacing: 6) {
                    Spacer()
                    AnimatedActionButton(action: {
                        AccessibilityService.shared.pasteIntoApp(
                            text: nodeBridge.lastInjectedBlock,
                            targetPid: target.pid
                        )
                        nodeBridge.setLastInjectionDate(Date())
                    }) { isSuccess in
                        Label(isSuccess ? "Pasted" : "Paste into \(target.name)", systemImage: isSuccess ? "checkmark" : "arrow.up.forward.app.fill")
                            .font(.caption.weight(.medium))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.accentColor)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if viewModel.promptForContext.isEmpty {
                        Text("Ask about your project…")
                            .font(.body)
                            .foregroundStyle(Color(NSColor.placeholderTextColor))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.promptForContext)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 120)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .onKeyPress(keys: [.return]) { press in
                            guard press.modifiers.contains(.shift) else { return .ignored }
                            let prompt = viewModel.promptForContext.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !prompt.isEmpty,
                                  !viewModel.isBuildingContext,
                                  !viewModel.isBuildingSubagentContext,
                                  !viewModel.isBuildingChat,
                                  !viewModel.isOptimizingPrompt else { return .handled }
                            runSendAction(for: sendMenuMode)
                            return .handled
                        }
                }
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                sendButtonWithMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Send button with upward menu

    private var sendButtonWithMenu: some View {
        let isDisabled = viewModel.isBuildingContext ||
            viewModel.isBuildingSubagentContext ||
            viewModel.isBuildingChat ||
            viewModel.isOptimizingPrompt ||
            viewModel.promptForContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        let bgColor = isDisabled ? Color(NSColor.controlBackgroundColor) : modeColor
        let fgColor = isDisabled ? Color.secondary : Color.white
        let dividerColor = isDisabled ? Color.secondary.opacity(0.2) : Color.white.opacity(0.3)
        
        return ZStack(alignment: .bottomTrailing) {
            // The actual button
            HStack(spacing: 0) {
                Button {
                    runSendAction(for: sendMenuMode)
                } label: {
                    Image(systemName: sendButtonIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(fgColor)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SplitHalfButtonStyle(isDisabled: isDisabled, isLeft: true))
                .help(sendMenuMode.helpText)
                .disabled(isDisabled)

                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 20)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7, blendDuration: 0)) {
                        sendMenuPresented.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(fgColor)
                        .rotationEffect(.degrees(sendMenuPresented ? 180 : 0))
                        .frame(width: 26, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SplitHalfButtonStyle(isDisabled: false, isLeft: false))
                .help("Choose send mode: Prompt, Subagent, or Chat")
            }
            .background(
                Capsule()
                    .fill(bgColor)
                    .shadow(color: isDisabled ? Color.clear : bgColor.opacity(0.3), radius: 4, x: 0, y: 2)
            )
            .overlay(
                Capsule()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: isDisabled ? 1 : 0)
            )
            .animation(.easeInOut(duration: 0.2), value: isDisabled)
            .animation(.easeInOut(duration: 0.2), value: sendMenuMode)
            .padding(.trailing, 2)
            
        }
        .padding(.leading, 2)
    }

    private var sendMenuPopupContent: some View {
        VStack(spacing: 4) {
            ForEach(SendMenuMode.allCases, id: \.rawValue) { mode in
                SendMenuItemView(
                    mode: mode,
                    isSelected: mode == sendMenuMode
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7, blendDuration: 0)) {
                        sendMenuMode = mode
                        sendMenuPresented = false
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        )
        .frame(width: 240)
    }

    private func runSendAction(for mode: SendMenuMode) {
        switch mode {
        case .prompt:
            Task { await viewModel.buildContextForPrompt(apiKey: grokApiKey, nodeBridge: nodeBridge) }
        case .subagent:
            Task { await viewModel.buildSubagentContext(apiKey: grokApiKey, nodeBridge: nodeBridge) }
        case .chat:
            Task { await viewModel.sendChatMessage(apiKey: grokApiKey, nodeBridge: nodeBridge) }
        }
    }

    private var sendButtonIcon: String {
        if viewModel.isBuildingContext && sendMenuMode == .prompt { return "ellipsis.circle" }
        if viewModel.isBuildingSubagentContext && sendMenuMode == .subagent { return "ellipsis.circle" }
        if viewModel.isBuildingChat && sendMenuMode == .chat { return "ellipsis.circle" }
        return sendMenuMode.iconName
    }

    private var modeColor: Color {
        switch sendMenuMode {
        case .prompt: return Color.accentColor
        case .subagent: return Color.orange
        case .chat: return Color.blue
        }
    }

    // MARK: - Settings toggle bar

    private var settingsToggleBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSettingsExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSettingsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Tools & Settings")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let date = viewModel.lastInjectionDate {
                    Text("Last ⌘⇧P: \(date, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !viewModel.nodeConnected {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Settings form

    private var settingsForm: some View {
        Form {
            Section("Status & Project") {
                HStack(spacing: 8) {
                    Label(
                        viewModel.nodeConnected ? "Connected" : (nodeBridge.lastError ?? "Disconnected"),
                        systemImage: viewModel.nodeConnected ? "network" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(viewModel.nodeConnected ? .green : .red)
                    .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Ping") { Task { await viewModel.ping(nodeBridge: nodeBridge) } }
                        .buttonStyle(.borderless).font(.caption)
                }
                if !viewModel.nodeConnected {
                    Button("Locate node/index.js…") { locateNodeScript() }
                        .buttonStyle(.borderless)
                    if nodeBridge.debugScriptPath != nil || nodeBridge.debugNodePath != nil || nodeBridge.debugRunError != nil {
                        DisclosureGroup("Debug info", isExpanded: $isConnectionDebugExpanded) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let p = nodeBridge.debugScriptPath {
                                    Text("Script: \(p)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2).truncationMode(.middle)
                                }
                                if let p = nodeBridge.debugNodePath {
                                    Text("Node: \(p)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2).truncationMode(.middle)
                                }
                                if let e = nodeBridge.debugRunError {
                                    Text("Error: \(e)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.red)
                                        .lineLimit(4)
                                }
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                        }
                    }
                }
                if viewModel.isIndexing {
                    HStack {
                        Label("Memory", systemImage: "internaldrive")
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Indexing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let stats = viewModel.dbStats {
                    HStack {
                        Label("Memory", systemImage: "internaldrive")
                        Spacer()
                        Text("\(stats.documentCount) docs · \(stats.chunkCount) chunks · \(formatByteCount(stats.dbSizeBytes))")
                            .font(.caption)
                            .foregroundStyle(chunkCountColor(viewModel.chunkCountDelta))
                            .animation(.easeInOut(duration: 0.35), value: viewModel.chunkCountDelta)
                    }
                }
                if let date = viewModel.lastInjectionDate {
                    HStack {
                        Label("Last ⌘⇧P", systemImage: "arrow.right.doc.on.clipboard")
                        Spacer()
                        Text("\(date, style: .relative) ago")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Ingest .md files") {
                ZStack {
                    dropZoneContent
                    if viewModel.isIngesting {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                VStack(spacing: 8) {
                                    ProgressView().scaleEffect(1.2)
                                    Text("Indexing…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 70)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isIngesting)
                .animation(.easeInOut(duration: 0.15), value: viewModel.isDropTargeted)

                if let err = viewModel.ingestError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if let msg = viewModel.ingestSuccessMessage {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if let last = viewModel.lastIngestedFile {
                    Text("Last: \((last as NSString).lastPathComponent)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Section("Full-project index") {
                Toggle("Index full project", isOn: Binding(
                    get: { folderService.indexFullProject },
                    set: { newValue in
                        _ = folderService.setIndexFullProject(newValue)
                        if newValue {
                            Task {
                                await viewModel.indexAll(nodeBridge: nodeBridge, folderService: folderService, projectId: project?.id)
                            }
                        }
                    }
                ))
                .font(.subheadline.weight(.medium))
                if folderService.indexFullProject {
                    Text("Full-project indexing includes all source files (Swift, JS, etc.) and can take several seconds and increase database size (e.g. 2–4 MB for small repos; more for large ones).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("When on, Index All runs automatically and indexes source files by extension (.swift, .js, .ts, .json, .md) outside .synapse. Configure in .synapse/config.json: indexFullProject, indexExtensions, indexDirs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Additional index folder") {
                Text("Add a folder (e.g. .Cursor) so its .md files are indexed with .synapse. Run Index All after changing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Label(folderService.additionalIndexFolderPath ?? "None", systemImage: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(folderService.additionalIndexFolderPath != nil ? .primary : .tertiary)
                    Spacer()
                    Button("Select folder…") {
                        viewModel.selectAdditionalFolder(folderService: folderService)
                    }
                    .disabled(folderService.projectPath == nil)
                    if folderService.additionalIndexFolderPath != nil {
                        AnimatedActionButton(action: {
                            viewModel.clearAdditionalFolder(folderService: folderService)
                        }) { isSuccess in
                            HStack(spacing: 4) {
                                if isSuccess { Image(systemName: "checkmark") }
                                Text(isSuccess ? "Cleared" : "Clear")
                            }
                        }
                        .foregroundStyle(.red)
                    }
                }
                if let msg = viewModel.extraFolderSuccess {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if let err = viewModel.extraFolderError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if viewModel.suggestSkillOnNoTags {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No tags found in additional folder. Generate a skill.md?", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Generate Skill") {
                            Task { await viewModel.suggestSkill(apiKey: grokApiKey, nodeBridge: nodeBridge) }
                        }
                        .font(.caption)
                        .disabled(grokApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 2)
                }
            }

            if !viewModel.memoryFiles.isEmpty || !viewModel.thoughtsPreview.isEmpty {
                DisclosureGroup(isExpanded: $isMemoryAndThoughtsExpanded) {
                    if !viewModel.memoryFiles.isEmpty {
                        ForEach(viewModel.memoryFiles.prefix(5), id: \.name) { f in
                            HStack {
                                Image(systemName: "doc.text")
                                Text(f.name)
                                Spacer()
                                Text("\(f.modified, style: .relative) ago")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !viewModel.thoughtsPreview.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                Text(viewModel.thoughtsPreview)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("thoughtsBottom")
                            }
                            .frame(maxHeight: 140)
                            .onChange(of: viewModel.thoughtsPreview) { _, _ in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("thoughtsBottom", anchor: .bottom)
                                }
                            }
                            .onAppear {
                                proxy.scrollTo("thoughtsBottom", anchor: .bottom)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Memory & Thoughts").font(.subheadline.weight(.medium))
                        if !viewModel.memoryFiles.isEmpty {
                            Text("\(viewModel.memoryFiles.count) files")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section("Learnings") {
                Text("Extract learnings from project memory (projectbrief, activeContext, progress, thoughts) and append to learnings.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Update learnings") {
                        Task { await viewModel.updateLearnings(apiKey: grokApiKey, nodeBridge: nodeBridge, folderService: folderService) }
                    }
                    .disabled(viewModel.isUpdatingLearnings)
                    if viewModel.isUpdatingLearnings { ProgressView().scaleEffect(0.7) }
                    if let msg = viewModel.learningsSuccess {
                        Text(msg).font(.caption).foregroundStyle(.green)
                    }
                    if let err = viewModel.learningsError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
                if !viewModel.learningsPreview.isEmpty {
                    DisclosureGroup("Preview", isExpanded: $isLearningsExpanded) {
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(viewModel.learningsPreview)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(maxHeight: 120)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
            }

            Section("Self Synapse") {
                Text("Send project context to Grok and fill out .synapse memory files. Works for code, design, docs, or any indexed folder. May take 30s–2min for large folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Self Synapse") {
                            Task { await viewModel.runSelfSynapse(apiKey: grokApiKey, nodeBridge: nodeBridge, folderService: folderService) }
                        }
                        .disabled(viewModel.isSelfSynapsing || folderService.projectPath == nil || grokApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let msg = viewModel.selfSynapseSuccess {
                            Text(msg).font(.caption).foregroundStyle(.green)
                        }
                        if let err = viewModel.selfSynapseError {
                            Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    if viewModel.isSelfSynapsing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                            Text(nodeBridge.selfSynapseProgress ?? "Preparing...")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.2), value: nodeBridge.selfSynapseProgress)
                        }
                        .padding(.top, 2)
                        .padding(.leading, 2)
                    }
                }
            }

            Section("Context Settings") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Max Chunks for Context", systemImage: "square.stack.3d.up")
                        Spacer()
                        Text("\(viewModel.maxChunksForPrompt)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.maxChunksForPrompt) },
                            set: { viewModel.maxChunksForPrompt = Int($0.rounded()) }
                        ),
                        in: 1...10,
                        step: 1
                    )
                    Text("Limits how many indexed chunks Grok can select per prompt. Lower = faster & cheaper; higher = broader context. Each chunk ≈ 300 tokens.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button {
                        showMemoryMap = true
                    } label: {
                        Label("Memory Map", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(.borderless)
                    Toggle("Show memory map in chat when empty", isOn: $showMemoryMapInChat)
                        .font(.caption)
                }
            }

            Section("Context Optimization") {
                Text("Token estimation: skill prompt and subagent bubbles show pre/post Grok token counts (X in / Y out). Adjust max chunks and memory-first mode to minimize context window usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Memory-First Mode", isOn: $viewModel.memoryFirstMode)
                    .font(.caption)
                Text("When enabled, prioritizes memory snippets (.synapse/) in chunk selection for skill prompts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Grok Skill Generator") {
                HStack {
                    Button("Suggest Skill") {
                        Task { await viewModel.suggestSkill(apiKey: grokApiKey, nodeBridge: nodeBridge) }
                    }
                    if let skill = viewModel.lastSkillCreated {
                        Text("Created: \(skill)").foregroundStyle(.green)
                    }
                    if let err = viewModel.skillError {
                        Text(err).foregroundStyle(.red).lineLimit(2)
                    }
                }
                DisclosureGroup("API key & token usage", isExpanded: $isGrokApiExpanded) {
                    SecureField("Grok API key", text: $grokApiKey)
                        .textFieldStyle(.roundedBorder)
                    Text("Tokens: \(viewModel.grokTokensInput) in / \(viewModel.grokTokensOutput) out")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            DisclosureGroup(isExpanded: $isHowItWorksExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Pick a project (New Project…) — Synapse creates a \".synapse\" folder and indexes its .md files.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("2. Ask a question above — Synapse searches indexed memory and returns matching chunks.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("3. Press **⌘⇧P** in Cursor — injects the latest context block directly into the Composer.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("4. Drop .md files here to add more to the index.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            } label: {
                Text("How Synapse works").font(.subheadline.weight(.medium))
            }

            DisclosureGroup(isExpanded: $isCursorInstructionsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Copy into your project's .cursorrules or Cursor instructions.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(Self.cursorInstructionsPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                AnimatedCopyButton(textToCopy: Self.cursorInstructionsPrompt, style: .bordered)
                }
            } label: {
                Text("Instructions for Cursor").font(.subheadline.weight(.medium))
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 480)
    }

    // MARK: - Onboarding sheet

    private var onboardingSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up Synapse")
                        .font(.title2.weight(.bold))
                    Text("Follow the steps below to configure your project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { showOnboardingSheet = false }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    onboardingStep(
                        number: "1",
                        icon: "folder.badge.gear",
                        iconColor: .accentColor,
                        title: "Select project folder",
                        description: "Synapse creates a .synapse folder with memory files (projectbrief, activeContext, progress, thoughts, learnings, codebase). This is your project memory — search and inject it into Cursor.",
                        isComplete: folderService.projectPath != nil
                    ) {
                        if let path = folderService.projectPath {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text((path as NSString).lastPathComponent)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Change…") { openProject(); showOnboardingSheet = false }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        } else {
                            Button("New Project…") { openProject(); showOnboardingSheet = false }
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    Divider().padding(.horizontal, 24)

                    onboardingStep(
                        number: "2",
                        icon: "doc.text.magnifyingglass",
                        iconColor: .blue,
                        title: "Project Type",
                        description: "Is this a code project or a markdown folder? Synapse can index your full code for deeper agent context, or just .md files for pure knowledge bases.",
                        isComplete: folderService.projectPath != nil
                    ) {
                        Picker("Project Type", selection: Binding(
                            get: { folderService.indexFullProject ? "code" : "md" },
                            set: { newValue in
                                _ = folderService.setIndexFullProject(newValue == "code")
                            }
                        )) {
                            Text("Code Project (Full Index)").tag("code")
                            Text("Knowledge Base (.md only)").tag("md")
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .disabled(folderService.projectPath == nil)
                    }

                    Divider().padding(.horizontal, 24)

                    onboardingStep(
                        number: "3",
                        icon: "folder.badge.plus",
                        iconColor: .purple,
                        title: "Add optional index folder",
                        description: "Index another folder (e.g. .Cursor) alongside .synapse. Its .md files — including skills.md and knowledge.md — become searchable in Synapse.",
                        isComplete: folderService.additionalIndexFolderPath != nil
                    ) {
                        HStack(spacing: 8) {
                            if let rel = folderService.additionalIndexFolderPath {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(rel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear") { viewModel.clearAdditionalFolder(folderService: folderService) }
                                    .foregroundStyle(.red)
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            } else {
                                Button("Select folder…") { viewModel.selectAdditionalFolder(folderService: folderService) }
                                    .buttonStyle(.bordered)
                                    .disabled(folderService.projectPath == nil)
                                Text("Optional").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if let msg = viewModel.extraFolderSuccess {
                            Label(msg, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        }
                        if let err = viewModel.extraFolderError {
                            Label(err, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                        }
                    }

                    Divider().padding(.horizontal, 24)

                    onboardingStep(
                        number: "4",
                        icon: "arrow.triangle.2.circlepath.doc.on.clipboard",
                        iconColor: .teal,
                        title: "Index your memory",
                        description: "Build the search index from your project. You must run this before using Self Synapse.",
                        isComplete: (viewModel.dbStats?.chunkCount ?? 0) > 0
                    ) {
                        HStack(spacing: 10) {
                            Button {
                                Task { await viewModel.indexAll(nodeBridge: nodeBridge, folderService: folderService, projectId: project?.id) }
                            } label: {
                                Label("Index All", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(folderService.projectPath == nil || viewModel.isIndexing)
                            if viewModel.isIndexing { ProgressView().scaleEffect(0.7) }
                            if let count = viewModel.indexCount {
                                Label("\(count) files indexed", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                    }

                    Divider().padding(.horizontal, 24)

                    onboardingStep(
                        number: "5",
                        icon: "brain",
                        iconColor: .indigo,
                        title: "Self Synapse (Optional)",
                        description: "Let Grok automatically read your indexed files and write your initial project memory. Requires an API key and a built index.",
                        isComplete: viewModel.selfSynapseSuccess != nil
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            if grokApiKey.isEmpty {
                                SecureField("Paste Grok API key…", text: $grokApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 300)
                            }
                            HStack {
                                Button("Run Self Synapse") {
                                    Task { await viewModel.runSelfSynapse(apiKey: grokApiKey, nodeBridge: nodeBridge, folderService: folderService) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isSelfSynapsing || folderService.projectPath == nil || grokApiKey.isEmpty || (viewModel.dbStats?.chunkCount ?? 0) == 0)
                                
                                if viewModel.isSelfSynapsing {
                                    HStack(spacing: 6) {
                                        ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                                        Text(nodeBridge.selfSynapseProgress ?? "Preparing...")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                            .contentTransition(.numericText())
                                            .animation(.easeInOut(duration: 0.2), value: nodeBridge.selfSynapseProgress)
                                    }
                                }
                            }
                            if let msg = viewModel.selfSynapseSuccess {
                                Text(msg).font(.caption).foregroundStyle(.green)
                            }
                            if let err = viewModel.selfSynapseError {
                                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                    }

                    Divider().padding(.horizontal, 24)

                    onboardingStep(
                        number: "6",
                        icon: "key.horizontal",
                        iconColor: .orange,
                        title: "Grok API key (optional)",
                        description: "Required for skill-format prompts, subagent context, and learnings. You can add it now or later in Tools & Settings.",
                        isComplete: !grokApiKey.isEmpty
                    ) {
                        DisclosureGroup("Set API key") {
                            VStack(alignment: .leading, spacing: 6) {
                                SecureField("Paste Grok API key…", text: $grokApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 300)
                                if !grokApiKey.isEmpty {
                                    Label("API key saved", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(.green)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Spacer()
                AnimatedActionButton(action: {
                    viewModel.onboardingCompleted = true
                    showOnboardingSheet = false
                }, delayAction: true) { isSuccess in
                    HStack(spacing: 4) {
                        if isSuccess { Image(systemName: "checkmark").transition(.scale.combined(with: .opacity)) }
                        Text("Done")
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 540, minHeight: 600)
    }

    @ViewBuilder
    private func onboardingStep<A: View>(
        number: String,
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        isComplete: Bool,
        @ViewBuilder action: () -> A
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green.opacity(0.12) : iconColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: isComplete ? "checkmark" : icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isComplete ? .green : iconColor)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Step \(number)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    if isComplete {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(title).font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action().padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Drop zone

    private var dropZoneContent: some View {
        Group {
            if viewModel.isDropTargeted {
                Text("Drop .md files to add to memory")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .background(Color.accentColor.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2))
                    .cornerRadius(12)
            } else {
                Text("Drag & drop .md files here to ingest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $viewModel.isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - Helpers

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedDate(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }

    private func formattedTokens(_ tokens: Int) -> String {
        tokens >= 1_000 ? String(format: "%.1fk", Double(tokens) / 1_000.0) : "\(tokens)"
    }

    private func openProject() {
        guard let path = folderService.openProjectPicker() else { return }
        viewModel.ingestError = nil
        Task {
            _ = await nodeBridge.setProject(path)
            _ = await nodeBridge.indexAll()
            if let pid = folderService.activeProjectId { folderService.recordIndexTime(for: pid) }
            NotificationCenter.default.post(name: .indexAllCompleted, object: path)
            await viewModel.refreshStats(nodeBridge: nodeBridge)
            viewModel.refreshFolderContent(folderService: folderService)
        }
    }

    private func locateNodeScript() {
        let panel = NSOpenPanel()
        panel.title = "Select node/index.js"
        panel.message = "Choose the Node bridge script (usually in your Synapse repo: node/index.js)"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            nodeBridge.setNodeScriptPath(url.path)
            nodeBridge.restartNode()
            viewModel.refresh(from: nodeBridge)
            if nodeBridge.isConnected {
                Task {
                    await SynapseAIApp.restoreProjectInNodeIfNeeded()
                    await viewModel.refreshStats(nodeBridge: nodeBridge)
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        if folderService.projectPath == nil {
            viewModel.ingestError = "Select a project first (New Project…)."
            return
        }
        viewModel.ingestError = nil
        for p in providers {
            guard p.hasItemConformingToTypeIdentifier("public.file-url") else { continue }
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let url: URL? = {
                    if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                    if let u = item as? URL { return u }
                    return nil
                }()
                guard let fileURL = url else { return }
                let ext = (fileURL.path as NSString).pathExtension.lowercased()
                guard ext == "md" else {
                    Task { @MainActor in viewModel.ingestError = "Only .md files are supported." }
                    return
                }
                Task { @MainActor in
                    viewModel.isIngesting = true
                    viewModel.ingestSuccessMessage = nil
                    viewModel.ingestError = nil
                    defer { viewModel.isIngesting = false }
                    let needsSecurityScope = fileURL.startAccessingSecurityScopedResource()
                    defer { if needsSecurityScope { fileURL.stopAccessingSecurityScopedResource() } }
                    guard let destPath = folderService.ingestFile(at: fileURL) else {
                        viewModel.ingestError = "Could not copy file. Ensure the project folder is selected (New Project…)."
                        return
                    }
                    switch await nodeBridge.indexFile(path: destPath) {
                    case .success(let chunks):
                        viewModel.lastIngestedFile = destPath
                        await viewModel.refreshStats(nodeBridge: nodeBridge)
                        viewModel.ingestSuccessMessage = "Added 1 file (\(chunks) chunks) — memory updated"
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            viewModel.ingestSuccessMessage = nil
                        }
                    case .failure(let err):
                        viewModel.ingestError = "Index failed: \(err.localizedDescription)"
                    }
                }
            }
            break
        }
    }
}

// MARK: - Animated Buttons

struct AnimatedCopyButton: View {
    let textToCopy: String
    enum ButtonStyleType { case iconOnly, prominent(Color?), bordered }
    let style: ButtonStyleType

    @State private var isCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textToCopy, forType: .string)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isCopied = true
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isCopied = false
                }
            }
        } label: {
            switch style {
            case .iconOnly:
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(isCopied ? Color.green : Color.primary)
            case .prominent:
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.clipboard.fill")
                    .font(.caption.bold())
                    .contentTransition(.symbolEffect(.replace))
            case .bordered:
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.clipboard")
                    .font(.caption.bold())
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyleForType(style, isCopied: isCopied)
    }
}

extension View {
    @ViewBuilder func buttonStyleForType(_ style: AnimatedCopyButton.ButtonStyleType, isCopied: Bool) -> some View {
        switch style {
        case .iconOnly:
            self.buttonStyle(.borderless)
        case .prominent(let tint):
            self.buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(isCopied ? .green : tint)
        case .bordered:
            self.buttonStyle(.bordered)
                .tint(isCopied ? .green : nil)
        }
    }
}

struct AnimatedActionButton<LabelView: View>: View {
    let action: () -> Void
    var delayAction: Bool = false
    @ViewBuilder let label: (Bool) -> LabelView
    
    @State private var isSuccess = false
    
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isSuccess = true
            }
            if delayAction {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    action()
                    isSuccess = false
                }
            } else {
                action()
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isSuccess = false
                    }
                }
            }
        } label: {
            label(isSuccess)
        }
    }
}

// MARK: - Process Animation View

struct ProcessAnimationView: View {
    let isSubagent: Bool
    var isChat: Bool = false
    let isOptimizing: Bool
    /// When set, the memory map animation uses this project's graph; view is keyed by projectPath so animation resets on tab change.
    var memoryMapCache: MemoryMapCache? = nil
    var projectPath: String? = nil

    @State private var stepIndex = 0
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    /// Animation limits: max chunks per file and max total nodes (for any future chunk-driven steps).
    private let maxChunksPerFileAnimation = 5
    private let maxAnimationNodes = 700
    
    private var steps: [(icon: String, text: String, color: Color)] {
        if isChat {
            return [
                ("brain.head.profile", "Reading project memory...", .blue),
                ("bubble.left.and.bubble.right", "Chatting with Grok...", .blue),
                ("doc.text.magnifyingglass", "Searching codebase when needed...", .blue),
                ("sparkles", "Preparing reply...", .blue)
            ]
        } else if isSubagent {
            return [
                ("brain.head.profile", "Loading full project memory...", .orange),
                ("doc.text.magnifyingglass", "Scanning codebase context...", .orange),
                ("arrow.triangle.branch", "Mapping subagent instructions...", .orange),
                ("shippingbox.fill", "Packaging subagent context...", .orange)
            ]
        } else if isOptimizing {
            return [
                ("brain.head.profile", "Consulting project memory...", .purple),
                ("doc.text.magnifyingglass", "Analyzing current prompt...", .purple),
                ("sparkles", "Applying senior engineer heuristics...", .purple),
                ("wand.and.stars", "Refining prompt with Grok...", .purple)
            ]
        } else {
            return [
                ("brain.head.profile", "Searching project memory...", .accentColor),
                ("doc.text.magnifyingglass", "Scanning codebase chunks...", .accentColor),
                ("sparkles", "Evaluating skill relevance...", .accentColor),
                ("slider.horizontal.3", "Optimizing context block...", .accentColor),
                ("shippingbox", "Finalizing prompt package...", .accentColor)
            ]
        }
    }
    
    
    var body: some View {
        let resolvedSteps = Array(steps.prefix(maxAnimationNodes))
        let currentStep = resolvedSteps.isEmpty ? steps[0] : resolvedSteps[stepIndex % resolvedSteps.count]
        
        VStack(spacing: 16) {
            MemoryMapAnimationView(
                color: currentStep.color,
                memoryMapCache: memoryMapCache,
                projectPath: projectPath
            )
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 24)
            
            HStack(spacing: 8) {
                Image(systemName: currentStep.icon)
                    .foregroundStyle(currentStep.color)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24)
                
                ZStack(alignment: .leading) {
                    // Hidden text of longest step to maintain width
                    Text("Applying senior engineer heuristics...")
                        .font(.headline)
                        .opacity(0)
                        .accessibilityHidden(true)
                    
                    Text(currentStep.text)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .id("text-\(stepIndex % steps.count)")
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        ))
                }
                .clipped()
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: stepIndex)
        }
        .onReceive(timer) { _ in
            stepIndex += 1
        }
    }
}

// MARK: - Memory Map Animation View

/// Canvas size used by MemoryMapLayout; used to normalize cached positions to 0–1.
private let memoryMapAnimationCanvasSize: CGFloat = 800

struct MemoryMapAnimationView: View {
    let color: Color
    /// When set and matching projectPath, the animation reveals this project's memory graph instead of random nodes.
    var memoryMapCache: MemoryMapCache? = nil
    var projectPath: String? = nil

    struct MapNode: Identifiable {
        let id: UUID
        let position: CGPoint
        var appearTime: TimeInterval
        var disappearTime: TimeInterval? = nil

        init(position: CGPoint, appearTime: TimeInterval, disappearTime: TimeInterval? = nil, id: UUID = UUID()) {
            self.id = id
            self.position = position
            self.appearTime = appearTime
            self.disappearTime = disappearTime
        }
    }

    struct MapEdge: Identifiable {
        let id = UUID()
        let from: UUID
        let to: UUID
        var appearTime: TimeInterval
        var disappearTime: TimeInterval? = nil
    }

    @State private var nodes: [MapNode] = []
    @State private var edges: [MapEdge] = []
    @State private var startTime: TimeInterval = 0
    /// Project-driven reveal: nodes/edges built from cache, revealed over time.
    @State private var pendingProjectNodes: [MapNode] = []
    @State private var pendingProjectEdges: [(from: UUID, to: UUID)] = []

    let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private var useProjectData: Bool {
        guard let cache = memoryMapCache, let path = projectPath, cache.projectPath == path, !cache.nodes.isEmpty else { return false }
        return true
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let elapsed = max(0, now - (startTime == 0 ? now : startTime))
                let progress = min(1.0, elapsed / 20.0)
                
                // Draw edges
                for edge in edges {
                    let age = now - edge.appearTime
                    if age > 0 {
                        var alpha = min(1.0, age / 0.4)
                        if let dTime = edge.disappearTime {
                            let dAge = now - dTime
                            if dAge > 0 {
                                alpha = max(0.0, 1.0 - (dAge / 0.5))
                            }
                        }
                        
                        if alpha > 0,
                           let fromNode = nodes.first(where: { $0.id == edge.from }),
                           let toNode = nodes.first(where: { $0.id == edge.to }) {
                            
                            let p1 = CGPoint(x: fromNode.position.x * size.width, y: fromNode.position.y * size.height)
                            let p2 = CGPoint(x: toNode.position.x * size.width, y: toNode.position.y * size.height)
                            
                            var path = Path()
                            path.move(to: p1)
                            path.addLine(to: p2)
                            
                            ctx.stroke(path, with: .color(Color.white.opacity(0.3 * alpha)), lineWidth: 1.5)
                        }
                    }
                }
                
                // Draw nodes
                for node in nodes {
                    let age = now - node.appearTime
                    if age > 0 {
                        var alpha = min(1.0, age / 0.3)
                        if let dTime = node.disappearTime {
                            let dAge = now - dTime
                            if dAge > 0 {
                                alpha = max(0.0, 1.0 - (dAge / 0.4))
                            }
                        }
                        
                        if alpha > 0 {
                            let p = CGPoint(x: node.position.x * size.width, y: node.position.y * size.height)
                            let radius: CGFloat = 12
                            
                            let pulseAmplitude = 0.15 * (1.0 - progress)
                            let pulse = 1.0 + pulseAmplitude * sin(age * 3)
                            
                            let scaleRect = CGRect(
                                x: p.x - radius * pulse,
                                y: p.y - radius * pulse,
                                width: radius * 2 * pulse,
                                height: radius * 2 * pulse
                            )
                            
                            var path = Path()
                            path.addEllipse(in: scaleRect)
                            ctx.fill(path, with: .color(Color.white.opacity(alpha)))
                        }
                    }
                }
            }
        }
        .onAppear {
            startTime = Date().timeIntervalSinceReferenceDate
            if useProjectData, let cache = memoryMapCache {
                let cs = memoryMapAnimationCanvasSize
                var idByNodeId: [String: UUID] = [:]
                var pendingNodes: [MapNode] = []
                for node in cache.nodes {
                    let raw = cache.nodePositions[node.id] ?? CGPoint(x: cs / 2, y: cs / 2)
                    let nx = max(0.05, min(0.95, raw.x / cs))
                    let ny = max(0.05, min(0.95, raw.y / cs))
                    let uuid = UUID()
                    idByNodeId[node.id] = uuid
                    pendingNodes.append(MapNode(position: CGPoint(x: nx, y: ny), appearTime: 0, id: uuid))
                }
                pendingProjectNodes = pendingNodes.shuffled()
                let visibleIds = Set(idByNodeId.values)
                pendingProjectEdges = cache.connections.compactMap { conn -> (UUID, UUID)? in
                    guard let fromU = idByNodeId[conn.fromId], let toU = idByNodeId[conn.toId], fromU != toU, visibleIds.contains(fromU), visibleIds.contains(toU) else { return nil }
                    return (fromU, toU)
                }
            }
        }
        .onReceive(timer) { date in
            let now = date.timeIntervalSinceReferenceDate
            let elapsed = max(0, now - (startTime == 0 ? now : startTime))
            let progress = min(1.0, elapsed / 20.0)
            let isStable = progress >= 1.0

            // Clean up fully disappeared elements
            nodes.removeAll { $0.disappearTime != nil && (now - $0.disappearTime!) > 0.5 }
            edges.removeAll { $0.disappearTime != nil && (now - $0.disappearTime!) > 0.5 }

            if useProjectData && !pendingProjectNodes.isEmpty {
                // Reveal project graph: add a few nodes per tick, then edges between visible nodes
                let toReveal = min(2, pendingProjectNodes.count)
                for _ in 0..<toReveal {
                    guard !pendingProjectNodes.isEmpty else { break }
                    var n = pendingProjectNodes.removeFirst()
                    n.appearTime = now
                    nodes.append(n)
                }
                let visibleIds = Set(nodes.filter { $0.disappearTime == nil }.map(\.id))
                let maxEdgesToAdd = 4
                var added = 0
                while added < maxEdgesToAdd, let idx = pendingProjectEdges.firstIndex(where: { visibleIds.contains($0.from) && visibleIds.contains($0.to) }) {
                    let e = pendingProjectEdges.remove(at: idx)
                    edges.append(MapEdge(from: e.from, to: e.to, appearTime: now + 0.05))
                    added += 1
                }
            } else if !useProjectData {
                // Add new node. Capacity grows from 30 up to 100 as memory stabilizes
                let maxNodes = Int(30 + (progress * 70))

                if nodes.filter({ $0.disappearTime == nil }).count < maxNodes {
                    let newNode = MapNode(
                        position: CGPoint(
                            x: CGFloat.random(in: 0.05...0.95),
                            y: CGFloat.random(in: 0.05...0.95)
                        ),
                        appearTime: now
                    )

                    let activeNodes = nodes.filter { $0.disappearTime == nil }
                    if !activeNodes.isEmpty {
                        let sortedNodes = activeNodes.sorted { n1, n2 in
                            let d1 = pow(n1.position.x - newNode.position.x, 2) + pow(n1.position.y - newNode.position.y, 2)
                            let d2 = pow(n2.position.x - newNode.position.x, 2) + pow(n2.position.y - newNode.position.y, 2)
                            return d1 < d2
                        }

                        let connections = Int.random(in: 1...min(3, activeNodes.count))
                        for i in 0..<connections {
                            edges.append(MapEdge(from: newNode.id, to: sortedNodes[i].id, appearTime: now + 0.1))
                        }
                    }

                    nodes.append(newNode)
                } else if !isStable {
                    // Trigger disappear for oldest node to create chaos/churn, stops when stable
                    if Double.random(in: 0...1) > 0.3 {
                        if let oldestIdx = nodes.firstIndex(where: { $0.disappearTime == nil }) {
                            nodes[oldestIdx].disappearTime = now
                            let oldId = nodes[oldestIdx].id
                            for eIdx in edges.indices {
                                if edges[eIdx].disappearTime == nil && (edges[eIdx].from == oldId || edges[eIdx].to == oldId) {
                                    edges[eIdx].disappearTime = now
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Fullscreen message sheet

private struct FullscreenMessageSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch message.kind {
        case .user: return "Prompt"
        case .hit(let path, let startLine, let endLine):
            return "\((path as NSString).lastPathComponent)  ·  L\(startLine)–\(endLine)"
        case .block: return "Skill prompt"
        case .subagentContext: return "Subagent context"
        case .assistant: return "Chat reply"
        case .optimized: return "Refined prompt"
        case .error: return "Error"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                AnimatedCopyButton(textToCopy: message.text, style: .prominent(nil))
                
                AnimatedActionButton(action: { dismiss() }, delayAction: true) { isSuccess in
                    HStack(spacing: 4) {
                        if isSuccess {
                            Image(systemName: "checkmark")
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text("Done")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .padding(.leading, 6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    MarkdownTextView(text: message.text, font: .body, lineSpacing: 6)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}
