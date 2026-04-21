import SwiftUI

struct InboxMessage: Identifiable {
    let id: String
    let senderHandle: String
    let requiredDurationMs: Int
    let locked: Bool
}

struct InboxView: View {
    @ObservedObject var session: AppSession
    @State private var messages: [InboxMessage] = []

    var body: some View {
        NavigationView {
            List(messages) { msg in
                NavigationLink {
                    UnlockAttemptView(session: session, message: msg)
                } label: {
                    HStack {
                        Image(systemName: msg.locked ? "lock.fill" : "play.circle")
                        VStack(alignment: .leading) {
                            Text(msg.senderHandle).font(.headline)
                            Text("\(Double(msg.requiredDurationMs) / 1000.0, specifier: "%.1f")s motion to unlock")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Inbox")
            .task { messages = (try? await session.api.fetchInbox()) ?? [] }
        }
    }
}
