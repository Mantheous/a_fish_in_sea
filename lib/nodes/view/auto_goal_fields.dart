import 'package:flutter/material.dart';

import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/auto_goal_format.dart';

/// Editor section for a single generic automated goal.
///
/// Kept out of `node_editor.dart` so the facet pipeline (source → metric →
/// window → filter) is one testable widget instead of another hundred
/// lines in an already long dialog. The parent owns the [value] and
/// persists whatever this widget emits.
class AutoGoalFields extends StatefulWidget {
  final AutoFacet? value;
  final ValueChanged<AutoFacet?> onChanged;

  /// Existing homework classes and transaction categories, offered as
  /// chips. Members missing from the options are still rendered so a stale
  /// selection never disappears silently.
  final List<String> classOptions;
  final List<String> moneyCategoryOptions;

  const AutoGoalFields({
    super.key,
    required this.value,
    required this.onChanged,
    this.classOptions = const [],
    this.moneyCategoryOptions = const [],
  });

  @override
  State<AutoGoalFields> createState() => _AutoGoalFieldsState();
}

class _AutoGoalFieldsState extends State<AutoGoalFields> {
  late final TextEditingController _target;
  late final TextEditingController _customDays;
  late final TextEditingController _horizon;

  @override
  void initState() {
    super.initState();
    _target = TextEditingController(text: _targetText(widget.value));
    _customDays = TextEditingController(
      text: (widget.value?.customPeriodDays ?? 30).toString(),
    );
    _horizon = TextEditingController(
      text: (widget.value?.horizonDays ?? 3).toString(),
    );
  }

  @override
  void didUpdateWidget(covariant AutoGoalFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The switch turning on/off replaces the whole facet; reflect any
    // programmatic value instead of keeping the previous text.
    if (oldWidget.value == null && widget.value != null) {
      _target.text = _targetText(widget.value);
      _customDays.text = (widget.value!.customPeriodDays ?? 30).toString();
      _horizon.text = (widget.value!.horizonDays ?? 3).toString();
    }
  }

  @override
  void dispose() {
    _target.dispose();
    _customDays.dispose();
    _horizon.dispose();
    super.dispose();
  }

  static String _targetText(AutoFacet? facet) {
    if (facet == null) return '';
    final target = facet.target;
    if (target == target.roundToDouble()) return target.toInt().toString();
    return target.toStringAsFixed(2);
  }

  void _emit(AutoFacet next) => widget.onChanged(next);

  void _setTarget() {
    final facet = widget.value;
    if (facet == null) return;
    final parsed = double.tryParse(_target.text.trim());
    _emit(facet.copyWith(target: parsed == null || parsed < 0 ? 0 : parsed));
  }

  void _setCustomDays() {
    final facet = widget.value;
    if (facet == null) return;
    final parsed = int.tryParse(_customDays.text.trim());
    _emit(
      facet.copyWith(
        customPeriodDays: parsed == null ? 30 : parsed.clamp(1, 36500),
      ),
    );
  }

