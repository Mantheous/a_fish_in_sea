import 'package:flutter/material.dart';

import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:a_fish_in_sea/nodes/model/node.dart';
import 'package:a_fish_in_sea/nodes/service/auto_goal_format.dart';

/// The goal editor's metric list.
///
/// A metric is just a statistic over the goal's scope; the list has no
/// attainment/guardrail roles. The first metric is the one shown on the
/// progress bar, and every metric must pass for derived completion.
class MetricsFields extends StatelessWidget {
  final List<AutoFacet> value;
  final ValueChanged<List<AutoFacet>> onChanged;
  final List<String> classOptions;
  final List<String> moneyCategoryOptions;
  final String Function(String key)? className;
  final bool hasChildren;

  const MetricsFields({
    super.key,
    required this.value,
    required this.onChanged,
    this.classOptions = const [],
    this.moneyCategoryOptions = const [],
    this.className,
    this.hasChildren = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Metrics',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            PopupMenuButton<AutoMetric>(
              tooltip: 'Add metric',
              onSelected: (metric) {
                final next = [...value];
                // A container's first explicit metric still needs the
                // structural "all work done" reading; otherwise adding a
                // 30h cap would let a week with no homework count as done.
                if (hasChildren &&
                    next.isEmpty &&
                    metric != AutoMetric.allDone) {
                  next.add(const AutoFacet(metric: AutoMetric.allDone));
                }
                next.add(_newMetric(metric));
                onChanged(next);
              },
              itemBuilder: (context) => [
                for (final metric in _addableMetrics)
                  PopupMenuItem(
                    value: metric,
                    child: Text(autoMetricLabel(metric)),
                  ),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Icon(Icons.add, size: 18), Text('Add metric')],
                ),
              ),
            ),
          ],
        ),
        if (value.isEmpty)
          Text(
            hasChildren
                ? 'No metrics. Completion is derived from the work under '
                      'this goal.'
                : 'No metrics. This is a checklist goal; completion is the '
                      'checkbox.',
            style: theme.textTheme.bodySmall,
          )
        else
          for (var i = 0; i < value.length; i++)
            _MetricCard(
              key: ValueKey('metric-card-$i-${value[i].metric.name}'),
              metric: value[i],
              primary: i == 0,
              canMoveUp: i > 0,
              canMoveDown: i < value.length - 1,
              classOptions: classOptions,
              moneyCategoryOptions: moneyCategoryOptions,
              className: className,
              onChanged: (next) {
                final copy = [...value];
                copy[i] = next;
                onChanged(copy);
              },
              onRemove: () {
                final copy = [...value]..removeAt(i);
                onChanged(copy);
              },
              onMoveUp: i == 0
                  ? null
                  : () {
                      final copy = [...value];
                      final item = copy.removeAt(i);
                      copy.insert(i - 1, item);
                      onChanged(copy);
                    },
              onMoveDown: i == value.length - 1
                  ? null
                  : () {
                      final copy = [...value];
                      final item = copy.removeAt(i);
                      copy.insert(i + 1, item);
                      onChanged(copy);
                    },
            ),
        const SizedBox(height: 4),
        Text(
          value.isEmpty
              ? ''
              : 'All metrics must pass for the goal to count as complete. '
                    'The first one drives the progress bar.',
          style: theme.textTheme.bodySmall,
        ),
        if (hasChildren &&
            value.isNotEmpty &&
            !value.any(
              (metric) =>
                  metric.metric == AutoMetric.allDone ||
                  metric.metric == AutoMetric.percentDone,
            ))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'This goal has work items. Add “All work done” to require '
              'them as well as these statistics.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  static const _addableMetrics = [
    AutoMetric.allDone,
    AutoMetric.minutes,
    AutoMetric.averageMinutes,
    AutoMetric.count,
    AutoMetric.days,
    AutoMetric.percentDone,
    AutoMetric.amount,
  ];

  static AutoFacet _newMetric(AutoMetric metric) {
    if (metric == AutoMetric.amount) {
      return const AutoFacet(
        source: AutoSource.money,
        metric: AutoMetric.amount,
      );
    }
    if (metric == AutoMetric.percentDone) {
      return const AutoFacet(metric: AutoMetric.percentDone, target: 100);
    }
    return AutoFacet(metric: metric);
  }
}

