import SwiftUI

/// The app's one navigation stack. Its root is where the app is: the connect
/// screen, or the events screen of the demo or of a server. An event pushes
/// the playback screen onto the same stack.
struct RootView: View {
    @State private var model = AppModel()
    @State private var path: [RecordedEvent] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: RecordedEvent.self) { event in
                    PlaybackScreen(event: event)
                }
        }
        .environment(model)
        .tint(.action)
        .task { model.restore() }
        .onChange(of: model.mode) { old, new in
            // Another place entirely: nothing of the old stack is still true.
            if old != new { path.removeAll() }
        }
        .sheet(isPresented: Binding(
            get: { model.sessionExpired },
            set: { if !$0 { model.dismissSessionNotice() } }
        )) {
            ReconnectSheet()
        }
    }

    @ViewBuilder
    private var root: some View {
        switch model.mode {
        case .connect:
            ConnectScreen()
        case .demo, .server:
            EventsScreen()
        }
    }
}
