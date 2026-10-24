import 'package:equatable/equatable.dart';

/// User color choices for events and task lists, persisted inside
/// [SettingsState] as one JSON blob (so they roam with sync for free).
///
/// Everything here is additive with a default: an old settings payload
/// without `colors`, one corrupt class entry, or a renamed surface flag
/// loads with the remaining choices intact instead of throwing (a throw
/// in `SettingsCubit.fromJson` resets every setting on this device).
class ColorPrefs extends Equatable {
  /// One color for imported homework events. Null means "follow the class,
  /// calendar, or personal color" — the pre-colors behavior.
  final int? homework;

  /// Default for events with no class and no calendar of their own.
  /// Null uses the app's built-in personal-event color.
  final int? personal;

  /// Class label → ARGB override. Classes without an entry keep the
  /// deterministic palette color from [courseColor].
  final Map<String, int> classes;

  /// Repaint calendar tiles and event details with these choices.
  final bool applyToCalendar;

  /// Repaint class chips and homework group headers in task lists.
  final bool applyToTaskLists;

  const ColorPrefs({
    this.homework,
    this.personal,
    this.classes = const {},
    this.applyToCalendar = true,
    this.applyToTaskLists = true,
  });

  bool get hasOverrides =>
      homework != null || personal != null || classes.isNotEmpty;

  bool get isDefault => !hasOverrides && applyToCalendar && applyToTaskLists;

  /// Assigned color for [label], keyed on the trimmed label so a class
  /// imported with stray whitespace still matches. [useOverrides] false
  /// ignores the assignment (a surface with color coding switched off) but
  /// still reports "no override" so callers fall back to the auto color.
  int? classColorFor(String label, {bool useOverrides = true}) =>
      useOverrides ? classes[label.trim()] : null;

  ColorPrefs copyWith({
    int? homework,
    bool clearHomework = false,
    int? personal,
    bool clearPersonal = false,
    Map<String, int>? classes,
    bool? applyToCalendar,
    bool? applyToTaskLists,
  }) => ColorPrefs(
    homework: clearHomework ? null : (homework ?? this.homework),
    personal: clearPersonal ? null : (personal ?? this.personal),
    classes: classes ?? this.classes,
    applyToCalendar: applyToCalendar ?? this.applyToCalendar,
    applyToTaskLists: applyToTaskLists ?? this.applyToTaskLists,
  );

  /// Restores one class color; a null [value] removes the override so the
  /// class falls back to its automatic palette color.
  ColorPrefs withClassColor(String label, int? value) {
    final key = label.trim();
    if (key.isEmpty) return this;
    final next = Map<String, int>.of(classes);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    return copyWith(classes: next);
  }

  /// Keeps every valid entry, drops the rest. Accepts an old or partial
  /// payload without throwing.
  factory ColorPrefs.fromJson(Object? raw) {
    if (raw is! Map) return const ColorPrefs();
    return ColorPrefs(
      homework: _color(raw['homework']),
      personal: _color(raw['personal']),
      classes: _classColors(raw['classes']),
      applyToCalendar: _flag(raw['applyToCalendar']),
      applyToTaskLists: _flag(raw['applyToTaskLists']),
    );
  }

  static bool _flag(Object? raw) => raw is bool ? raw : true;

  /// ARGB int, accepting the pre-alpha form some older code wrote.
  static int? _color(Object? raw) {
    if (raw is! num) return null;
    final value = raw.toInt();
    if (value < 0 || value > 0xFFFFFFFF) return null;
    return value <= 0xFFFFFF ? value | 0xFF000000 : value;
  }

  static Map<String, int> _classColors(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, int>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final label = key.trim();
      if (label.isEmpty) continue;
      final color = _color(entry.value);
      if (color != null) out[label] = color;
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
    'homework': homework,
    'personal': personal,
    'classes': classes,
    'applyToCalendar': applyToCalendar,
    'applyToTaskLists': applyToTaskLists,
  };

  @override
  List<Object?> get props => [
    homework,
    personal,
    classes,
    applyToCalendar,
    applyToTaskLists,
  ];
}
