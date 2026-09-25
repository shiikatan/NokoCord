import SwiftUI

enum NokoDestination: String, CaseIterable, Identifiable {
    case home, discord, downloads, shortcuts, privacy, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .discord: String(localized: "Discord")
        case .downloads: String(localized: "Downloads")
        case .shortcuts: String(localized: "Keyboard shortcuts")
        case .privacy: String(localized: "Privacy")
        case .settings: String(localized: "Settings")
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .discord: "bubble.left.and.bubble.right"
        case .downloads: "arrow.down.circle"
        case .shortcuts: "command"
        case .privacy: "hand.raised"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(ActiveBrowserEngine.self) private var browser
    @Binding var selection: NokoDestination
    @Binding var showQuickSwitcher: Bool
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Home", systemImage: "house").tag(NokoDestination.home)
                Label("Discord", systemImage: "bubble.left.and.bubble.right").tag(NokoDestination.discord)
                Section {
                    Label("Downloads", systemImage: "arrow.down.circle").tag(NokoDestination.downloads)
                    Label("Shortcuts", systemImage: "command").tag(NokoDestination.shortcuts)
                    Label("Privacy", systemImage: "hand.raised").tag(NokoDestination.privacy)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("NokoCord")
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Button("Quick switcher", systemImage: "command") { showQuickSwitcher = true }
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }.buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        } detail: {
            Group {
                switch selection {
                case .downloads: BrowserSettingsView()
                case .privacy: PrivacyPage()
                case .shortcuts: KeyboardShortcutsView()
                default: home
                }
            }.navigationTitle(selection == .home ? "" : selection.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, destination in
            if destination == .discord { browser.openDiscord() }
        }
        .nokoCordAppearance()
    }
    private var home: some View { TanHubView() }
}

private struct HomeAction: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(17).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .contentShape(.rect(cornerRadius: 14))
        }.buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor).opacity(hovered ? 1 : 0.65), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovered ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
            .onHover { hovered = $0 }
    }
}

struct NokoPageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
                .frame(width: 48, height: 48).background(.tint.opacity(0.1), in: .rect(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(28)
    }
}

