import SwiftUI

struct InboxMessage: Identifiable {
    let id: String
    let senderHandle: String
    let requiredDurationMs: Int
    let locked: Bool
    let viewed: Bool
    let tracePreview: [TracePoint]
    let expiresAt: Date?              // group rounds only — drives the live countdown
    let isLateResponse: Bool          // true if the responder snuck in within the last 10%
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
                    InboxRow(msg: msg)
                }
            }
            .navigationTitle("Inbox")
            .task { messages = (try? await session.api.fetchInbox()) ?? [] }
        }
    }
}

struct InboxRow: View {
    let msg: InboxMessage

    var body: some View {
        HStack(spacing: 12) {
            TraceThumbnailView(
                trace: msg.tracePreview,
                durationMs: msg.requiredDurationMs,
                state: thumbnailState
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(msg.senderHandle).font(.headline)
                    if msg.isLateResponse {
                        Text("LATE").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text("\(Double(msg.requiredDurationMs) / 1000.0, specifier: "%.1f")s motion to unlock")
                    .font(.caption).foregroundColor(.secondary)
                if let countdown = countdownText {
                    HStack(spacing: 2) {
                        Image(systemName: "timer").font(.caption2)
                        Text(countdown).font(.caption.monospacedDigit())
                    }.foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var thumbnailState: TraceThumbnailView.ThumbnailState {
        if msg.locked { return .locked }
        if msg.viewed { return .viewed }
        return .unlocked
    }

    /// Live "Xh Ym" until a group round expires. Only shown for group messages.
    private var countdownText: String? {
        guard let expires = msg.expiresAt else { return nil }
        let interval = expires.timeIntervalSinceNow
        if interval <= 0 { return "expired" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
