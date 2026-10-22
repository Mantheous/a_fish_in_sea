abstract final class Migration {
  /// Static removal marker only. Runtime restores always run migrations;
  /// the expiry test enforces this date without stranding old device data.
  static bool removeAfter(String isoDate, [DateTime? now]) => true;
}
