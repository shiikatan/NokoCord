import SwiftUI
import AppKit

/// Sleek macOS Liquid Glass drawer displaying private locally saved Discord messages.
/// Accessible via ⌘⇧B, the Command Palette (⌘K), or the workspace toolbar.
struct BookmarksDrawerView: View {
    @Binding var isPresented: Bool
    var onOpenURL: ((URL) -> Void)?

    @State private var store = BookmarkStore.shared
    @State private var searchText = ""
    @State private var hoveredBookmarkId: String?
    @State private var copiedBookmarkId: String?

    private var filteredBookmarks: [NokoBookmark] {
        store.search(query: searchText)
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Saved Messages")
                                .font(.system(size: 15, weight: .bold))
                            if !store.bookmarks.isEmpty {
                                Text("\(store.bookmarks.count)")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                            }
                        }
                        Text("Private to this Mac • Zero network tracking")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        withAnimation(.nokoFluidSpring) {
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Search saved messages, users, servers…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                Divider()
                    .background(Color.white.opacity(0.08))

                // Content List
                if filteredBookmarks.isEmpty {
                    VStack(spacing: 14) {
                        Spacer()
                        Image(systemName: searchText.isEmpty ? "bookmark" : "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)

                        Text(searchText.isEmpty ? "No Saved Messages Yet" : "No Matches Found")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(searchText.isEmpty ?
                             "Hover over any message in Discord and press ⌘S to bookmark it permanently." :
                             "Try searching for a different word, author, or server.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredBookmarks) { bookmark in
                                BookmarkRowView(
                                    bookmark: bookmark,
                                    isHovered: hoveredBookmarkId == bookmark.id,
                                    isCopied: copiedBookmarkId == bookmark.id,
                                    onCopy: {
                                        copyBookmark(bookmark)
                                    },
                                    onJump: {
                                        jumpToMessage(bookmark)
                                    },
                                    onDelete: {
                                        withAnimation(.nokoSnappySpring) {
                                            store.remove(id: bookmark.id)
                                        }
                                    }
                                )
                                .onHover { hovering in
                                    hoveredBookmarkId = hovering ? bookmark.id : nil
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
            }
            .frame(width: 440)
            .frame(maxHeight: .infinity)
            .background(
                ZStack {
                    Color(nsColor: NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 0.94))
                    Rectangle()
                        .fill(.ultraThinMaterial.opacity(0.8))
                }
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 0.5)
            }
            .shadow(color: Color.black.opacity(0.4), radius: 30, x: -10, y: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func copyBookmark(_ bookmark: NokoBookmark) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(bookmark.content, forType: .string)
        withAnimation(.nokoSnappySpring) {
            copiedBookmarkId = bookmark.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedBookmarkId == bookmark.id {
                withAnimation(.nokoSnappySpring) {
                    copiedBookmarkId = nil
                }
            }
        }
    }

    private func jumpToMessage(_ bookmark: NokoBookmark) {
        if let url = URL(string: bookmark.messageURL), BrowserPolicy.isDiscordOrigin(url) {
            onOpenURL?(url)
            withAnimation(.nokoFluidSpring) {
                isPresented = false
            }
        }
    }
}

private struct BookmarkRowView: View {
    let bookmark: NokoBookmark
    let isHovered: Bool
    let isCopied: Bool
    var onCopy: () -> Void
    var onJump: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top author and location header
            HStack(spacing: 8) {
                if let avatarURL = bookmark.authorAvatarURL, let url = URL(string: avatarURL) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Circle().fill(Color.accentColor.opacity(0.4))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Text(String(bookmark.authorName.prefix(1)).uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.authorName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        if !bookmark.serverName.isEmpty {
                            Text(bookmark.serverName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("•")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        Text("#\(bookmark.channelName)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                }

                Spacer()

                Text(bookmark.createdAt, style: .date)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // Message Content
            if !bookmark.content.isEmpty {
                Text(bookmark.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(8)
                    .textSelection(.enabled)
            }

            // Media attachment preview thumbnail (if any)
            if let mediaURL = bookmark.mediaURL, let url = URL(string: mediaURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: 160)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }

            // Action toolbar
            HStack(spacing: 8) {
                Spacer()

                Button {
                    onCopy()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isCopied ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    onJump()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.up.right")
                        Text("Jump to Chat")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .opacity(isHovered ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .padding(14)
        .background(
            Color.white.opacity(isHovered ? 0.07 : 0.03),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(isHovered ? 0.15 : 0.06), lineWidth: 0.5)
        )
    }
}
