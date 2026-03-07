//
//  MemoryMapView.swift
//  SynapseAI
//
//  Graph visualization of indexed memory relationships from Synapse SQLite.
//

import SwiftUI
import AppKit

// MARK: - Debug (filter console with "[MemoryMap]" to trace per-tab map: which path is used, cache hit/miss, load success/fail)
private func memoryMapLog(_ msg: String) {
    print("[MemoryMap] \(msg)")
}

/// Serializes setProject + getAllConnections so concurrent tab loads don't overwrite the Node's project and all get the same data.
private actor MemoryMapLoadSerializer {
    static let shared = MemoryMapLoadSerializer()
    private init() {}
    func runLoad(path: String, nodeBridge: NodeBridgeService) async -> Result<(nodes: [MemoryMapNode], connections: [MemoryMapConnection]), Error> {
        // MainActor.run takes a synchronous closure; use a MainActor Task to run async work on the main actor.
        await Task { @MainActor in
            _ = await nodeBridge.setProject(path)
            return await nodeBridge.getAllConnections()
        }.value
    }
}

// MARK: - MemoryMapView

struct MemoryMapView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @EnvironmentObject var nodeBridge: NodeBridgeService
    @EnvironmentObject var folderService: FolderService
    @EnvironmentObject var memoryMapCacheStore: MemoryMapCacheStore
    @Environment(\.dismiss) private var dismiss

    /// When true, hide header and embed in chat area (no Back button).
    var embedInChat: Bool = false
    /// When set, use this path for load/cache (per-tab project). Otherwise use folderService.projectPath.
    var projectPath: String? = nil
    /// When true, this tab is the selected one (so the map is visible). Keying view id with this forces onAppear when tab becomes selected.
    var isTabSelected: Bool = true

    private var effectiveProjectPath: String {
        let path = projectPath ?? folderService.projectPath ?? ""
        return path
    }

    @State private var nodes: [MemoryMapNode] = []
    @State private var connections: [MemoryMapConnection] = []
    @State private var nodePositions: [String: CGPoint] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var scale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var selectedNodeId: String?
    @State private var previewNodeId: String?
    @State private var layoutComplete = false
    /// Node IDs from last prompt's context (chunk-X and file paths) — highlighted in blue.
    @State private var lastContextHighlightIds: Set<String> = []
    /// Staged reveal: 1=files+chunks, 2=file-chunk edges, 3=all edges
    @State private var revealPhase: Int = 0
    private let fileNodeRadius: CGFloat = 10
    private let chunkNodeRadius: CGFloat = 5
    private let canvasSize: CGFloat = 800
    private let forceIterations = 45
    /// Animation limits: max chunk nodes per file and max total nodes (files + chunks). Keeps map readable.
    private let maxChunksPerFile = 5
    private let maxMapNodes = 250

    private func nodeRadius(for node: MemoryMapNode) -> CGFloat {
        node.type == .file ? fileNodeRadius : chunkNodeRadius
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedInChat {
                headerBar
                Divider()
            }
            if isLoading {
                loadingView
            } else if let err = errorMessage {
                errorView(err)
            } else {
                graphCanvas
            }
        }
        .frame(minWidth: 500, minHeight: embedInChat ? 320 : 480)
        .frame(maxWidth: embedInChat ? .infinity : nil, maxHeight: embedInChat ? .infinity : nil)
        .id("\(effectiveProjectPath)")
        .onAppear {
            memoryMapLog("onAppear embedInChat=\(embedInChat) effectivePath=\((effectiveProjectPath as NSString).lastPathComponent) passedPath=\(projectPath.map { ($0 as NSString).lastPathComponent } ?? "nil")")
            tryRestoreFromCacheOrLoad()
        }
        .onChange(of: isTabSelected) { _, nowSelected in
            if nowSelected {
                memoryMapLog("onChange(isTabSelected)=true → refresh view effectivePath=\((effectiveProjectPath as NSString).lastPathComponent)")
                tryRestoreFromCacheOrLoad()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lastContextUpdated)) { _ in
            refreshLastContextHighlight()
        }
    }

    private func refreshLastContextHighlight() {
        guard !effectiveProjectPath.isEmpty else { return }
        Task {
            if case .success(let ctx) = await nodeBridge.getLastContextChunkIds() {
                var ids: Set<String> = []
                for id in ctx.chunkIds { ids.insert("chunk-\(id)") }
                for path in ctx.filePaths { ids.insert(path) }
                await MainActor.run { lastContextHighlightIds = ids }
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                Text("Back")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("Memory Map")
                .font(.headline)
            Spacer()
            if !nodes.isEmpty {
                Text("\(nodes.count) nodes · \(connections.count) connections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading memory map…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var graphCanvas: some View {
        // Snapshot state into locals so Canvas drawing closures capture the correct values for this render.
        let currentNodes = nodes
        let currentConnections = connections
        let currentPositions = nodePositions
        let currentRevealPhase = revealPhase
        let currentSelectedNodeId = selectedNodeId
        let currentHighlightIds = lastContextHighlightIds
        return TimelineView(.animation) { timeline in
            let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate) * 0.5
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    Color(NSColor.controlBackgroundColor)
                    ZStack {
                        Canvas { ctx, _ in
                            drawEdgesData(ctx: ctx, size: size, phase: phase,
                                          connections: currentConnections,
                                          nodePositions: currentPositions,
                                          revealPhase: currentRevealPhase,
                                          selectedNodeId: currentSelectedNodeId,
                                          lastContextHighlightIds: currentHighlightIds)
                            drawNodesData(ctx: ctx, size: size, phase: phase,
                                          nodes: currentNodes,
                                          nodePositions: currentPositions,
                                          revealPhase: currentRevealPhase,
                                          selectedNodeId: currentSelectedNodeId,
                                          lastContextHighlightIds: currentHighlightIds)
                        }
                        .id(nodes.first?.id ?? "empty")
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                        nodeTapOverlay(size: size, phase: phase)
                    }
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(scale)
                    .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = baseScale * value
                            }
                            .onEnded { value in
                                baseScale = max(0.3, min(3.0, baseScale * value))
                                scale = baseScale
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                                dragOffset = .zero
                            }
                    )
                    if let nodeId = previewNodeId, let node = nodes.first(where: { $0.id == nodeId }) {
                        VStack {
                            Spacer()
                            nodePreviewPanel(node)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .task(id: layoutComplete) {
            guard layoutComplete else { return }
            if revealPhase < 2 { revealPhase = 1 }
            for phase in 2...3 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                revealPhase = phase
            }
        }
    }

    private func nodeTapOverlay(size: CGSize, phase: CGFloat) -> some View {
        ZStack {
            ForEach(visibleNodes()) { node in
                if let pos = nodePositions[node.id] {
                    let floatPos = applyFloat(pos, phase: phase)
                    let screenCenter = viewToScreen(floatPos, size: size)
                    let hitSize: CGFloat = node.type == .file ? 44 : 28
                    Button {
                        selectedNodeId = selectedNodeId == node.id ? nil : node.id
                        previewNodeId = node.id
                    } label: {
                        Circle()
                            .fill(Color.clear)
                    }
                    .buttonStyle(.plain)
                    .frame(width: hitSize, height: hitSize)
                    .contentShape(Circle())
                    .position(screenCenter)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func nodePreviewPanel(_ node: MemoryMapNode) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(node.displayLabel)
                    .font(.headline)
                Text(node.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if node.type == .chunk {
                    Text("Chunk of \(node.path)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let preview = folderService.filePreview(relativePath: node.path, maxChars: 200) {
                    Text(preview)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No preview available")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            Button {
                previewNodeId = nil
                selectedNodeId = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .padding(16)
    }

    private func applyFloat(_ p: CGPoint, phase: CGFloat) -> CGPoint {
        let amp: CGFloat = 3
        let freq: CGFloat = 0.7
        let dx = sin(phase + CGFloat(p.x) * 0.01) * amp
        let dy = cos(phase * freq + CGFloat(p.y) * 0.01) * amp
        return CGPoint(x: p.x + dx, y: p.y + dy)
    }

    private func viewToScreen(_ p: CGPoint, size: CGSize) -> CGPoint {
        let cx = size.width / 2
        let cy = size.height / 2
        return CGPoint(x: cx + (p.x - canvasSize / 2), y: cy + (p.y - canvasSize / 2))
    }

    // MARK: - Pure-data drawing (pass all state explicitly so Canvas closure captures correct values)

    private func drawEdgesData(ctx: GraphicsContext, size: CGSize, phase: CGFloat,
                               connections: [MemoryMapConnection],
                               nodePositions: [String: CGPoint],
                               revealPhase: Int,
                               selectedNodeId: String?,
                               lastContextHighlightIds: Set<String> = []) {
        guard revealPhase >= 2 else { return }
        let cx = size.width / 2
        let cy = size.height / 2
        let visibleConns = connections.filter { conn in
            let fromIsChunk = conn.fromId.hasPrefix("chunk-")
            let toIsChunk = conn.toId.hasPrefix("chunk-")
            if revealPhase == 2 { return fromIsChunk != toIsChunk }
            return true
        }
        for conn in visibleConns {
            guard let from = nodePositions[conn.fromId], let to = nodePositions[conn.toId] else { continue }
            let isSelected = selectedNodeId != nil && (conn.fromId == selectedNodeId || conn.toId == selectedNodeId)
            let isLastContext = lastContextHighlightIds.contains(conn.fromId) && lastContextHighlightIds.contains(conn.toId)
            let isHighlighted = isSelected || isLastContext
            let strokeColor: Color = isSelected ? Color.accentColor : (isLastContext ? Color.blue : Color.gray.opacity(0.5))
            let fFrom = applyFloat(from, phase: phase)
            let fTo = applyFloat(to, phase: phase)
            var path = Path()
            let p1 = CGPoint(x: cx + (fFrom.x - canvasSize / 2), y: cy + (fFrom.y - canvasSize / 2))
            let p2 = CGPoint(x: cx + (fTo.x - canvasSize / 2), y: cy + (fTo.y - canvasSize / 2))
            path.move(to: p1)
            path.addLine(to: p2)
            ctx.stroke(path, with: .color(strokeColor), lineWidth: isHighlighted ? 2 : 1)
        }
    }

    private func drawNodesData(ctx: GraphicsContext, size: CGSize, phase: CGFloat,
                               nodes: [MemoryMapNode],
                               nodePositions: [String: CGPoint],
                               revealPhase: Int,
                               selectedNodeId: String?,
                               lastContextHighlightIds: Set<String> = []) {
        guard revealPhase >= 1 else { return }
        let cx = size.width / 2
        let cy = size.height / 2
        for node in nodes {
            guard let pos = nodePositions[node.id] else { continue }
            let radius: CGFloat = node.type == .file ? fileNodeRadius : chunkNodeRadius
            let fPos = applyFloat(pos, phase: phase)
            let isSelected = node.id == selectedNodeId
            let isLastContext = lastContextHighlightIds.contains(node.id)
            let nodeColor: Color = isSelected ? Color.accentColor : (isLastContext ? Color.blue : Color.primary)
            let fillOpacity: Double = node.type == .file ? 0.9 : 0.5
            let lineWidth: CGFloat = node.type == .file ? 2 : 0.5
            let screenPos = CGPoint(x: cx + (fPos.x - canvasSize / 2), y: cy + (fPos.y - canvasSize / 2))
            var path = Path()
            path.addEllipse(in: CGRect(x: screenPos.x - radius, y: screenPos.y - radius, width: radius * 2, height: radius * 2))
            ctx.fill(path, with: .color(nodeColor.opacity(isSelected || isLastContext ? 0.9 : fillOpacity)))
            ctx.stroke(path, with: .color(nodeColor.opacity(node.type == .file ? 0.9 : 0.4)), lineWidth: (isSelected || isLastContext) ? 2 : lineWidth)
            if node.type == .file {
                let fullTitle = node.displayLabel
                let title = fullTitle.count > 24 ? String(fullTitle.prefix(21)) + "…" : fullTitle
                ctx.draw(Text(title).font(.caption).foregroundStyle(.primary),
                         at: CGPoint(x: screenPos.x, y: screenPos.y + radius + 12), anchor: .top)
            }
        }
    }

    private func visibleConnections() -> [MemoryMapConnection] {
        guard revealPhase >= 2 else { return [] }
        return connections.filter { conn in
            let fromIsChunk = conn.fromId.hasPrefix("chunk-")
            let toIsChunk = conn.toId.hasPrefix("chunk-")
            if revealPhase == 2 { return fromIsChunk != toIsChunk }
            return true
        }
    }

    private func visibleNodes() -> [MemoryMapNode] {
        guard revealPhase >= 1 else { return [] }
        return nodes
    }

    private func drawEdges(ctx: GraphicsContext, size: CGSize, phase: CGFloat) {
        drawEdgesData(ctx: ctx, size: size, phase: phase, connections: connections, nodePositions: nodePositions, revealPhase: revealPhase, selectedNodeId: selectedNodeId, lastContextHighlightIds: lastContextHighlightIds)
    }

    private func drawNodes(ctx: GraphicsContext, size: CGSize, phase: CGFloat) {
        drawNodesData(ctx: ctx, size: size, phase: phase, nodes: nodes, nodePositions: nodePositions, revealPhase: revealPhase, selectedNodeId: selectedNodeId, lastContextHighlightIds: lastContextHighlightIds)
    }

    /// Cap nodes: at most maxMapNodes file nodes, then chunks (maxChunksPerFile per file) fill remaining slots; filter connections to kept nodes only.
    private func capNodesAndConnections(nodes: [MemoryMapNode], connections: [MemoryMapConnection]) -> ([MemoryMapNode], [MemoryMapConnection]) {
        let allFileNodes = nodes.filter { $0.type == .file }
        let fileNodes = Array(allFileNodes.prefix(maxMapNodes))
        let chunkNodes = nodes.filter { $0.type == .chunk }
        let shownPathSet = Set(fileNodes.map(\.path))
        let maxChunkSlots = max(0, maxMapNodes - fileNodes.count)
        var perPathCount: [String: Int] = [:]
        var cappedChunks: [MemoryMapNode] = []
        for node in chunkNodes {
            guard shownPathSet.contains(node.path) else { continue }
            let key = node.path
            let n = (perPathCount[key] ?? 0) + 1
            if n > maxChunksPerFile || cappedChunks.count >= maxChunkSlots { continue }
            perPathCount[key] = n
            cappedChunks.append(node)
        }
        let keptNodes = fileNodes + cappedChunks
        let keptIds = Set(keptNodes.map(\.id))
        let cappedConns = connections.filter { keptIds.contains($0.fromId) && keptIds.contains($0.toId) }
        return (keptNodes, cappedConns)
    }

    /// Use cached map for current project if valid; otherwise load from node and cache result.
    /// Store persists across tab switches; viewModel used for ProcessAnimationView.
    private func tryRestoreFromCacheOrLoad() {
        let currentPath = effectiveProjectPath
        let pathLabel = (currentPath as NSString).lastPathComponent
        let cache = memoryMapCacheStore.cache(for: currentPath) ?? viewModel.memoryMapCache
        if let c = cache, c.projectPath == currentPath, !c.nodes.isEmpty {
            memoryMapLog("restoreFromCache HIT path=\(pathLabel) nodes=\(c.nodes.count)")
            nodes = c.nodes
            connections = c.connections
            nodePositions = c.nodePositions
            isLoading = false
            errorMessage = nil
            layoutComplete = true
            revealPhase = 2
            viewModel.memoryMapCache = c
            Task {
                if case .success(let ctx) = await nodeBridge.getLastContextChunkIds() {
                    var ids: Set<String> = []
                    for id in ctx.chunkIds { ids.insert("chunk-\(id)") }
                    for path in ctx.filePaths { ids.insert(path) }
                    await MainActor.run { lastContextHighlightIds = ids }
                }
            }
            return
        }
        memoryMapLog("restoreFromCache MISS path=\(pathLabel) → load")
        loadConnections()
    }

    private func loadConnections() {
        isLoading = true
        errorMessage = nil
        let currentPath = effectiveProjectPath
        let pathLabel = (currentPath as NSString).lastPathComponent
        guard !currentPath.isEmpty else {
            memoryMapLog("loadConnections SKIP path=empty → no project set")
            isLoading = false
            errorMessage = "No project set. Select a project in the dashboard (or add one) and try again."
            return
        }
        memoryMapLog("loadConnections START path=\(pathLabel)")
        Task {
            let result = await MemoryMapLoadSerializer.shared.runLoad(path: currentPath, nodeBridge: nodeBridge)
            memoryMapLog("loadConnections got result for path=\(pathLabel)")
            switch result {
            case .success(let data):
                let (nodesToLayout, connsToLayout) = capNodesAndConnections(nodes: data.nodes, connections: data.connections)
                let positions = await Task.detached(priority: .userInitiated) {
                    MemoryMapLayout.run(
                        nodes: nodesToLayout,
                        connections: connsToLayout,
                        canvasSize: canvasSize,
                        iterations: forceIterations,
                        nodeRadius: fileNodeRadius
                    )
                }.value
                var highlightIds: Set<String> = []
                if case .success(let ctx) = await nodeBridge.getLastContextChunkIds() {
                    for id in ctx.chunkIds {
                        highlightIds.insert("chunk-\(id)")
                    }
                    for path in ctx.filePaths {
                        highlightIds.insert(path)
                    }
                }
                let cache = MemoryMapCache(
                    projectPath: currentPath,
                    nodes: nodesToLayout,
                    connections: connsToLayout,
                    nodePositions: positions
                )
                await MainActor.run {
                    nodes = nodesToLayout
                    connections = connsToLayout
                    nodePositions = positions
                    lastContextHighlightIds = highlightIds
                    isLoading = false
                    layoutComplete = true
                    revealPhase = 2
                    viewModel.memoryMapCache = cache
                    memoryMapCacheStore.setCache(cache)
                    memoryMapLog("loadConnections SUCCESS path=\(pathLabel) nodes=\(nodesToLayout.count) cached")
                }
            case .failure(let err):
                await MainActor.run {
                    isLoading = false
                    errorMessage = err.localizedDescription
                    memoryMapLog("loadConnections FAIL path=\(pathLabel) error=\(err.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Force-directed layout (testable)

struct MemoryMapLayout {
    static func run(
        nodes: [MemoryMapNode],
        connections: [MemoryMapConnection],
        canvasSize: CGFloat = 800,
        iterations: Int = 80,
        nodeRadius: CGFloat = 8
    ) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        var pos = [String: CGPoint]()
        let center = canvasSize / 2
        for (i, node) in nodes.enumerated() {
            let angle = Double(i) / Double(nodes.count) * 2 * .pi
            pos[node.id] = CGPoint(x: center + cos(angle) * 120, y: center + sin(angle) * 120)
        }

        let repulsion: CGFloat = 800
        let attraction: CGFloat = 0.02
        let damping: CGFloat = 0.85

        for _ in 0..<iterations {
            var forces = [String: CGPoint]()
            for node in nodes {
                forces[node.id] = .zero
            }
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    let a = nodes[i], b = nodes[j]
                    guard let pa = pos[a.id], let pb = pos[b.id] else { continue }
                    let dx = pa.x - pb.x
                    let dy = pa.y - pb.y
                    let dist = max(sqrt(dx * dx + dy * dy), 1)
                    let force = repulsion / (dist * dist)
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    forces[a.id] = CGPoint(
                        x: (forces[a.id]?.x ?? 0) + fx,
                        y: (forces[a.id]?.y ?? 0) + fy
                    )
                    forces[b.id] = CGPoint(
                        x: (forces[b.id]?.x ?? 0) - fx,
                        y: (forces[b.id]?.y ?? 0) - fy
                    )
                }
            }
            for conn in connections {
                guard let pa = pos[conn.fromId], let pb = pos[conn.toId] else { continue }
                let dx = pb.x - pa.x
                let dy = pb.y - pa.y
                let dist = max(sqrt(dx * dx + dy * dy), 1)
                let force = dist * attraction
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[conn.fromId] = CGPoint(
                    x: (forces[conn.fromId]?.x ?? 0) + fx,
                    y: (forces[conn.fromId]?.y ?? 0) + fy
                )
                forces[conn.toId] = CGPoint(
                    x: (forces[conn.toId]?.x ?? 0) - fx,
                    y: (forces[conn.toId]?.y ?? 0) - fy
                )
            }
            for node in nodes {
                guard var p = pos[node.id], let f = forces[node.id] else { continue }
                p.x += f.x * damping
                p.y += f.y * damping
                p.x = max(nodeRadius * 2, min(canvasSize - nodeRadius * 2, p.x))
                p.y = max(nodeRadius * 2, min(canvasSize - nodeRadius * 2, p.y))
                pos[node.id] = p
            }
        }
        return pos
    }
}

