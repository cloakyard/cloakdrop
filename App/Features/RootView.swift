import SwiftUI
import DownloadModels

/// The main window: a sidebar + content list with a persistent detail inspector. The system
/// supplies Liquid Glass for the sidebar, toolbar, and inspector chrome. The inspector stays
/// open (no collapse control) so the layout has a single, left-side collapse affordance.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        } detail: {
            DownloadListView()
                .inspector(isPresented: .constant(true)) {
                    InspectorView()
                        .inspectorColumnWidth(min: 300, ideal: 320, max: 360)
                }
        }
        .sheet(isPresented: $model.isAddSheetPresented) {
            AddDownloadSheet()
        }
        .sheet(isPresented: $model.isBatchSheetPresented) {
            BatchAddSheet()
        }
        // A streaming manifest resolved into renditions — pick a quality before the grab is queued.
        .sheet(item: $model.pendingMediaSelection) { selection in
            MediaPickerSheet(selection: selection)
        }
        // Brief, non-blocking indicator while a manifest URL is being fetched and parsed.
        .overlay(alignment: .bottom) {
            if model.isResolvingMedia {
                Label("Checking stream…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.isResolvingMedia)
        // A download for the same URL already exists — confirm before adding a duplicate. Fires for
        // every intake path (sheet, batch, drop, clipboard, browser/`cloakdrop://` capture). The
        // buttons drive the FIFO, so the isPresented setter is intentionally a no-op.
        .alert(
            "Download Again?",
            isPresented: Binding(get: { model.currentDuplicateAdd != nil }, set: { _ in }),
            presenting: model.currentDuplicateAdd
        ) { duplicate in
            Button("Download Again") { model.confirmDuplicateAdd() }
            if duplicate.existingIsOnDisk {
                Button("Reveal in Finder") { model.revealExistingDuplicate() }
            }
            Button("Cancel", role: .cancel) { model.cancelDuplicateAdd() }
        } message: { duplicate in
            switch duplicate.reason {
            case .sameURL:
                Text("“\(duplicate.existingFileName)” is already in your downloads. Download it again?")
            case .sameETag:
                Text("You already downloaded “\(duplicate.existingFileName)” from this server. Download it again?")
            case .sameContent:
                Text("“\(duplicate.existingFileName)” — same name and size — is already in your downloads. Download it again?")
            }
        }
    }
}
