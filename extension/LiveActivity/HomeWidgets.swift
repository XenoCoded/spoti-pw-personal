import SwiftUI
import WidgetKit

// The mod's own home and lock screen widgets (Batch 68): what is playing,
// with the line being sung under it, and the day's listening. Everything
// they show is written by the tweak into the suite Spotify's own widget
// reads (group.com.spotify.client.widget.data), which the App Groups shim
// redirects into a folder this extension shares with the app — the same
// trick that keeps Spotify's widget alive in a re-signed IPA. No friends,
// no feed: the song and the stats, nothing else.
//
// Built by scripts/build-extension.sh with LiveActivityWidget.swift;
// the two files are one module.

private let sgSuiteName = "group.com.spotify.client.widget.data"
private let sgGreen = Color(red: 0.12, green: 0.84, blue: 0.38)
private let sgDim = Color.white.opacity(0.55)

struct SGWidgetEntry: TimelineEntry {
    let date: Date
    var title = ""
    var artist = ""
    var line = ""
    var playsToday = 0
    var minutesToday = 0
    var streak = 0
    var topTitle = ""
    var cover: UIImage? = nil
}

private func sgEntry() -> SGWidgetEntry {
    var entry = SGWidgetEntry(date: Date())
    guard let suite = UserDefaults(suiteName: sgSuiteName) else { return entry }
    entry.title = suite.string(forKey: "sg.title") ?? ""
    entry.artist = suite.string(forKey: "sg.artist") ?? ""
    entry.line = suite.string(forKey: "sg.line") ?? ""
    // The day stamp (Batch 93): after a kill, a reboot or midnight the
    // suite still holds the last write, and its "today" may be another
    // day's. Stats from a different day read as zero, not as today's.
    let dayFormat = DateFormatter()
    dayFormat.locale = Locale(identifier: "en_US_POSIX")
    dayFormat.calendar = Calendar(identifier: .gregorian)
    dayFormat.dateFormat = "yyyy-MM-dd"
    if suite.string(forKey: "sg.day") == dayFormat.string(from: Date()) {
        entry.playsToday = suite.integer(forKey: "sg.playsToday")
        entry.minutesToday = suite.integer(forKey: "sg.minutesToday")
        entry.streak = suite.integer(forKey: "sg.streak")
        entry.topTitle = suite.string(forKey: "sg.topTitle") ?? ""
    }
    if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sgSuiteName) {
        let file = container.appendingPathComponent("sg-cover.jpg")
        if let data = try? Data(contentsOf: file) {
            entry.cover = UIImage(data: data)
        }
    }
    return entry
}

struct SGWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SGWidgetEntry { sgEntry() }
    func getSnapshot(in context: Context, completion: @escaping (SGWidgetEntry) -> Void) {
        completion(sgEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SGWidgetEntry>) -> Void) {
        // The tweak asks for a reload when the track changes; the half
        // hour policy is only the backstop for a long, unchanging listen.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [sgEntry()], policy: .after(next)))
    }
}

// MARK: - Now playing

struct SGNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SGNowPlayingWidget", provider: SGWidgetProvider()) { entry in
            SGNowPlayingView(entry: entry)
                // Black, the way the mod's own pages are; without a
                // container background WidgetKit draws its "please adopt
                // the container background API" placeholder instead.
                .containerBackground(Color.black, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("The song, and the line being sung.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct SGNowPlayingView: View {
    @Environment(\.widgetFamily) var family
    let entry: SGWidgetEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.title.isEmpty ? "Nothing playing" : "\(entry.title) — \(entry.artist)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Open Spotify and play" : entry.title)
                    .font(.headline).lineLimit(1)
                Text(entry.artist).font(.subheadline).foregroundStyle(sgDim).lineLimit(1)
                if !entry.line.isEmpty {
                    Text(entry.line).font(.caption).foregroundStyle(sgGreen).lineLimit(1)
                }
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                if let cover = entry.cover {
                    Image(uiImage: cover).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text(entry.title.isEmpty ? "Nothing playing" : entry.title)
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(entry.artist).font(.caption).foregroundStyle(sgDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        default:
            HStack(spacing: 12) {
                if let cover = entry.cover {
                    Image(uiImage: cover).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title.isEmpty ? "Nothing playing" : entry.title)
                        .font(.headline).lineLimit(1)
                    Text(entry.artist).font(.subheadline).foregroundStyle(sgDim).lineLimit(1)
                    if !entry.line.isEmpty {
                        Text(entry.line).font(.callout).foregroundStyle(sgGreen).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Listening today

struct SGStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SGStatsWidget", provider: SGWidgetProvider()) { entry in
            SGStatsView(entry: entry)
                .containerBackground(Color.black, for: .widget)
        }
        .configurationDisplayName("Listening Today")
        .description("Today's plays, time and streak, from the stats this phone keeps.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

struct SGStatsView: View {
    @Environment(\.widgetFamily) var family
    let entry: SGWidgetEntry

    private var timeText: String {
        entry.minutesToday >= 60 ? "\(entry.minutesToday / 60) h \(entry.minutesToday % 60) min"
                                 : "\(entry.minutesToday) min"
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Text("\(entry.playsToday)").font(.title3.weight(.bold))
                Text("plays").font(.caption2).foregroundStyle(sgDim)
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                Text("Today").font(.caption.weight(.semibold)).foregroundStyle(sgGreen)
                Text(timeText).font(.title3.weight(.bold))
                Text("\(entry.playsToday) plays").font(.subheadline).foregroundStyle(sgDim)
                if entry.streak > 1 {
                    Text("\(entry.streak) day streak").font(.caption).foregroundStyle(sgDim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        default:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Listening today").font(.caption.weight(.semibold)).foregroundStyle(sgGreen)
                    Text(timeText).font(.title2.weight(.bold))
                    Text("\(entry.playsToday) plays").font(.subheadline).foregroundStyle(sgDim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if entry.streak > 0 {
                        Text("\(entry.streak)").font(.title2.weight(.bold))
                        Text("day streak").font(.caption).foregroundStyle(sgDim)
                    }
                    if !entry.topTitle.isEmpty {
                        Text("Top: \(entry.topTitle)").font(.caption).foregroundStyle(sgDim).lineLimit(1)
                    }
                }
            }
        }
    }
}
