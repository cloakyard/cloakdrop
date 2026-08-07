import AppKit
import SwiftUI
import DownloadModels

/// The main window: a sidebar + content list with a persistent detail panel. System materials
/// supply Liquid Glass for the sidebar, toolbar, and detail chrome. The detail stays open so the
/// layout has a single, left-side collapse affordance.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        } detail: {
            PersistentInspectorSplitView()
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
        // One bottom toast slot: the "reading video" indicator, or the extraction error (which is
        // already localized by `friendlyExtractionMessage`). A single slot means the two can never
        // stack on top of each other; the error takes precedence when both would show.
        .overlay(alignment: .bottom) {
            if let error = model.mediaExtractionError {
                toast {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } else if model.isResolvingMedia {
                toast { Label("Reading video…", systemImage: "sparkles.tv") }
            }
        }
        .animation(.default, value: model.isResolvingMedia)
        .animation(.default, value: model.mediaExtractionError)
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

    /// The floating status capsule above the list. A hairline separator stroke keeps its edge
    /// defined in dark mode, where the shadow alone all but disappears.
    private func toast(@ViewBuilder content: () -> some View) -> some View {
        content()
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A Notes-style content/detail pair whose detail pane is part of the permanent window layout.
/// SwiftUI's `inspector` can still be collapsed by dragging its divider to the trailing edge even
/// when `isPresented` is always true. Keeping the detail in this bounded split prevents that hidden
/// state altogether while preserving a small, useful resize range.
private struct PersistentInspectorSplitView: View {
    private static let minimumWidth = 300.0
    private static let idealWidth = 320.0
    private static let maximumWidth = 360.0

    @AppStorage("mainInspectorWidth") private var storedWidth = Self.idealWidth

    private var inspectorWidth: CGFloat {
        CGFloat(storedWidth.clamped(to: Self.minimumWidth...Self.maximumWidth))
    }

    var body: some View {
        HStack(spacing: 0) {
            DownloadListView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            InspectorDivider(
                width: $storedWidth,
                range: Self.minimumWidth...Self.maximumWidth
            )

            InspectorView()
                .frame(width: inspectorWidth)
                .background(.regularMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { storedWidth = Double(inspectorWidth) }
    }
}

/// A one-point separator with a forgiving invisible hit target. The drag origin is captured once
/// per gesture so repeated updates remain stable, and every input path clamps to the same bounds.
private struct InspectorDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>

    @State private var dragOrigin: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                ResizeCursorArea(width: $width, range: range)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture)
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? width
                dragOrigin = origin
                width = (origin - value.translation.width).clamped(to: range)
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

/// Registers AppKit's native horizontal-resize cursor without balancing a manual cursor stack.
private struct ResizeCursorArea: NSViewRepresentable {
    @Binding var width: Double
    let range: ClosedRange<Double>

    func makeNSView(context: Context) -> CursorView {
        let view = CursorView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.slider)
        view.setAccessibilityLabel(String(localized: "Details"))
        return view
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.setAccessibilityMinValue(NSNumber(value: range.lowerBound))
        nsView.setAccessibilityMaxValue(NSNumber(value: range.upperBound))
        nsView.setAccessibilityValue(NSNumber(value: width))
        nsView.onAdjust = { delta in
            width = (width + delta).clamped(to: range)
        }
    }

    final class CursorView: NSView {
        var onAdjust: ((Double) -> Void)?

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func accessibilityPerformIncrement() -> Bool {
            onAdjust?(20)
            return true
        }

        override func accessibilityPerformDecrement() -> Bool {
            onAdjust?(-20)
            return true
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
