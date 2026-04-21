import SwiftUI

@main
struct MistyLemurApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Gates on authentication status. Phone-OTP auth is delegated to Supabase
/// via the `API` client; until that returns a session token, we show sign-in.
struct RootView: View {
    @StateObject private var session = AppSession()

    var body: some View {
        Group {
            if session.userId == nil {
                SignInView(session: session)
            } else {
                TabView {
                    InboxView(session: session)
                        .tabItem { Label("Inbox", systemImage: "tray") }
                    ComposeView(session: session)
                        .tabItem { Label("Send", systemImage: "camera") }
                }
            }
        }
        .task { await session.restore() }
    }
}

@MainActor
final class AppSession: ObservableObject {
    @Published var userId: String?
    let api = API()

    func restore() async { userId = api.restoreStoredSession() }
    func signOut() { api.clearSession(); userId = nil }
}

struct SignInView: View {
    @ObservedObject var session: AppSession
    @State private var phone = ""
    @State private var code = ""
    @State private var stage: Stage = .phone

    enum Stage { case phone, code }

    var body: some View {
        VStack(spacing: 20) {
            Text("Misty Lemur").font(.largeTitle).bold()
            switch stage {
            case .phone:
                TextField("+1 555 555 5555", text: $phone).keyboardType(.phonePad)
                Button("Send code") {
                    Task { try? await session.api.requestOTP(phone: phone); stage = .code }
                }
            case .code:
                TextField("6-digit code", text: $code).keyboardType(.numberPad)
                Button("Verify") {
                    Task {
                        if let uid = try? await session.api.verifyOTP(phone: phone, code: code) {
                            session.userId = uid
                        }
                    }
                }
            }
        }.padding()
    }
}
