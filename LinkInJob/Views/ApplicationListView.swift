import AppKit
import SwiftUI

struct ApplicationListView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @FocusState private var focus: FocusTarget?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                VStack(spacing: 0) {
                    header

                    if viewModel.filteredApplications.isEmpty {
                        ContentUnavailableView(
                            "No applications",
                            systemImage: "tray",
                            description: Text(emptyStateMessage)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focus = nil
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(viewModel.filteredApplications) { item in
                                    ApplicationRowView(
                                        item: item,
                                        isSelected: viewModel.selectedItemID == item.id,
                                        toggleStar: { viewModel.toggleStar(for: item) }
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Menu("Set Stage") {
                                            ForEach(Stage.allCases, id: \.self) { stage in
                                                Button(stage.title) {
                                                    viewModel.setStage(stage, for: item)
                                                }
                                            }
                                        }

                                        if item.jobURL != nil {
                                            Button("Open Job Link") {
                                                viewModel.openJobLink(for: item)
                                            }
                                        }

                                        Button("Open Source File") {
                                            viewModel.openSourceFile(for: item)
                                        }

                                        Button(item.starred ? "Unstar" : "Toggle Star") {
                                            viewModel.toggleStar(for: item)
                                        }

                                        Button("Reset to Auto") {
                                            viewModel.resetToAuto(for: item)
                                        }
                                    }
                                    .onTapGesture {
                                        viewModel.selectedItemID = item.id
                                        focus = nil
                                    }
                                    .onTapGesture(count: 2) {
                                        viewModel.selectedItemID = item.id
                                        focus = nil
                                        if item.jobURL != nil {
                                            viewModel.openJobLink(for: item)
                                        } else {
                                            viewModel.openSourceFile(for: item)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .id(item.id)
                                }
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focus = nil
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    KeyCaptureView(isEnabled: focus != .searchField) { event in
                        switch event {
                        case .upArrow:
                            viewModel.selectPreviousInFilteredList()
                        case .downArrow:
                            viewModel.selectNextInFilteredList()
                        case .letter(let char):
                            viewModel.handleListHotkey(String(char))
                        case .returnKey:
                            guard let item = viewModel.selectedItem else { return }
                            if item.jobURL != nil {
                                viewModel.openJobLink(for: item)
                            } else {
                                viewModel.openSourceFile(for: item)
                            }
                        case .space:
                            guard let item = viewModel.selectedItem else { return }
                            viewModel.openSourceFile(for: item)
                        }
                    }
                    .allowsHitTesting(false)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Applications")
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    viewModel.selectPreviousInFilteredList()
                case .down:
                    viewModel.selectNextInFilteredList()
                default:
                    break
                }
            }
            .onAppear {
                viewModel.ensureSelectionVisibleInFilteredList()
                focus = nil
                scrollSelectionIfNeeded(with: proxy, animated: false)
            }
            .onChange(of: viewModel.filteredApplications.map(\.id)) { _, _ in
                viewModel.ensureSelectionVisibleInFilteredList()
                scrollSelectionIfNeeded(with: proxy, animated: false)
            }
            .onChange(of: viewModel.selectedItemID) { _, newValue in
                let selectedText = newValue?.uuidString ?? "nil"
                print("[Selection] selectedItemID=\(selectedText)")
                scrollSelectionIfNeeded(with: proxy)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Sort", selection: $viewModel.sortOption) {
                ForEach(AppViewModel.SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220, alignment: .leading)

            TextField("Search company, role, location", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .searchField)
                .frame(maxWidth: 430, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) {
            Button("Focus Search") {
                focus = .searchField
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
    }

    private func scrollSelectionIfNeeded(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard let selectedID = viewModel.selectedItemID else { return }
        let action = {
            proxy.scrollTo(selectedID, anchor: .center)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.12)) {
                action()
            }
        } else {
            action()
        }
    }

    private var emptyStateMessage: String {
        if !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matches for the current search."
        }

        switch viewModel.sidebarFilter {
        case .stage(let stage):
            return "No applications in \(stage.title)."
        case .starred:
            return "No starred applications."
        case .noReply:
            return "No follow-up items right now."
        }
    }
}

private enum KeyAction {
    case upArrow
    case downArrow
    case letter(Character)
    case returnKey
    case space
}

private enum FocusTarget: Hashable {
    case jobsList
    case searchField
}

private struct KeyCaptureView: NSViewRepresentable {
    let isEnabled: Bool
    let onKeyAction: (KeyAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyAction: onKeyAction)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onKeyAction = onKeyAction
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var isEnabled = false
        var onKeyAction: (KeyAction) -> Void
        private var monitor: Any?

        init(onKeyAction: @escaping (KeyAction) -> Void) {
            self.onKeyAction = onKeyAction
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isEnabled else { return event }
                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
                    return event
                }

                switch event.keyCode {
                case 125:
                    self.onKeyAction(.downArrow)
                    return nil
                case 126:
                    self.onKeyAction(.upArrow)
                    return nil
                case 36:
                    self.onKeyAction(.returnKey)
                    return nil
                case 49:
                    self.onKeyAction(.space)
                    return nil
                default:
                    if let char = event.charactersIgnoringModifiers?.lowercased().first,
                       ["i", "r", "a", "s", "f"].contains(char) {
                        self.onKeyAction(.letter(char))
                        return nil
                    }
                    return event
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
