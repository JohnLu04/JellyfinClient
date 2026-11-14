import SwiftUI

// Look and building blocks of the Seerr screens, taken from the Servarr app.
// The accent follows this app's accent color.

enum Theme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.05)
    static let card = Color(red: 0.11, green: 0.11, blue: 0.135)
    static let tile = Color(red: 0.055, green: 0.055, blue: 0.07)
    static let iconTile = Color(red: 0.17, green: 0.17, blue: 0.2)
    static let accent = Color.accentColor
    static let online = Color(red: 0.2, green: 0.8, blue: 0.4)
    static let cardRadius: CGFloat = 20
}

extension View {
    /// Rounded dark card.
    func card(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// Dark background for lists and scroll views.
    func themedBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}

/// What a poster placeholder shows when there's no artwork.
enum SeerrArtKind {
    case movie, series

    var systemImage: String { self == .movie ? "film" : "tv" }
    var tint: Color { self == .movie ? .orange : .blue }
}

/// Seerr's logo on a dark rounded tile.
struct ServiceIcon: View {
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Theme.iconTile)
            .frame(width: size, height: size)
            .overlay {
                Image("LogoSeerr")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.16)
            }
            .accessibilityLabel("Seerr")
    }
}

/// "Title >        See All >" row above a section.
struct SectionHeader<Destination: Hashable>: View {
    let title: String
    let destination: Destination?

    init(_ title: String, destination: Destination?) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            label
            Spacer()
            seeAll
        }
    }

    @ViewBuilder private var label: some View {
        let text = HStack(spacing: 6) {
            Text(title).font(.title3.bold())
            if destination != nil {
                Image(systemName: "chevron.right").font(.subheadline.bold())
            }
        }
        .foregroundStyle(.primary)

        if let destination {
            NavigationLink(value: destination) { text }.buttonStyle(.plain)
        } else {
            text
        }
    }

    @ViewBuilder private var seeAll: some View {
        if let destination {
            NavigationLink(value: destination) {
                Label("See All", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.font(.footnote.weight(.semibold))
        }
    }
}

/// Small tag such as "Movie" or "Series".
struct MediaChip: View {
    let text: String
    var compact = false

    var body: some View {
        Text(text)
            .font(compact ? .caption : .subheadline)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, compact ? 6 : 9)
            .padding(.vertical, compact ? 2 : 4)
            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5)
            }
    }
}

/// Poster with title, chip, optional footnote and a status dot – used in rows and grids.
struct SeerrPosterCard: View {
    let url: URL?
    let title: String
    let kind: SeerrArtKind
    let chip: String
    var footnote: String?
    var badge: SeerrState?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: url, title: title, kind: kind)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Circle()
                            .fill(badge.color)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1.5))
                            .padding(7)
                            .accessibilityLabel(badge.label)
                    }
                }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            MediaChip(text: chip, compact: true)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 2:3 poster artwork with a generated placeholder when there's no image.
struct PosterImage: View {
    let url: URL?
    let title: String
    let kind: SeerrArtKind

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                PipelineImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: { _ in
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
    }

    private var placeholder: some View {
        // Stable hue per title so each poster looks different but consistent.
        let hue = Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                    Color(hue: hue, saturation: 0.7, brightness: 0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                // Small thumbnails (list rows) only get the icon; the title would wrap mid-word.
                let showsTitle = proxy.size.width >= 80
                VStack(spacing: 6) {
                    Image(systemName: kind.systemImage)
                        .font(showsTitle ? .title2 : .body)
                    if showsTitle {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// Image through the shared pipeline with a placeholder.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fit
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        PipelineImage(url: url) { image in
            image.resizable().interpolation(.high).aspectRatio(contentMode: contentMode)
        } placeholder: { _ in
            placeholder()
        }
    }
}

struct StatusBadge: View {
    let state: SeerrState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(state.color.opacity(0.18), in: Capsule())
            .foregroundStyle(state.color)
    }
}

/// Shown when no Seerr server is connected yet.
struct SeerrNotConnectedView: View {
    @State private var showSetup = false

    var body: some View {
        ContentUnavailableView {
            Label("Seerr Not Connected", systemImage: "tray.full")
        } description: {
            Text("Connect your Seerr server to discover new movies and series and request them.")
        } actions: {
            Button("Connect Seerr") { showSetup = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                SeerrSetupView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSetup = false }
                        }
                    }
            }
        }
    }
}
