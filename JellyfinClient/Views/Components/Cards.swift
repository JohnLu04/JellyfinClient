import SwiftUI

struct RemoteImage: View {
    let url: URL?
    var placeholderSymbol = "film"

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let url {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipped()
    }

    private var placeholder: some View {
        Image(systemName: placeholderSymbol)
            .font(.title2)
            .foregroundStyle(.secondary)
    }
}

/// Thin progress bar drawn over artwork for partially watched items.
struct WatchProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.45))
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .padding(6)
    }
}

struct PlayedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .font(.title3)
            .padding(4)
    }
}

struct PosterCard: View {
    @Environment(AppModel.self) private var app
    let item: BaseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: app.api?.posterURL(for: item), placeholderSymbol: item.kind == .series ? "tv" : "film")
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) { if item.userData?.played == true { PlayedBadge() } }
                .overlay(alignment: .bottom) { if let f = item.progressFraction { WatchProgressBar(fraction: f) } }
            Text(item.name ?? "")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(item.productionYear.map(String.init) ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// "Continue Watching" card: poster format; episodes show their series' poster.
struct ContinueWatchingCard: View {
    @Environment(AppModel.self) private var app
    let item: BaseItem
    var width: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: app.api?.seriesOrItemPosterURL(for: item, maxWidth: 360),
                        placeholderSymbol: item.type == "Episode" ? "tv" : "film")
                .frame(width: width, height: width * 3 / 2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { if let f = item.progressFraction { WatchProgressBar(fraction: f) } }
            Text(item.seriesName ?? item.name ?? "")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }

    /// Episodes: "S1 · E3"; movies: year.
    private var subtitle: String {
        if item.type == "Episode" { return item.episodeLabel ?? item.name ?? "" }
        return item.productionYear.map(String.init) ?? ""
    }
}

struct LibraryTile: View {
    @Environment(AppModel.self) private var app
    let item: BaseItem

    var body: some View {
        RemoteImage(url: app.api?.posterURL(for: item, maxWidth: 600), placeholderSymbol: symbol)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                Text(item.name ?? "")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var symbol: String {
        switch item.collectionType {
        case "movies": return "film.stack"
        case "tvshows": return "tv"
        default: return "folder"
        }
    }
}

// MARK: - Navigation

struct ItemRouter: View {
    let item: BaseItem

    var body: some View {
        switch item.kind {
        case .playable: ItemDetailView(item: item)
        case .series: SeriesView(series: item)
        case .folder: LibraryItemsView(parent: item)
        case .unsupported:
            ContentUnavailableView("Not supported yet", systemImage: "questionmark.square.dashed",
                                   description: Text("This client can't open “\(item.type ?? "this")” items yet."))
        }
    }
}

extension View {
    func itemNavigationDestinations() -> some View {
        navigationDestination(for: BaseItem.self) { ItemRouter(item: $0) }
    }
}
