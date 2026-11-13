import SwiftUI

/// One page of the home hero: what to show (movie or series) and what the play button starts.
struct HeroEntry: Identifiable {
    let display: BaseItem       // movie or series (artwork, logo, genres)
    let target: BaseItem?       // episode or movie to play; nil → resolve when tapped
    var id: String { display.id }

    var playLabel: String {
        guard let target else { return String(localized: "Play") }
        let resume = target.resumeTicks > 0
        if target.type == "Episode", let label = target.shortEpisodeLabel {
            return resume ? String(localized: "Resume \(label)") : String(localized: "Play \(label)")
        }
        return resume ? String(localized: "Resume") : String(localized: "Play")
    }
}

/// Full-width artwork carousel with title logo, genres, play and "My List" buttons.
struct HeroCarousel: View {
    @Environment(AppModel.self) private var app
    let title: LocalizedStringKey
    let entries: [HeroEntry]
    let topInset: CGFloat
    let favorites: Set<String>
    let onOpen: (BaseItem) -> Void
    let onPlay: (HeroEntry) -> Void
    let onToggleFavorite: (BaseItem) -> Void

    @State private var page = 0
    @State private var lastInteraction = Date()

    private let height: CGFloat = 560

    var body: some View {
        VStack(spacing: 16) {
            TabView(selection: $page) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    page(for: entry).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: height + topInset)
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8)
                    .padding(.horizontal)
                    .padding(.top, topInset + 8)
                    .allowsHitTesting(false)
            }
            .onChange(of: page) { lastInteraction = .now }

            if entries.count > 1 {
                PageDots(count: entries.count, current: page)
            }
        }
        .task(id: entries.map(\.id)) { await autoAdvance() }
    }

    private func page(for entry: HeroEntry) -> some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: app.api?.heroBackdropURL(for: entry.display), placeholderSymbol: "film")
                .frame(height: height + topInset)
                .frame(maxWidth: .infinity)
                .clipped()

            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset + 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 300)
            }
            .allowsHitTesting(false)

            VStack(spacing: 14) {
                TitleLogo(item: entry.display, maxHeight: 90)
                    .padding(.horizontal, 40)

                metaLine(for: entry.display)

                HStack(spacing: 12) {
                    Button { onPlay(entry) } label: {
                        Label(entry.playLabel, systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 26)
                            .frame(height: 52)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.15)))
                    }
                    Button { onToggleFavorite(entry.display) } label: {
                        Image(systemName: favorites.contains(entry.display.id) ? "checkmark" : "plus")
                            .font(.title3.weight(.semibold))
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.15)))
                    }
                    .accessibilityLabel(favorites.contains(entry.display.id) ? "Remove from My List" : "Add to My List")
                }
                .foregroundStyle(.white)
            }
            .padding(.bottom, 20)
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen(entry.display) }
    }

    private func metaLine(for item: BaseItem) -> some View {
        HStack(spacing: 8) {
            if let genres = item.genres, !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: " · "))
                    .lineLimit(1)
            }
            if let rating = item.officialRating {
                Text(rating)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.7)))
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal)
    }

    /// Moves to the next page every 8 s unless the user just swiped.
    private func autoAdvance() async {
        guard entries.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, Date().timeIntervalSince(lastInteraction) >= 7 else { continue }
            withAnimation(.easeInOut(duration: 0.6)) { page = (page + 1) % entries.count }
        }
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.5))
                    .frame(width: index == current ? 26 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
    }
}

/// Title logo image when the server has one, otherwise the title as large text.
struct TitleLogo: View {
    @Environment(AppModel.self) private var app
    let item: BaseItem
    var maxHeight: CGFloat = 80

    var body: some View {
        if let url = app.api?.logoURL(for: item) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    titleText
                } else {
                    Color.clear
                }
            }
            .frame(maxHeight: maxHeight)
            .shadow(color: .black.opacity(0.4), radius: 6)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(item.seriesName ?? item.name ?? "")
            .font(.system(size: 34, weight: .heavy))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.5), radius: 6)
    }
}
