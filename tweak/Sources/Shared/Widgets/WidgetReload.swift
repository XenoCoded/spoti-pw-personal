import WidgetKit

// Asks the system to refresh the mod's two widgets (Batch 68), called
// from WidgetData.m when the song changes. The half-hour timeline the
// widgets declare is only a backstop; this is what keeps them current.
@objc(SGWidgetReload)
public class SGWidgetReload: NSObject {
    @objc public static func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "SGNowPlayingWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "SGStatsWidget")
    }
}
