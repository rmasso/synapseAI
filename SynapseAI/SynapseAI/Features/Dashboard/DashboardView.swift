//
//  DashboardView.swift
//  SynapseAI
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - DashboardView (TabView shell)

struct DashboardView: View {
    @EnvironmentObject var nodeBridge: NodeBridgeService
    @EnvironmentObject var folderService: FolderService
    @State private var selectedProjectId: UUID? = nil

    // Add-project sheet state (lives here so the + tab can show the sheet from DashboardView level)
    @State private var showAddProjectSheet = false
    @State private var addProjectSheetPath: String? = nil
    @State private var addProjectExtraFolderSuccess: String? = nil
    @State private var addProjectExtraFolderError: String? = nil
    @AppStorage("synapse.onboardingCompleted") private var onboardingCompleted = false

    /// Sentinel UUID used as the tag for the "+" tab item. Never represents a real project.
    private static let addTabSentinel = UUID()

    var body: some View {
        TabView(selection: $selectedProjectId) {
            ForEach(folderService.projects) { project in
                ProjectDashboardContent(project: project)
                    .tabItem {
                        let stale = folderService.isIndexStale(for: project.id)
                        Label(project.name, systemImage: stale ? "exclamationmark.triangle" : "folder")
                    }
                    .tag(project.id as UUID?)
            }
            // Shown when there are no projects yet (no-project onboarding state).
            if folderService.projects.isEmpty {
                ProjectDashboardContent(project: nil)
                    .tabItem { Label("Synapse", systemImage: "brain.head.profile") }
                    .tag(UUID?.none)
            }
            // "+" sentinel tab — tapping it shows the Add Project sheet; never navigated to.
            Color.clear
                .tabItem { Label("Add", systemImage: "plus") }
                .tag(UUID?.some(Self.addTabSentinel))
        }
        .frame(minWidth: 500, minHeight: 640)
        .onAppear {
            selectedProjectId = folderService.activeProjectId
        }
        // When FolderService activates a project (e.g. after addProject), sync the tab selection.
        .onChange(of: folderService.activeProjectId) { _, newId in
            if selectedProjectId != newId {
                selectedProjectId = newId
            }
        }
        // When the user picks a different tab, activate that project.
        // Intercept the sentinel tab to show the Add Project sheet instead.
        .onChange(of: selectedProjectId) { _, newId in
            if newId == Self.addTabSentinel {
                // Reset selection immediately — never actually navigate to the sentinel tab.
                selectedProjectId = folderService.activeProjectId
                addProjectSheetPath = nil
                addProjectExtraFolderSuccess = nil
                addProjectExtraFolderError = nil
                showAddProjectSheet = true
                return
            }
            guard let newId,
                  let project = folderService.projects.first(where: { $0.id == newId }),
                  folderService.activeProjectId != newId else { return }
            folderService.activateProject(project)
            Task { _ = await nodeBridge.setProject(project.path) }
        }
        .sheet(isPresented: $showAddProjectSheet) {
            addProjectSheet
        }
    }

    // MARK: - Add Project sheet (DashboardView-level, no viewModel dependency)

