const fs = require('fs');

let content = fs.readFileSync('/Users/rubenmasso/Documents/Synapse/SynapseAI/SynapseAI/Features/Dashboard/DashboardView.swift', 'utf8');

const oldOnboardingSheet = content.match(/private var onboardingSheet: some View \{[\s\S]*?    @ViewBuilder\n    private func onboardingStep/);
if (!oldOnboardingSheet) {
    console.error("Could not find onboardingSheet");
    process.exit(1);
}

const newOnboardingSheet = `private var onboardingSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up Synapse")
                        .font(.title2.weight(.bold))
                    Text("Step \\(currentOnboardingStep) of 6")
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

            ZStack {
                if currentOnboardingStep == 1 {
                    wizardStep(
                        icon: "folder.badge.gear",
                        iconColor: .accentColor,
                        title: "Select project folder",
                        description: "Synapse creates a .synapse folder with memory files (projectbrief, activeContext, progress, thoughts, learnings, codebase). This is your project memory — search and inject it into Cursor."
                    ) {
                        if let path = folderService.projectPath {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text((path as NSString).lastPathComponent)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer().frame(width: 8)
                                Button("Change…") { openProject() }
                                    .buttonStyle(.borderless).font(.body)
                            }
                            .padding()
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(8)
                        } else {
                            Button("New Project…") { openProject() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                    }
                    .transition(.opacity)
                } else if currentOnboardingStep == 2 {
                    wizardStep(
                        icon: "doc.text.magnifyingglass",
                        iconColor: .blue,
                        title: "Project Type",
                        description: "Is this a code project or a markdown folder? Synapse can index your full code for deeper agent context, or just .md files for pure knowledge bases."
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
                        .padding()
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .transition(.opacity)
                } else if currentOnboardingStep == 3 {
                    wizardStep(
                        icon: "folder.badge.plus",
                        iconColor: .purple,
                        title: "Add optional index folder",
                        description: "Index another folder (e.g. .Cursor) alongside .synapse. Its .md files — including skills.md and knowledge.md — become searchable in Synapse."
                    ) {
                        VStack(spacing: 12) {
                            HStack(spacing: 8) {
                                if let rel = folderService.additionalIndexFolderPath {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text(rel).font(.body.weight(.medium)).foregroundStyle(.secondary)
                                    Spacer().frame(width: 8)
                                    Button("Clear") { viewModel.clearAdditionalFolder(folderService: folderService) }
                                        .foregroundStyle(.red).buttonStyle(.borderless).font(.body)
                                } else {
                                    Button("Select folder…") { viewModel.selectAdditionalFolder(folderService: folderService) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                        .disabled(folderService.projectPath == nil)
                                    Text("Optional").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            if let msg = viewModel.extraFolderSuccess {
                                Label(msg, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            }
                            if let err = viewModel.extraFolderError {
                                Label(err, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .transition(.opacity)
                } else if currentOnboardingStep == 4 {
                    wizardStep(
                        icon: "magnifyingglass",
                        iconColor: .teal,
                        title: "Index your memory",
                        description: "Build the search index from your project. You must run this before using Self Synapse."
                    ) {
                        VStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Button("Index All") {
                                    Task { await viewModel.indexAll(nodeBridge: nodeBridge, folderService: folderService, projectId: project?.id) }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(viewModel.isIndexing)
                                
                                if viewModel.isIndexing { ProgressView().scaleEffect(0.7) }
                                if let count = viewModel.indexCount {
                                    Label("\\(count) files indexed", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .transition(.opacity)
                } else if currentOnboardingStep == 5 {
                    wizardStep(
                        icon: "brain",
                        iconColor: .indigo,
                        title: "Self Synapse (Optional)",
                        description: "Let Grok automatically read your indexed files and write your initial project memory. Requires an API key and a built index."
                    ) {
                        VStack(spacing: 12) {
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
                                .controlSize(.large)
                                .disabled(viewModel.isSelfSynapsing || grokApiKey.isEmpty || (viewModel.dbStats?.chunkCount ?? 0) == 0)
                                
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
                    .transition(.opacity)
                } else if currentOnboardingStep == 6 {
                    wizardStep(
                        icon: "key",
                        iconColor: .orange,
                        title: "Grok API key",
                        description: "Required for Self Synapse, skill generation, and other AI features."
                    ) {
                        SecureField("Paste Grok API key…", text: $grokApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                            .padding()
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(8)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: currentOnboardingStep)

            Divider()

            HStack {
                if currentOnboardingStep > 1 {
                    Button("Back") {
                        currentOnboardingStep -= 1
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if currentOnboardingStep < 6 {
                    Button("Next") {
                        currentOnboardingStep += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentOnboardingStep == 1 && folderService.projectPath == nil)
                } else {
                    AnimatedActionButton(action: {
                        onboardingCompleted = true
                        showOnboardingSheet = false
                    }, delayAction: true) { isSuccess in
                        HStack(spacing: 4) {
                            if isSuccess { Image(systemName: "checkmark").transition(.scale.combined(with: .opacity)) }
                            Text("Done")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540, height: 460)
        .onAppear {
            currentOnboardingStep = 1
        }
    }

    @ViewBuilder
    private func onboardingStep`;

content = content.replace(oldOnboardingSheet[0], newOnboardingSheet);

// Now we can also delete the `addSheetStep` and `onboardingStep` functions since they are no longer used!
content = content.replace(/    @ViewBuilder\n    private func addSheetStep[\s\S]*?(?=    \/\/ MARK: - Helper)/, "");
content = content.replace(/    @ViewBuilder\n    private func onboardingStep[\s\S]*?(?=\}\n\n    \/\/ MARK: - Previews)/, "");

fs.writeFileSync('/Users/rubenmasso/Documents/Synapse/SynapseAI/SynapseAI/Features/Dashboard/DashboardView.swift', content, 'utf8');
console.log('Patch applied successfully.');
