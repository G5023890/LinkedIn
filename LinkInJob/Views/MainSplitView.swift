import SwiftUI

struct MainSplitView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showsSidebar = true

    var body: some View {
        NavigationStack {
            HSplitView {
                if showsSidebar {
                    SidebarView()
                        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                        .background(Color(nsColor: .windowBackgroundColor))
                }

                ApplicationListView()
                    .frame(minWidth: 380, idealWidth: 430, maxWidth: 560)
                    .background(Color(nsColor: .windowBackgroundColor))

                DetailView(item: viewModel.selectedItem)
                    .frame(minWidth: 480, idealWidth: 640, maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                SplitViewAutosaveInstaller(autosaveName: "LinkInJob.MainSplit")
            )
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            showsSidebar.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .help(showsSidebar ? "Hide Sidebar" : "Show Sidebar")
                }

                ToolbarItem(placement: .principal) {
                    Text("Applications")
                        .font(.headline)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            WindowFrameAutosaveInstaller(autosaveName: "LinkInJob.MainWindow")
        )
        .frame(minWidth: 1080, minHeight: 720)
        .task {
            await viewModel.loadFromBridge()
        }
    }
}