    private var addProjectSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Project")
                        .font(.title2.weight(.bold))
                    Text("Connect a Cursor workspace to Synapse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { showAddProjectSheet = false }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    addSheetStep(
                        number: "1",
                        systemImage: "folder.badge.gear",
                        iconColor: .accentColor,
                        title: "Select project folder",
                        description: "Synapse creates a .synapse memory folder (projectbrief, activeContext, progress, thoughts, learnings, codebase). This becomes your project's searchable memory.",
                        isComplete: addProjectSheetPath != nil
                    ) {
                        if let path = addProjectSheetPath {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text((path as NSString).lastPathComponent)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Change…") {
                                    if let newPath = folderService.openProjectPicker() {
                                        addProjectSheetPath = newPath
                                        Task { _ = await nodeBridge.setProject(newPath) }
                                    }
                                }
                                .buttonStyle(.borderless).font(.caption)
                            }
                        } else {
                            Button("Select folder…") {
                                if let newPath = folderService.openProjectPicker() {
                                    addProjectSheetPath = newPath
                                    Task { _ = await nodeBridge.setProject(newPath) }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Divider().padding(.horizontal, 24)

                    addSheetStep(
                        number: "2",
                        systemImage: "folder.badge.plus",
                        iconColor: .purple,
                        title: "Add skills folder",
                        description: "Optional: index another folder (e.g. .Cursor) so its .md skills and knowledge files are searchable. Run Index All after adding.",
                        isComplete: folderService.additionalIndexFolderPath != nil
                    ) {
                        HStack(spacing: 8) {
                            if let rel = folderService.additionalIndexFolderPath {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(rel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear") {
                                    folderService.writeAdditionalIndexFolder(nil)
                                    addProjectExtraFolderSuccess = nil
                                }
                                .foregroundStyle(.red).buttonStyle(.borderless).font(.caption)
                            } else {
                                Button("Select folder…") {
                                    addProjectExtraFolderError = nil
                                    addProjectExtraFolderSuccess = nil
                                    if let rel = folderService.openAdditionalIndexFolderPicker() {
                                        addProjectExtraFolderSuccess = "Added: \(rel)"
                                    } else if folderService.projectPath != nil {
                                        addProjectExtraFolderError = "Folder must be inside the project folder."
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(addProjectSheetPath == nil && folderService.projectPath == nil)
                                Text("Optional").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        if let msg = addProjectExtraFolderSuccess {
                            Label(msg, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        }
                        if let err = addProjectExtraFolderError {
                            Label(err, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Spacer()
                AnimatedActionButton(action: {
                    onboardingCompleted = true
                    showAddProjectSheet = false
                    if folderService.projectPath != nil {
                        Task {
                            _ = await nodeBridge.indexAll()
                            if let pid = folderService.activeProjectId { folderService.recordIndexTime(for: pid) }
                        }
                    }
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
        .frame(minWidth: 480, minHeight: 380)
    }

    @ViewBuilder
    private func addSheetStep<A: View>(
        number: String,
        systemImage: String,
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
                Image(systemName: isComplete ? "checkmark" : systemImage)
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
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
                Text(title).font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action().padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

// MARK: - ProjectDashboardContent

/// Full per-project dashboard content. Each tab gets its own instance with an isolated DashboardViewModel.
private struct ProjectDashboardContent: View {
    /// The project this content represents. nil = no project selected (onboarding state).
    let project: SynapseProject?

    @EnvironmentObject var nodeBridge: NodeBridgeService
    @EnvironmentObject var folderService: FolderService
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
    @State private var isShowingDeleteConfirmation: Bool = false
    @State private var isPromptCopied = false
    /// Tick updated every 60 s so `isStale` re-evaluates without any user interaction.
    @State private var now = Date()

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
        .sheet(item: $fullscreenMessage) { msg in
            FullscreenMessageSheet(message: msg)
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    // MARK: - Stale index warning

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
            if let stats = viewModel.dbStats {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(stats.chunkCount) chunks · \(formatByteCount(stats.dbSizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
            if project != nil {
                Button(action: { isShowingDeleteConfirmation = true }) {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.8))
                .alert(isPresented: $isShowingDeleteConfirmation) {
                    let projectName = project?.name ?? "Unknown"
                    return Alert(
                        title: Text("Delete Project?"),
                        message: Text("This will remove the project '\(projectName)' from Synapse. The .synapse folder and database remain on disk. This action cannot be undone."),
                        primaryButton: .destructive(Text("Delete")) {
                            removeCurrentProject()
                        },
                        secondaryButton: .cancel()
                    )
                }
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
            if viewModel.isBuildingContext || viewModel.isBuildingSubagentContext || viewModel.isOptimizingPrompt {
                // Large centered loading animation
                VStack {
                    Spacer()
                    ProcessAnimationView(
                        isSubagent: viewModel.isBuildingSubagentContext,
                        isOptimizing: viewModel.isOptimizingPrompt
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
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
        .animation(.easeInOut(duration: 0.3), value: viewModel.isBuildingContext || viewModel.isBuildingSubagentContext || viewModel.isOptimizingPrompt)
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
                        Image(systemName: "arrow.up.circle.fill")
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
                Text(msg.text)
                    .font(.body)
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
                Text(msg.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14)

        case .block(let count, let total, let savedTokens):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skill prompt · \(count) of \(total) chunk\(total == 1 ? "" : "s") selected · copied to clipboard")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
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
                    Spacer()
                    Button { fullscreenMessage = msg } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("View full content")
                    AnimatedCopyButton(textToCopy: msg.text, style: .prominent(nil))
                }
                Text(msg.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
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
                Text(msg.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
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
                Text(msg.text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
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
                                  !viewModel.isOptimizingPrompt else { return .handled }
                            Task { await viewModel.buildContextForPrompt(apiKey: grokApiKey, nodeBridge: nodeBridge) }
                            return .handled
                        }
                }
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                Button {
                    Task { await viewModel.buildContextForPrompt(apiKey: grokApiKey, nodeBridge: nodeBridge) }
                } label: {
                    Image(systemName: viewModel.isBuildingContext ? "ellipsis.circle" : "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            viewModel.isBuildingContext || viewModel.promptForContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .help("Send — skill-format prompt for Cursor")
                .disabled(
                    viewModel.isBuildingContext ||
                    viewModel.isBuildingSubagentContext ||
                    viewModel.isOptimizingPrompt ||
                    viewModel.promptForContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                Button {
                    Task { await viewModel.buildSubagentContext(apiKey: grokApiKey, nodeBridge: nodeBridge) }
                } label: {
                    Image(systemName: viewModel.isBuildingSubagentContext ? "ellipsis.circle" : "person.2.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            viewModel.isBuildingSubagentContext || viewModel.promptForContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary : Color.orange
                        )
                }
                .buttonStyle(.plain)
                .help("Subagent context — memory-heavy package for parallel agent")
                .disabled(
                    viewModel.isBuildingContext ||
                    viewModel.isBuildingSubagentContext ||
                    viewModel.isOptimizingPrompt ||
                    viewModel.promptForContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(NSColor.windowBackgroundColor))
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
                if let stats = viewModel.dbStats {
                    HStack {
                        Label("Memory", systemImage: "internaldrive")
                        Spacer()
                        Text("\(stats.documentCount) docs · \(stats.chunkCount) chunks · \(formatByteCount(stats.dbSizeBytes))")
                            .font(.caption).foregroundStyle(.secondary)
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

            Section("Context Settings") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Max chunks", systemImage: "square.stack.3d.up")
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
                }
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
                        number: "3",
                        icon: "arrow.triangle.2.circlepath.doc.on.clipboard",
                        iconColor: .teal,
                        title: "Index your memory",
                        description: "Build the search index from .synapse (and the extra folder if set). Run Index All after adding or editing any memory files.",
                        isComplete: (viewModel.dbStats?.chunkCount ?? 0) > 0
                    ) {
                        HStack(spacing: 10) {
                            Button {
                                Task { await viewModel.indexAll(nodeBridge: nodeBridge, folderService: folderService, projectId: project?.id) }
                            } label: {
                                Label("Index All", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(folderService.projectPath == nil)
                            if let count = viewModel.indexCount {
                                Label("\(count) files indexed", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                    }

                    Divider().padding(.horizontal, 24)

                    onboardingStep(
                        number: "4",
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
            await viewModel.refreshStats(nodeBridge: nodeBridge)
            viewModel.refreshFolderContent(folderService: folderService)
        }
    }

    private func removeCurrentProject() {
        guard let id = project?.id ?? folderService.activeProjectId else { return }
        folderService.removeProject(id: id)
        Task { _ = await nodeBridge.setProject(folderService.projectPath) }
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
    let isOptimizing: Bool
    
    @State private var stepIndex = 0
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    private var steps: [(icon: String, text: String, color: Color)] {
        if isSubagent {
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
        let currentStep = steps[stepIndex % steps.count]
        
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .padding(.bottom, 4)
            
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
                Text(message.text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}
