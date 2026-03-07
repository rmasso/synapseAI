const fs = require('fs');

let content = fs.readFileSync('/Users/rubenmasso/Documents/Synapse/SynapseAI/SynapseAI/Features/Dashboard/DashboardView.swift', 'utf8');

const oldAddProjectSheet = content.match(/private var addProjectSheet: some View \{[\s\S]*?    @ViewBuilder\n    private func addSheetStep/);
if (!oldAddProjectSheet) {
    console.error("Could not find addProjectSheet");
    process.exit(1);
}

const newAddProjectSheet = `private var addProjectSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Project")
                        .font(.title2.weight(.bold))
                    Text("Step \\(currentAddProjectStep) of 6")
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

            ZStack {
                if currentAddProjectStep == 1 {
                    wizardStep(
                        icon: "folder.badge.gear",
                        iconColor: .accentColor,
                        title: "Select project folder",
                        description: "Synapse creates a .synapse memory folder (projectbrief, activeContext, progress, thoughts, learnings, codebase). This becomes your project's searchable memory."
                    ) {
                        if let path = addProjectSheetPath {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text((path as NSString).lastPathComponent)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer().frame(width: 8)
                                Button("Change…") {
                                    if let newPath = folderService.openProjectPicker() {
                                        addProjectSheetPath = newPath
                                        Task { _ = await nodeBridge.setProject(newPath) }
                                    }
                                }
                                .buttonStyle(.borderless).font(.body)
                            }
                            .padding()
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(8)
                        } else {
                            Button("Select folder…") {
                                if let newPath = folderService.openProjectPicker() {
                                    addProjectSheetPath = newPath
                                    Task { _ = await nodeBridge.setProject(newPath) }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    .transition(.opacity)
                } else if currentAddProjectStep == 2 {
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
                } else if currentAddProjectStep == 3 {
                    wizardStep(
                        icon: "folder.badge.plus",
                        iconColor: .purple,
                        title: "Add skills folder",
                        description: "Optional: index another folder (e.g. .Cursor) so its .md skills and knowledge files are searchable. Run Index All after adding."
                    ) {
                        VStack(spacing: 12) {
                            HStack(spacing: 8) {
                                if let rel = folderService.additionalIndexFolderPath {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text(rel).font(.body.weight(.medium)).foregroundStyle(.secondary)
                                    Spacer().frame(width: 8)
                                    Button("Clear") {
                                        folderService.writeAdditionalIndexFolder(nil)
                                        addProjectExtraFolderSuccess = nil
                                    }
                                    .foregroundStyle(.red).buttonStyle(.borderless).font(.body)
                                } else {
                                    Button("Select folder…") {
                                        addProjectExtraFolderError = nil
                                        addProjectExtraFolderSuccess = nil
                                        if let rel = folderService.openAdditionalIndexFolderPicker() {
                                            addProjectExtraFolderSuccess = "Added: \\(rel)"
                                        } else if folderService.projectPath != nil {
                                            addProjectExtraFolderError = "Folder must be inside the project folder."
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    Text("Optional").font(.caption).foregroundStyle(.tertiary)
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
                    .transition(.opacity)
                } else if currentAddProjectStep == 4 {
                    wizardStep(
                        icon: "magnifyingglass",
                        iconColor: .orange,
                        title: "Index your memory",
                        description: "Build the search index from your project. You must run this before using Self Synapse."
                    ) {
                        VStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Button("Index All") {
                                    Task {
                                        isIndexing = true
                                        _ = await nodeBridge.indexAll()
                                        if let pid = folderService.activeProjectId { folderService.recordIndexTime(for: pid) }
                                        addProjectIndexComplete = true
                                        isIndexing = false
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(isIndexing)
                                
                                if isIndexing { ProgressView().scaleEffect(0.7) }
                                if addProjectIndexComplete { Image(systemName: "checkmark").foregroundColor(.green) }
                            }
                        }
                    }
                    .transition(.opacity)
                } else if currentAddProjectStep == 5 {
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
                                    Task { await runSelfSynapseFromView() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .disabled(isSelfSynapsing || grokApiKey.isEmpty || !addProjectIndexComplete)
                                
                                if isSelfSynapsing {
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
                            if let msg = selfSynapseSuccess {
                                Text(msg).font(.caption).foregroundStyle(.green)
                            }
                            if let err = selfSynapseError {
                                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                    }
                    .transition(.opacity)
                } else if currentAddProjectStep == 6 {
                    wizardStep(
                        icon: "doc.on.clipboard",
                        iconColor: .blue,
                        title: "Remind Cursor to update memory",
                        description: "Paste this into Cursor so the agent knows to refresh your memory files after setup."
                    ) {
                        HStack(spacing: 8) {
                            Text("Update my .synapse memory folder (projectbrief, activeContext, progress, codebase).")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("Update my .synapse memory folder (projectbrief, activeContext, progress, codebase).", forType: .string)
                                addProjectMemoryPromptCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    addProjectMemoryPromptCopied = false
                                }
                            } label: {
                                Image(systemName: addProjectMemoryPromptCopied ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(addProjectMemoryPromptCopied ? .green : .secondary)
                                    .scaleEffect(addProjectMemoryPromptCopied ? 1.1 : 1.0)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding()
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: currentAddProjectStep)

            Divider()

            HStack {
                if currentAddProjectStep > 1 {
                    Button("Back") {
                        currentAddProjectStep -= 1
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if currentAddProjectStep < 6 {
                    Button("Next") {
                        currentAddProjectStep += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentAddProjectStep == 1 && addProjectSheetPath == nil)
                } else {
                    AnimatedActionButton(action: {
                        onboardingCompleted = true
                        showAddProjectSheet = false
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
            currentAddProjectStep = 1
        }
    }

    @ViewBuilder
    private func wizardStep<A: View>(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        @ViewBuilder action: () -> A
    ) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            .padding(.top, 40)
            
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            action()
                .padding(.top, 24)
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func addSheetStep`;

content = content.replace(oldAddProjectSheet[0], newAddProjectSheet);
fs.writeFileSync('/Users/rubenmasso/Documents/Synapse/SynapseAI/SynapseAI/Features/Dashboard/DashboardView.swift', content, 'utf8');
console.log('Patch applied successfully.');
