/// Global demo-mode flag for service-layer short-circuits.
///
/// The UI rebuilds off [DemoCubit]; services (which have no BuildContext)
/// read this static instead. It is intentionally never persisted: a reload
/// always lands back on the sign-in page with the real stored data.
class DemoMode {
  static bool isActive = false;

  /// Address shown as the signed-in user while demoing.
  static const demoEmail = 'demo@example.com (mock)';
}
