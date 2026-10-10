import SwiftUI

struct MLNotificationsView: View {
    @Environment(MLRuntime.self) private var runtime
    @State private var store = MLPageStore()
    @State private var external: URL?
    @State private var confirmation = false
    @State private var originalUnread = 0
    @State private var reads = MLReadActions()
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack { MLSectionHeading(title: "Notifications", subtitle: "Updates from AniList, refreshed when you open this page."); Button("Refresh", systemImage: "arrow.clockwise") { reads.run { await load(reset: true, refresh: true) } }.labelStyle(.iconOnly).disabled(store.loading) }
                MLStaleBanner(date: store.staleDate, partial: store.partial)
                if let error = store.error { MLErrorBanner(message: error) }
                let notifications = store.data.notifications?.compactMap { $0 } ?? []
                ForEach(Array(notifications.enumerated()), id: \.element.id) { index, notification in
                    Button { open(notification) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            if let media = notification.media { MLArtwork(url: media.coverImage?.medium, width: 34, height: 48) }
                            else if let user = notification.user { MLArtwork(url: user.avatar?.medium, width: 34, height: 34, radius: 17) }
                            else { Image(systemName: "bell").frame(width: 34) }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(notification.type?.mlWords ?? "AniList update").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text([notification.user?.name, notification.context ?? notification.contexts?.joined(separator: " "), notification.media?.name].compactMap { $0 }.joined(separator: " ")).font(.callout).multilineTextAlignment(.leading)
                                if let created = notification.createdAt { Text(Date(timeIntervalSince1970: Double(created)), format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if index < originalUnread { Circle().fill(.tint).frame(width: 6, height: 6).accessibilityLabel("New") }
                        }.padding(14).modifier(MLPanel())
                    }.buttonStyle(.plain)
                }
                if store.page > 0 && notifications.isEmpty { ContentUnavailableView("You’re all caught up", systemImage: "bell") }
                MLLoadMoreView(store: store) { await load() }
            }.padding(26).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.mlTask(id: "notifications/\(runtime.viewer?.id ?? 0)") { originalUnread = runtime.viewer?.unreadNotificationCount ?? 0; await load(reset: true) }
            .mlReadActions(reads, id: "\(runtime.viewer?.id ?? 0)")
            .alert("Open this content in your browser?", isPresented: $confirmation) {
                Button("Cancel", role: .cancel) { external = nil }
                Button("Open") { if let external { NSWorkspace.shared.open(external) }; external = nil }
            } message: { Text("MaoList can’t accurately display this content natively. Open it in your browser?") }
    }
    private func load(reset: Bool = false, refresh: Bool = false) async {
        await store.load(reset: reset, preservingData: reset) { try await runtime.repository.notifications(page: $0, refresh: refresh) }
        if store.error == nil { await runtime.refreshViewer() }
    }
    private func open(_ notification: MLNotification) {
        if let media = notification.media { runtime.routes.append(.media(media.id)) }
        else if let id = notification.activityId { runtime.routes.append(.activity(id)) }
        else if let url = notification.thread?.siteUrl { external = url; confirmation = true }
        else if let user = notification.user { runtime.routes.append(.profile(user.id)) }
    }
}

struct MLSingleActivityView: View {
    @Environment(MLRuntime.self) private var runtime
    let id: Int
    @State private var activity: MLActivity?
    @State private var error: String?
    @State private var stale: Date?
    @State private var partial = false
    @State private var retryRevision = 0
    var body: some View {
        ScrollView {
            VStack {
                MLStaleBanner(date: stale, partial: partial)
                if let activity { MLActivityCard(activity: activity) }
                else if let error { MLErrorBanner(message: error); Button("Retry") { retryRevision += 1 } }
                else { ProgressView("Loading activity…") }
            }.padding(26).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }.mlTask(id: "activity/\(id)/\(retryRevision)") {
            error = nil
            do { let value = try await runtime.repository.activity(id, refresh: retryRevision > 0); try Task.checkCancellation(); activity = value.value; stale = value.cachedAt; partial = value.isPartial; if value.value == nil { error = "This activity is no longer available." } }
            catch { if !(error is CancellationError) { self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription } }
        }
    }
}
struct MLReviewDetailView: View {
    @Environment(MLRuntime.self) private var runtime
    let id: Int
    @State private var review: MLReview?
    @State private var error: String?
    @State private var stale: Date?
    @State private var partial = false
    @State private var retryRevision = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MLStaleBanner(date: stale, partial: partial)
                if let review {
                    Text(review.summary ?? "Review").font(.title.bold())
                    if let user = review.user { MLUserButton(user: user) }
                    MLRichText(text: review.body ?? "The review text isn’t available.", fallbackURL: URL(string: "https://anilist.co/review/\(id)"))
                } else if let error { MLErrorBanner(message: error); Button("Retry") { retryRevision += 1 } }
                else { ProgressView("Loading review…") }
            }.padding(26).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.mlTask(id: "review/\(id)/\(retryRevision)") {
            error = nil
            do { let value = try await runtime.repository.review(id, refresh: retryRevision > 0); try Task.checkCancellation(); review = value.value; stale = value.cachedAt; partial = value.isPartial; if value.value == nil { error = "This review is no longer available." } }
            catch { if !(error is CancellationError) { self.error = (error as? MLError)?.localizedDescription ?? MLError.offline.localizedDescription } }
        }
    }
}
