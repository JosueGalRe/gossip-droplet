import DroppyKit
import SwiftUI

/// The phone's SMS conversations: the list, then one conversation with a field to answer in. Gossip refreshes the list
/// only while this page is on screen.
struct MessagesPage: View {
    @ObservedObject var droplet: GossipDroplet
    let context: ShelfWidgetContext

    var body: some View {
        Group {
            if context.isCompact {
                compactBody
            } else if let thread = droplet.openThread {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    HStack(spacing: DroppySpacing.xsm) {
                        Button { droplet.openThread(nil) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(DroppyCircleButtonStyle(size: 20))
                            .accessibilityLabel("All conversations")
                        Text(thread.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .droppyFlatGlassControls()
                    Conversation(droplet: droplet, thread: thread)
                }
            } else if droplet.threads.isEmpty {
                Message(text: droplet.messagesError ?? (droplet.messagesLoading ? "Loading conversations…" : "No conversations"))
            } else {
                ThreadList(droplet: droplet)
            }
        }
        .onAppear { droplet.messagesVisible(true) }
        .onDisappear { droplet.messagesVisible(false) }
    }

    /// Narrow: the three newest conversations, each a button to the full widget in that conversation.
    @ViewBuilder private var compactBody: some View {
        if droplet.threads.isEmpty {
            Message(text: droplet.messagesLoading ? "Loading conversations…" : "No conversations")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(droplet.threads.prefix(4)) { thread in
                    Button { droplet.open(thread) } label: {
                        HStack(spacing: DroppySpacing.sm) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(thread.title)
                                    .font(.system(size: 12, weight: thread.unread > 0 ? .bold : .semibold))
                                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                                Text((thread.outgoing ? "You: " : "") + thread.snippet)
                                    .font(.system(size: 11))
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 0)
                            if thread.unread > 0 { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                        }
                        .padding(.horizontal, DroppySpacing.xs)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .hoverHighlight()
                    }
                    .buttonStyle(.plain)
                }
                if droplet.threads.count > 4 {
                    SeeAllButton(count: droplet.threads.count) { droplet.reveal(.messages) }
                        .padding(.top, DroppySpacing.xs)
                }
            }
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