  void _setHorizon() {
    final facet = widget.value;
    if (facet == null) return;
    final parsed = int.tryParse(_horizon.text.trim());
    _emit(
      facet.copyWith(horizonDays: parsed == null ? 3 : parsed.clamp(1, 3650)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final facet = widget.value;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Automated goal'),
          subtitle: const Text(
            'Measure progress from tasks, calendar, or money '
            'instead of only checking it off.',
          ),
          value: facet != null,
          onChanged: (on) => widget.onChanged(on ? const AutoFacet() : null),
        ),
        if (facet != null) ...[
          DropdownButtonFormField<AutoSource>(
            key: const ValueKey('auto-source'),
            initialValue: facet.source,
            decoration: const InputDecoration(labelText: 'Measures'),
            items: [
              for (final source in AutoSource.values)
                DropdownMenuItem(
                  value: source,
                  child: Text(autoSourceLabel(source)),
                ),
            ],
            onChanged: (source) {
              if (source == null) return;
              final metrics = autoMetricsFor(source);
              final metric = metrics.contains(facet.metric)
                  ? facet.metric
                  : metrics.first;
              _emit(facet.copyWith(source: source, metric: metric));
            },
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<AutoMetric>(
            key: ValueKey('auto-metric-${facet.source.name}'),
            initialValue: facet.metric,
            decoration: const InputDecoration(labelText: 'Counts'),
            items: [
              for (final metric in autoMetricsFor(facet.source))
                DropdownMenuItem(
                  value: metric,
                  child: Text(_metricLabel(metric)),
                ),
            ],
            onChanged: (metric) {
              if (metric == null) return;
              // "Done" is naturally 100%; prefill it so a new goal is not
              // born at an impossible 0% target.
              final target = metric == AutoMetric.percentDone &&
                      facet.target == 0
                  ? 100.0
                  : facet.target;
              if (metric == AutoMetric.percentDone &&
                  facet.target == 0 &&
                  _target.text.trim().isEmpty) {
                _target.text = '100';
              }
              _emit(facet.copyWith(metric: metric, target: target));
            },
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _target,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: _targetLabel(facet.metric),
                    prefixText: facet.metric == AutoMetric.amount
                        ? '\$ '
                        : null,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => _setTarget(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<AutoComparison>(
                  initialValue: facet.comparison,
                  decoration: const InputDecoration(
                    labelText: 'Target',
                    isDense: true,
                  ),
                  items: [
                    for (final comparison in AutoComparison.values)
                      DropdownMenuItem(
                        value: comparison,
                        child: Text(autoComparisonLabel(comparison)),
                      ),
                  ],
                  onChanged: (comparison) {
                    if (comparison != null) {
                      _emit(facet.copyWith(comparison: comparison));
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<TimeScale>(
            initialValue: facet.period,
            decoration: const InputDecoration(labelText: 'Resets'),
            items: [
              for (final period in TimeScale.values)
                DropdownMenuItem(
                  value: period,
                  child: Text(period.displayName),
                ),
            ],
            onChanged: (period) {
              if (period != null) _emit(facet.copyWith(period: period));
            },
          ),
          if (facet.period == TimeScale.custom) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _customDays,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Custom period (days)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => _setCustomDays(),
            ),
          ],
          if (facet.source == AutoSource.tasks ||
              facet.source == AutoSource.money) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<AutoScope>(
              initialValue: facet.scope,
              decoration: const InputDecoration(labelText: 'Reads'),
              items: [
                for (final scope in AutoScope.values)
                  DropdownMenuItem(
                    value: scope,
                    child: Text(autoScopeLabel(scope)),
                  ),
              ],
              onChanged: (scope) {
                if (scope != null) _emit(facet.copyWith(scope: scope));
              },
            ),
          ],
          if (facet.source == AutoSource.tasks) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Homework only'),
              value: facet.homeworkOnly,
              onChanged: (on) => _emit(
                facet.copyWith(
                  homeworkOnly: on,
                  // Homework is normally store-wide, not a child of this
                  // goal; switching the filter on would otherwise read an
                  // empty subtree and show 0.
                  scope: on ? AutoScope.all : facet.scope,
                ),
              ),
            ),
            if (facet.homeworkOnly)
              _ChipPicker(
                label: 'Classes',
                emptyLabel: 'No homework classes found yet.',
                options: widget.classOptions,
                selected: facet.classKeys,
                onChanged: (keys) => _emit(facet.copyWith(classKeys: keys)),
              ),
            if (facet.metric == AutoMetric.percentDone) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _horizon,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Days ahead that must be done',
                  helperText: 'e.g. 2 = finish Monday’s homework by Saturday',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => _setHorizon(),
              ),
            ],
          ],
          if (facet.source == AutoSource.money)
            _ChipPicker(
              label: 'Categories',
              emptyLabel: 'Import transactions to pick categories.',
              options: widget.moneyCategoryOptions,
              selected: facet.moneyCategories,
              onChanged: (categories) =>
                  _emit(facet.copyWith(moneyCategories: categories)),
            ),
          const SizedBox(height: 8),
          Text(describeAutoGoal(facet), style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }

  static String _metricLabel(AutoMetric metric) => switch (metric) {
    AutoMetric.amount => 'Amount spent (\$)',
    AutoMetric.percentDone => 'Done (%)',
    _ => autoMetricLabel(metric),
  };

  static String _targetLabel(AutoMetric metric) => switch (metric) {
    AutoMetric.minutes || AutoMetric.averageMinutes => 'Target minutes',
    AutoMetric.amount => 'Target amount',
    AutoMetric.percentDone => 'Target percent',
    AutoMetric.count || AutoMetric.days => 'Target count',
  };
}

/// Multi-select chips. Selected values that are not in [options] are kept
/// and shown at the end, so edited data always stays visible.
class _ChipPicker extends StatelessWidget {
  final String label;
  final String emptyLabel;
  final List<String> options;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  const _ChipPicker({
    required this.label,
    required this.emptyLabel,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final merged = <String>[...options];
    for (final value in selected) {
      if (!merged.any((o) => o.toLowerCase() == value.toLowerCase())) {
        merged.add(value);
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          if (merged.isEmpty)
            Text(emptyLabel, style: Theme.of(context).textTheme.bodySmall)
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final option in merged)
                  FilterChip(
                    label: Text(option),
                    selected: selected.any(
                      (value) => value.toLowerCase() == option.toLowerCase(),
                    ),
                    onSelected: (on) {
                      final next = [...selected];
                      final index = next.indexWhere(
                        (value) => value.toLowerCase() == option.toLowerCase(),
                      );
                      if (on && index < 0) {
                        next.add(option);
                      } else if (!on && index >= 0) {
                        next.removeAt(index);
                      }
                      onChanged(next);
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
