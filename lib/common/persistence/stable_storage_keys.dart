/// Stable [HydratedMixin.storagePrefix] values for every hydrated cubit.
///
/// hydrated_bloc defaults the storage key to `runtimeType.toString()`. That
/// is stable on the VM (and in non-obfuscated AOT builds), but a **release
/// web build** runs through dart2js with minification on: `runtimeType`
/// becomes `minified:<compiler name>`, and those names are re-assigned
/// whenever the compiler's name table shifts. The class name can therefore
/// change between two deploys with no schema change at all — every hydrated
/// cubit then boots from a key that the previous build never wrote, which
/// silently resets the Tasks views/rules, calendar visibility, and even the
/// stored auth tokens on the next hard refresh.
///
/// Every hydrated cubit must override `storagePrefix` with one of these
/// literals. The literals match the VM/AOT class names, so native and debug
/// installs keep reading their existing box entries.
abstract final class StableStorageKeys {
  static const auth = 'AuthCubit';
  static const node = 'NodeCubit';
  static const calendar = 'CalendarCubit';
  static const feed = 'FeedCubit';
  static const transactions = 'TransactionsCubit';
  static const plaid = 'PlaidCubit';
  static const waterfall = 'WaterfallCubit';
  static const places = 'PlacesCubit';
  static const reporting = 'ReportingCubit';
  static const tracking = 'TrackingCubit';
  static const settings = 'SettingsCubit';
  static const syncMeta = 'SyncMetaCubit';
  static const schedulePrefs = 'SchedulePrefsCubit';
  static const tasksViewOptions = 'TasksViewOptionsCubit';
  static const calendarVisibility = 'CalendarVisibilityCubit';
  static const assignmentRules = 'AssignmentRulesCubit';
  static const assignmentEstimates = 'AssignmentEstimatesCubit';

  static const Set<String> all = {
    auth,
    node,
    calendar,
    feed,
    transactions,
    plaid,
    waterfall,
    places,
    reporting,
    tracking,
    settings,
    syncMeta,
    schedulePrefs,
    tasksViewOptions,
    calendarVisibility,
    assignmentRules,
    assignmentEstimates,
  };
}
