import DroppyKit
import SwiftUI

/// The phone's SMS conversations: the list, then one conversation with a field to answer in. Gossip refreshes the list
/// only while this widget is on screen.
struct MessagesWidget: View {
    @ObservedObject var droplet: GossipDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            ConnectionGate(droplet: droplet) {
                if context.isCompact {
                    compactBody
                } else if let thread = droplet.openThread {
                    Conversation(droplet: droplet, thread: thread)
                } else if droplet.threads.isEmpty {
                    Message(text: droplet.messagesError ?? (droplet.messagesLoading ? "Loading conversations…" : "No conversations"))
                } else {
                    ThreadList(droplet: droplet)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { droplet.messagesVisible(true) }
        .onDisappear { droplet.messagesVisible(false) }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            if !context.isCompact, droplet.openThread != nil {
                Button { droplet.openThread(nil) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .accessibilityLabel("All conversations")
            } else {
                Image(systemName: "message")
                    .font(.system(size: 12, weight: .medium))
            }
            Text(droplet.openThread?.title ?? "Messages")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if droplet.messagesLoading {
                ProgressView().controlSize(.mini)
            }
            if !context.isCompact, droplet.openThread == nil {
                Button { droplet.openInGossip("messages") } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help("New message in Gossip")
                    .accessibilityLabel("New message")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .droppyFlatGlassControls()
    }

    @ViewBuilder private var compactBody: some View {
        if let latest = droplet.threads.first {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text(latest.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text(latest.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(2)
                if droplet.unreadCount > 0 {
                    Text("\(droplet.unreadCount) unread")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
            .lineLimit(1)
        } else {
            Message(text: "No conversations")
        }
    }
}

private struct ThreadList: View {
    @ObservedObject var droplet: GossipDroplet

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    ForEach(droplet.threads) { thread in
                        Button { droplet.openThread(thread) } label: {
                            HStack(spacing: DroppySpacing.sm) {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: DroppySpacing.xs) {
                                        Text(thread.title)
                                            .font(.system(size: 12, weight: thread.unread > 0 ? .bold : .semibold))
                                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                                        Text(RelativeTime.short(Date(timeIntervalSince1970: thread.date), now: timeline.date))
                                            .font(.system(size: 11))
                                            .monospacedDigit()
                                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                                    }
                                    Text((thread.outgoing ? "You: " : "") + thread.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                                if thread.unread > 0 {
                                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                                        .accessibilityLabel("\(thread.unread) unread")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct Conversation: View {
    @ObservedObject var droplet: GossipDroplet
    let thread: MessageThread
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: DroppySpacing.sm) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DroppySpacing.xs) {
                        if droplet.conversation.isEmpty {
                            Message(text: droplet.messagesError ?? "Loading…")
                        }
                        ForEach(droplet.conversation) { message in
                            Bubble(message: message).id(message.id)
                        }
                    }
                }
                .onChange(of: droplet.conversation.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onAppear {
                    if let last = droplet.conversation.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            HStack(spacing: DroppySpacing.sm) {
                TextField("Text message", text: $droplet.composeText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .focused($focused)
                    .onSubmit { droplet.sendMessage() }
                    .onExitCommand { droplet.openThread(nil) }
                Button("Send") { droplet.sendMessage() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(droplet.composeText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true }
    }
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 40) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 1) {
                Text(message.body)
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .padding(.horizontal, DroppySpacing.sm)
                    .padding(.vertical, DroppySpacing.xs)
                    .background(message.outgoing ? Color.accentColor.opacity(0.55) : AdaptiveColors.notchSurfaceCardFill,
                                in: RoundedRectangle(cornerRadius: DroppyRadius.ml, style: .continuous))
                if message.failed || message.sending {
                    Text(message.failed ? "Not sent" : "Sending…")
                        .font(.system(size: 10))
                        .foregroundStyle(message.failed ? Color.red : AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
            if !message.outgoing { Spacer(minLength: 40) }
        }
    }
}
