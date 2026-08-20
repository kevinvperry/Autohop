import SwiftUI

// AI CONTEXT — Complete, Release-build App Review demo shell. It consumes only
// TVDemoSession and bundled media, visibly labels synthetic content, and offers
// Reset/Exit. It intentionally reuses Autohop's tab vocabulary and 10-foot
// visual grammar without injecting fixtures into production observable models.

struct TVDemoRootView: View {
    let onExit: () -> Void
    @State private var session = TVDemoSession()
    @State private var selectedTab: TVDemoTab = .home
    @State private var playingEpisode: TVDemoEpisode?
    @State private var selectedShow: TVDemoShow?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: .home) { home }
            Tab("Subscriptions", systemImage: "books.vertical", value: .library) { library }
            Tab("History", systemImage: "clock.arrow.circlepath", value: .history) { history }
            Tab("Settings", systemImage: "gearshape", value: .settings) { settings }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(.purple)
        .background(TVBrandBackground())
        .overlay(alignment: .topTrailing) {
            Label("Demo Library", systemImage: "sparkles.tv")
                .font(.headline).padding(.horizontal, 16).padding(.vertical, 9)
                .background(.purple.opacity(0.85), in: Capsule()).padding(30)
        }
        .sheet(item: $selectedShow) { show in showDetail(show) }
        .fullScreenCover(item: $playingEpisode) { episode in
            TVDemoPlayerView(
                episode: episode,
                initialPosition: session.progressByEpisodeID[episode.id] ?? 0,
                onProgress: { session.recordProgress($0, for: episode) },
                onComplete: { session.markCompleted(episode); playingEpisode = nil },
                onExit: { playingEpisode = nil }
            )
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("Home").font(.largeTitle.bold())
                if let episode = session.continueEpisode {
                    heading("Continue Listening")
                    episodeButton(episode, subtitle: "\(Int(session.progressByEpisodeID[episode.id] ?? 0)) seconds played")
                }
                heading("Up Next")
                ForEach(session.upNext) { episode in
                    episodeButton(episode, subtitle: episode.mediaKind == .video ? "Video · \(episode.showTitle)" : episode.showTitle)
                        .contextMenu {
                            Button { session.playNext(episode) } label: { Label("Play Next", systemImage: "text.insert") }
                            Button(role: .destructive) { session.archive(episode) } label: { Label("Archive", systemImage: "archivebox") }
                        }
                }
            }.padding(.horizontal, 80).padding(.vertical, 60)
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Subscriptions").font(.largeTitle.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 36)], spacing: 36) {
                    ForEach(session.shows) { show in
                        Button { selectedShow = show } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                TVDemoArtwork(title: show.title, colorHex: show.colorHex).aspectRatio(1, contentMode: .fit)
                                Text("#\(show.priority) · \(show.title)").font(.title3.bold()).lineLimit(2)
                                Text(show.author).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.card)
                    }
                }
            }.padding(.horizontal, 80).padding(.vertical, 60)
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("History").font(.largeTitle.bold())
                ForEach(session.history) { item in
                    episodeButton(item.episode, subtitle: "\(item.status.rawValue) · \(item.listenedAt.formatted(.relative(presentation: .named)))")
                }
            }.padding(.horizontal, 80).padding(.vertical, 60)
        }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Demo Settings").font(.largeTitle.bold())
                Label("This demonstration is stored only in memory. It never writes subscriptions, playback history, queue changes or statistics to your private iCloud library.", systemImage: "lock.icloud")
                    .font(.title3).padding(24).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                Button { session.reset(); selectedTab = .home } label: { Label("Reset Demo Library", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.bordered)
                Button(role: .destructive, action: onExit) { Label("Exit Demo", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(.borderedProminent)
            }.padding(.horizontal, 80).padding(.vertical, 60)
        }
    }

    private func showDetail(_ show: TVDemoShow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 28) {
                    TVDemoArtwork(title: show.title, colorHex: show.colorHex).frame(width: 220, height: 220)
                    VStack(alignment: .leading) { Text(show.title).font(.largeTitle.bold()); Text(show.author).font(.title3).foregroundStyle(.secondary) }
                }
                ForEach(show.episodes) { episode in episodeButton(episode, subtitle: episode.summary) }
            }.padding(60)
        }
    }

    private func episodeButton(_ episode: TVDemoEpisode, subtitle: String) -> some View {
        Button { playingEpisode = episode } label: {
            HStack(spacing: 22) {
                TVDemoArtwork(title: episode.showTitle, colorHex: episode.mediaKind == .video ? 0xB42372 : 0x6633CC).frame(width: 130, height: 130)
                VStack(alignment: .leading, spacing: 8) { Text(episode.title).font(.title3.bold()).lineLimit(2); Text(subtitle).foregroundStyle(.secondary).lineLimit(2) }
                Spacer(); Image(systemName: episode.mediaKind == .video ? "play.rectangle.fill" : "play.fill").font(.title2)
            }.padding(18).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.card)
    }

    private func heading(_ text: String) -> some View { Text(text).font(.title2.bold()) }
}

private enum TVDemoTab: Hashable { case home, library, history, settings }

struct TVDemoArtwork: View {
    let title: String
    let colorHex: UInt
    var body: some View {
        let color = Color(red: Double((colorHex >> 16) & 255) / 255, green: Double((colorHex >> 8) & 255) / 255, blue: Double(colorHex & 255) / 255)
        ZStack {
            LinearGradient(colors: [color, color.opacity(0.48), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "waveform").font(.system(size: 72, weight: .bold)).foregroundStyle(.white.opacity(0.86))
            Text(title).font(.headline).multilineTextAlignment(.center).foregroundStyle(.white).padding(18).frame(maxHeight: .infinity, alignment: .bottom)
        }.clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
