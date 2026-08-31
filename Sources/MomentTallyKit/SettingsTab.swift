/// The app's navigation vocabulary, shared across platforms (#124): on the
/// Mac these are the settings window's sections in toolbar order (raw value =
/// tab index, consumed by SettingsWindowManager's NSTabViewController); on
/// iOS they name the destinations the TabView/launcher routes to. Content
/// tabs first, then the one preferences tab (connection + behaviour).
package enum SettingsTab: Int, CaseIterable, Sendable {
    case launcher, tagSets, log, calendar, history, review, help, settings
}