class _MetricCard extends StatelessWidget {
  final AutoFacet metric;
  final bool primary;
  final bool canMoveUp;
  final bool canMoveDown;
  final List<String> classOptions;
  final List<String> moneyCategoryOptions;
  final String Function(String key)? className;
  final ValueChanged<AutoFacet> onChanged;
  final VoidCallback onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  const _MetricCard({
    super.key,
    required this.metric,
    required this.primary,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.classOptions,
    required this.moneyCategoryOptions,
    required this.className,
    required this.onChanged,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  primary ? Icons.star : Icons.insights_outlined,
                  size: 18,
                  color: primary ? theme.colorScheme.primary : null,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    describeAutoGoal(metric, className: className),
                    style: theme.textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Move up',
                  onPressed: onMoveUp,
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                IconButton(
                  tooltip: 'Move down',
                  onPressed: onMoveDown,
                  icon: const Icon(Icons.arrow_downward, size: 18),
                ),
                IconButton(
                  tooltip: 'Remove metric',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ),
            _MetricEditor(
              value: metric,
              classOptions: classOptions,
              moneyCategoryOptions: moneyCategoryOptions,
              className: className,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricEditor extends StatefulWidget {
  final AutoFacet value;
  final List<String> classOptions;
  final List<String> moneyCategoryOptions;
  final String Function(String key)? className;
  final ValueChanged<AutoFacet> onChanged;

  const _MetricEditor({
    required this.value,
    required this.classOptions,
    required this.moneyCategoryOptions,
    required this.className,
    required this.onChanged,
  });

  @override
  State<_MetricEditor> createState() => _MetricEditorState();
}

class _MetricEditorState extends State<_MetricEditor> {
  late final TextEditingController _target;
  late final TextEditingController _customDays;
  late final TextEditingController _horizon;

  @override
  void initState() {
    super.initState();
    _target = TextEditingController(text: _targetText(widget.value));
    _customDays = TextEditingController(
      text: (widget.value.customPeriodDays ?? 30).toString(),
    );
    _horizon = TextEditingController(
      text: (widget.value.horizonDays ?? 3).toString(),
    );
  }

  @override
  void dispose() {
    _target.dispose();
    _customDays.dispose();
    _horizon.dispose();
    super.dispose();
  }

  static String _targetText(AutoFacet facet) {
    if (facet.target == facet.target.roundToDouble()) {
      return facet.target.toInt().toString();
    }
    return facet.target.toStringAsFixed(2);
  }

  void _emit(AutoFacet next) => widget.onChanged(next);

  void _setTarget() {
    final parsed = double.tryParse(_target.text.trim());
    _emit(
      widget.value.copyWith(target: parsed == null || parsed < 0 ? 0 : parsed),
    );
  }

  void _setCustomDays() {
    final parsed = int.tryParse(_customDays.text.trim());
    _emit(
      widget.value.copyWith(
        customPeriodDays: parsed == null ? 30 : parsed.clamp(1, 36500),
      ),
    );
  }

  void _setHorizon() {
    final parsed = int.tryParse(_horizon.text.trim());
    _emit(
      widget.value.copyWith(
        horizonDays: parsed == null ? 3 : parsed.clamp(1, 3650),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final facet = widget.value;
    final allDone = facet.metric == AutoMetric.allDone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!allDone) ...[
          DropdownButtonFormField<AutoSource>(
            isExpanded: true,
            key: ValueKey('metric-source-${facet.metric.name}'),
            initialValue: facet.source,
            decoration: const InputDecoration(
              labelText: 'Reads',
              isDense: true,
            ),
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
            isExpanded: true,
            key: ValueKey(
              'metric-kind-${facet.source.name}-${facet.metric.name}',
            ),
            initialValue: facet.metric,
            decoration: const InputDecoration(
              labelText: 'Counts',
              isDense: true,
            ),
            items: [
              for (final metric in autoMetricsFor(facet.source))
                DropdownMenuItem(
                  value: metric,
                  child: Text(autoMetricLabel(metric)),
                ),
            ],
            onChanged: (metric) {
              if (metric == null) return;
              _emit(facet.copyWith(metric: metric));
            },
          ),
          const SizedBox(height: 8),
          Row(
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
                  isExpanded: true,
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
            isExpanded: true,
            initialValue: facet.period,
            decoration: const InputDecoration(
              labelText: 'Resets',
              isDense: true,
            ),
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
        ],
        const SizedBox(height: 8),
        DropdownButtonFormField<AutoScope>(
          isExpanded: true,
          initialValue: facet.scope,
          decoration: const InputDecoration(labelText: 'Scope', isDense: true),
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
        if (facet.source == AutoSource.tasks) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Homework only'),
            value: facet.homeworkOnly,
            onChanged: (on) => _emit(
              facet.copyWith(
                homeworkOnly: on,
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
              className: _className,
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
      ],
    );
  }

  String _className(String key) => widget.className?.call(key) ?? key;

  static String _targetLabel(AutoMetric metric) => switch (metric) {
    AutoMetric.minutes || AutoMetric.averageMinutes => 'Target minutes',
    AutoMetric.amount => 'Target amount',
    AutoMetric.percentDone => 'Target percent',
    AutoMetric.allDone => 'Target',
    AutoMetric.count || AutoMetric.days => 'Target count',
  };
}

/// Multi-select chips. Selected values missing from [options] stay visible.
class _ChipPicker extends StatelessWidget {
  final String label;
  final String emptyLabel;
  final List<String> options;
  final List<String> selected;
  final String Function(String key)? className;
  final ValueChanged<List<String>> onChanged;

  const _ChipPicker({
    required this.label,
    required this.emptyLabel,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.className,
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
                    label: Text(className?.call(option) ?? option),
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
