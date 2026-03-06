import AppKit
import SwiftUI

@main
struct LinkInJobApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(viewModel)
        }
        .commands {
            CommandMenu("Actions") {
                Button("Archive Selected") {
                    viewModel.archiveSelectedItem()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(viewModel.selectedItem == nil)
            }

            CommandMenu("Tools") {
                Button("Запустить Sync сейчас") {
                    Task {
                        await viewModel.runProcessingPipeline()
                    }
                }

                Divider()

                Button("Показать исходные файлы TXT") {
                    openSourceTXTFolder()
                }

                Button("Открыть лог последней синхронизации") {
                    viewModel.openLastSyncLog()
                }

                Divider()

                Menu("Метод перевода") {
                    ForEach(AppViewModel.TranslationMethod.allCases) { method in
                        Button(translationMenuTitle(for: method)) {
                            viewModel.translationMethod = method
                        }
                    }

                    Divider()

                    Button("Указать Google API key...") {
                        promptGoogleTranslateAPIKey()
                    }

                    Button("Очистить Google API key") {
                        viewModel.clearGoogleTranslateAPIKey()
                    }
                    .disabled(!viewModel.hasGoogleTranslateAPIKey)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
    }

    private func openSourceTXTFolder() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/DriveCVSync/LinkedIn Archive")
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
        }
    }

    private func translationMenuTitle(for method: AppViewModel.TranslationMethod) -> String {
        let marker = viewModel.translationMethod == method ? "✓ " : ""
        return "\(marker)\(method.title)"
    }

    private func promptGoogleTranslateAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Google Cloud Translate API key"
        alert.informativeText = "Введите API key для официального Google Translate API."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "AIza..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.setGoogleTranslateAPIKey(field.stringValue)
        }
    }
}
