import SwiftUI
import UniformTypeIdentifiers

// AI CONTEXT — Views/WelcomeView.swift ("Welcome" page, see PAGES.md).
// First-run value-prop screen shown ONCE to a brand-new user (no real
// subscriptions AND !hasCompletedWelcome), presented as a fullScreenCover from
// RootView while the launch splash is still up so the transition is seamless
// (both share the purple launch background). It teaches the core model
// (subscribe → Autohop builds Up Next → it just plays) and offers the three
// ways forward: Find shows (Discover), Import (OPML), or Skip. The chosen path
// is reported back via `onComplete`; RootView sets hasCompletedWelcome and
// routes the NavigationStack. See ONBOARDING_PLAN.md Phase 2.

/// What the user chose on the Welcome screen. RootView maps each to a route.
enum WelcomeOutcome {
    case findShows            // → Discover
    case importedSubscriptions // OPML imported in-place → Subscriptions
    case skip                 // → Subscriptions (empty state)
}

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var importCoordinator: SubscriptionImportCoordinator
    @EnvironmentObject private var onboardingCoordinator: OnboardingCoordinator
    let onComplete: (WelcomeOutcome) -> Void

    @State private var showImporter = false
    @State private var isImporting = false
    @State private var panel = 0

    // Matches the launch splash so presenting over it is seamless.
    private let background = Color(red: 0.176, green: 0.149, blue: 0.502)

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $panel) {
                    panelView(
                        hero: AnyView(heroMotif),
                        title: "Welcome to Autohop",
                        body: "Subscribe to your shows and Autohop does the rest — it downloads the latest episodes, builds Up Next, and just plays. Like radio, but only your podcasts."
                    ).tag(0)

                    panelView(
                        hero: AnyView(iconHero("slider.horizontal.3")),
                        title: "Listen your way",
                        body: "Speed things up, trim the silences, and boost voices so every word is clear — automatically, on every episode."
                    ).tag(1)

                    panelView(
                        hero: AnyView(iconHero("moon.zzz.fill")),
                        title: "Made for real life",
                        body: "A sleep schedule that fades out when you nod off, and one-tap shared listening for the car. Set it once and forget it."
                    ).tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: 12) {
                    Button { onComplete(.findShows) } label: {
                        primaryLabel("Find shows")
                    }
                    .buttonStyle(.plain)

                    Button { showImporter = true } label: {
                        secondaryLabel(isImporting ? "Importing…" : "Import from another app")
                    }
                    .buttonStyle(.plain)
                    .disabled(isImporting)

                    Button { onComplete(.skip) } label: {
                        Text("I'll explore on my own")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .disabled(isImporting)
                }
                .adaptiveContentWidth(.form)
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
            }
        }
        .interactiveDismissDisabled(true)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.xml, .plainText, UTType(filenameExtension: "opml") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            isImporting = true
            Task {
                let summary = await importCoordinator.importOPML(from: url)
                if summary.imported > 0 {
                    onboardingCoordinator.toast = "Imported \(summary.imported) show\(summary.imported == 1 ? "" : "s") — welcome aboard."
                }
                isImporting = false
                onComplete(.importedSubscriptions)
            }
        }
    }

    // MARK: - Pieces

    /// One carousel panel: hero art, title, body — vertically centred.
    private func panelView(hero: AnyView, title: String, body: String) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .padding(.bottom, 24)
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 14)
                Text(body)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }
            .adaptiveContentWidth(.prose)
            .padding(.vertical, 28)
        }
    }

    /// Hero for panels 2–3: a single glyph in a soft circle.
    private func iconHero(_ systemName: String) -> some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 132, height: 132)
            Image(systemName: systemName)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(height: 132)
    }

    /// A calm, static echo of the launch waveform: purple bars → chevron → green
    /// bars, reinforcing the "your shows, on autopilot" brand mark.
    private var heroMotif: some View {
        HStack(spacing: 12) {
            bars([(40, 0.66, 0.62, 0.91), (92, 0.77, 0.74, 0.94), (64, 0.69, 0.66, 0.93), (28, 0.60, 0.56, 0.89)])
            Image(systemName: "chevron.right")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.24))
            bars([(34, 0.11, 0.73, 0.33), (92, 0.15, 0.82, 0.38), (56, 0.11, 0.73, 0.33), (24, 0.09, 0.66, 0.29)])
        }
        .frame(height: 100)
    }

    private func bars(_ specs: [(CGFloat, Double, Double, Double)]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: spec.1, green: spec.2, blue: spec.3))
                    .frame(width: 19, height: spec.0)
            }
        }
    }

    private func primaryLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Color(red: 0.176, green: 0.149, blue: 0.502))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Capsule().fill(.white))
    }

    private func secondaryLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Capsule().fill(.white.opacity(0.16)))
    }
}