struct PrivacyPage: View {
    var body: some View {
        VStack(spacing: 0) {
            NokoPageHeader(title: "Privacy", subtitle: "Control what stays on this Mac.", symbol: "hand.raised")
            ScrollView {
                GroupBox { DiscordSessionControls() } label: { Text("Discord session").font(.headline) }
                    .frame(maxWidth: 760, alignment: .leading).padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct NokoSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    @AppStorage("useLiquidGlass") private var useLiquidGlass = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if !useLiquidGlass || reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.12)))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

struct NokoPrimaryAction: ViewModifier {
    @AppStorage("useLiquidGlass") private var useLiquidGlass = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if useLiquidGlass && !reduceTransparency && contrast != .increased {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct NokoQuickSwitcher: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: NokoDestination? = .home
    @FocusState private var focused: Bool
    let navigate: (NokoDestination) -> Void
    private var matches: [NokoDestination] {
        NokoDestination.allCases.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to…", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { activate() }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if matches.isEmpty {
                Text("No matching destinations").foregroundStyle(.secondary).padding()
            }
            ForEach(matches) { destination in
                Button {
                    dismiss(); navigate(destination)
                } label: {
                    HStack { Label(destination.title, systemImage: destination.symbol); Spacer(); if selected == destination { Image(systemName: "return") } }
                        .padding(12).contentShape(Rectangle())
                        .background(selected == destination ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }.padding(14).frame(width: 480)
            .onAppear { focused = true }
            .onChange(of: query) { _, _ in selected = matches.first }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
    }
    private func move(_ offset: Int) {
        guard !matches.isEmpty else { selected = nil; return }
        let index = matches.firstIndex(where: { $0 == selected }) ?? 0
        selected = matches[min(max(index + offset, 0), matches.count - 1)]
    }
    private func activate() {
        guard let destination = selected, matches.contains(destination) else { return }
        dismiss(); navigate(destination)
    }
}

struct KeyboardShortcutsView: View {
    var body: some View {
        VStack(spacing: 0) {
            NokoPageHeader(title: "Keyboard shortcuts", subtitle: "A few keys. Right where you want to be.", symbol: "command")
            ScrollView {
                VStack(spacing: 0) {
                    shortcut("Toggle Tans Inspector", keys: ["⌘", "T"], spoken: "Command T")
                    Divider()
                    shortcut("Quick switcher", keys: ["⌘", "K"], spoken: "Command K")
                    Divider()
                    shortcut("Settings", keys: ["⌘", ","], spoken: "Command comma")
                    Divider()
                    shortcut("Reload Discord", keys: ["⌘", "R"], spoken: "Command R")
                }.padding(.horizontal, 20)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
                Text("Reloading Discord interrupts active calls and playback.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 16)
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }
    }
    private func shortcut(_ title: String, keys: [String], spoken: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 5) {
                ForEach(keys, id: \.self) { key in
                    Text(key).font(.body.monospaced()).frame(minWidth: 26, minHeight: 28)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                }
            }
        }.padding(.vertical, 14).accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(spoken)")
    }
}

struct SettingsView: View {
    @AppStorage("useLiquidGlass") private var useLiquidGlass = true
    @AppStorage("openDiscordOnLaunch") private var openDiscordOnLaunch = true
    @AppStorage("showMenuBar") private var showMenuBar = false
    @AppStorage("appearance") private var appearance = "system"
    @Environment(ActiveBrowserEngine.self) private var browser
    @State private var confirmLocalCleanup = false
    @State private var cleanupMessage: String?
    @State private var cleaning = false
    var body: some View {
        TabView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("NokoMark").renderingMode(.original).resizable().scaledToFit().frame(width: 56, height: 56)
                            .clipShape(.rect(cornerRadius: 14)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("NokoCord").font(.title2.bold())
                            Text("Made by shiikatan").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                Section("Appearance") {
                    Picker("Color scheme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }.pickerStyle(.radioGroup)
                    Toggle("Liquid Glass", isOn: $useLiquidGlass)
                    Text("Use translucent controls and surfaces. Accessibility settings take priority.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Show NokoCord in menu bar", isOn: $showMenuBar)
                }
                Section("Startup") {
                    Toggle("Open Discord on Launch", isOn: $openDiscordOnLaunch)
                    Text("Discord loads directly at launch. Tans are integrated inside the window.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About") {
                    if let edition = EditionIdentity.current {
                        LabeledContent("Version", value: edition.publicVersion)
                        LabeledContent("Edition", value: edition.name)
                        LabeledContent("Maintainer", value: edition.maintainer)
                    } else {
                        LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    }
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                DiscordSessionPrivacySection()
                Section { Label("No analytics or telemetry", systemImage: "hand.raised") }
            }.formStyle(.grouped).tabItem { Label("Privacy", systemImage: "hand.raised") }
            Form {
                Section("Diagnostics") { LabeledContent("Engine", value: browser.engineDescription) }
                Section("Maintenance") {
                    Button("Clear app caches and saved drafts…", role: .destructive) { confirmLocalCleanup = true }
                        .disabled(cleaning)
                    if cleaning { ProgressView("Clearing local data") }
                    if let cleanupMessage { Text(cleanupMessage).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }.frame(width: 640, height: 480).nokoCordAppearance()
            .confirmationDialog("Clear app caches and saved drafts?", isPresented: $confirmLocalCleanup, titleVisibility: .visible) {
                Button("Clear local data", role: .destructive) {
                    cleaning = true
                    Task {
                        do {
                            try await DraftStore.shared.clearAll()
                            try await AccountCache().clear()
                            await AvatarPipeline.shared.clear()
                            cleanupMessage = String(localized: "Local caches and saved drafts cleared.")
                        } catch {
                            cleanupMessage = String(localized: "Some local data could not be cleared. Try again.")
                        }
                        cleaning = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes NokoCord’s local caches and saved drafts. Your Discord session and downloaded files are kept.")
            }
    }
}

private struct NokoCordAppearance: ViewModifier {
    @AppStorage("appearance") private var appearance = "system"
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}

extension View {
    func nokoCordAppearance() -> some View { modifier(NokoCordAppearance()) }
}
