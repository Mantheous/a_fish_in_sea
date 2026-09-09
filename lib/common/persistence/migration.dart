abstract final class Migration {
  static bool removeAfter(String isoDate, [DateTime? now]) {
    DateTime deadline;
    try {
      deadline = DateTime.parse(isoDate);
    } catch (_) {
      return true;
    }
    return (now ?? DateTime.now()).isBefore(deadline);
  }
}
