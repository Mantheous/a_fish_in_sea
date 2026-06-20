import 'package:a_fish_in_sea/finances/model/budget.dart';
import 'package:a_fish_in_sea/finances/model/ledger_entry.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// A month-grid calendar showing financial events on their actual dates.
///
/// Concrete (actual) entries render as filled dots; projected/planned
/// entries render as outlined dots. Budgets that only resolve to a
/// week or month (not a specific day) render as banners spanning that
/// week-row or the whole month, rather than being dropped or pinned to
/// a single day.
class MonthCalendar extends StatefulWidget {
  final List<LedgerEntry> entries;
  final List<Budget> budgets;

  const MonthCalendar({
    super.key,
    required this.entries,
    required this.budgets,
  });

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<MonthCalendar> {
  static final _currencyFormat = NumberFormat.currency(symbol: '\$');
  static const _weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  late DateTime _focusedMonth;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focusedMonth = DateTime(now.year, now.month, 1);
  }

  void _goToPreviousMonth() {
    setState(() => _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1, 1));
  }

  void _goToNextMonth() {
    setState(() => _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1));
  }

  void _goToToday() {
    final now = DateTime.now();
    setState(() => _focusedMonth = DateTime(now.year, now.month, 1));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entriesByDay = _groupEntriesByDay(widget.entries);
    final weeks = _buildWeeks(_focusedMonth);
    final monthlyBudgets = widget.budgets
        .where((b) => b.period == TimeScale.monthly && _budgetActiveInPeriod(b, _focusedMonth))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(theme),
        if (monthlyBudgets.isNotEmpty)
          _buildBanners(theme, monthlyBudgets, _focusedMonth, icon: Icons.calendar_view_month),
        const SizedBox(height: 4),
        _buildWeekdayHeader(theme),
        for (final week in weeks) _buildWeekRow(context, theme, week, entriesByDay),
        const SizedBox(height: 8),
        _buildLegend(theme),
      ],
    );
  }

  // ── Header / navigation ────────────────────────────────────────────

  Widget _buildHeader(ThemeData theme) {
    final monthLabel = DateFormat('MMMM yyyy').format(_focusedMonth);
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: _goToPreviousMonth,
          tooltip: 'Previous month',
        ),
        Expanded(
          child: Center(
            child: Text(
              monthLabel,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: _goToNextMonth,
          tooltip: 'Next month',
        ),
        IconButton(
          icon: const Icon(Icons.today),
          onPressed: _goToToday,
          tooltip: 'Jump to today',
        ),
      ],
    );
  }

  Widget _buildWeekdayHeader(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Row(
      children: _weekdayLabels
          .map((label) => Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ))
          .toList(),
    );
  }

  // ── Week / day grid ─────────────────────────────────────────────────

  /// Splits [month] into Monday-Sunday week rows, including the leading
  /// and trailing days of adjacent months needed to fill the grid.
  List<List<DateTime>> _buildWeeks(DateTime month) {
    final firstOfMonth = DateTime(month.year, month.month, 1);
    final leadingDays = firstOfMonth.weekday - 1; // weekday: 1=Mon..7=Sun
    final gridStart = firstOfMonth.subtract(Duration(days: leadingDays));

    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final lastOfMonth = DateTime(month.year, month.month, daysInMonth);
    final trailingDays = 7 - lastOfMonth.weekday;
    final gridEnd = lastOfMonth.add(Duration(days: trailingDays));

    final totalDays = gridEnd.difference(gridStart).inDays + 1;
    final allDays = List.generate(totalDays, (i) => gridStart.add(Duration(days: i)));

    final weeks = <List<DateTime>>[];
    for (var i = 0; i < allDays.length; i += 7) {
      weeks.add(allDays.sublist(i, i + 7));
    }
    return weeks;
  }

  Widget _buildWeekRow(
    BuildContext context,
    ThemeData theme,
    List<DateTime> week,
    Map<DateTime, List<LedgerEntry>> entriesByDay,
  ) {
    final weekStart = week.first;
    final weeklyBudgets = widget.budgets
        .where((b) => b.period == TimeScale.weekly && _budgetActiveInPeriod(b, weekStart))
        .toList();

    return Column(
      children: [
        Row(
          children: week
              .map((day) => _buildDayCell(context, theme, day, entriesByDay))
              .toList(),
        ),
        if (weeklyBudgets.isNotEmpty)
          _buildBanners(theme, weeklyBudgets, weekStart, icon: Icons.calendar_view_week),
      ],
    );
  }

  Widget _buildDayCell(
    BuildContext context,
    ThemeData theme,
    DateTime day,
    Map<DateTime, List<LedgerEntry>> entriesByDay,
  ) {
    final colorScheme = theme.colorScheme;
    final isCurrentMonth = day.month == _focusedMonth.month;
    final isToday = _isSameDay(day, DateTime.now());
    final dayEntries = entriesByDay[DateTime(day.year, day.month, day.day)] ?? const [];
    const maxDots = 4;

    return Expanded(
      child: AspectRatio(
        aspectRatio: 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: dayEntries.isEmpty ? null : () => _showDayDetails(context, day, dayEntries),
          child: Container(
            margin: const EdgeInsets.all(2),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: isToday ? colorScheme.primary.withValues(alpha: 0.12) : null,
              border: isToday ? Border.all(color: colorScheme.primary) : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${day.day}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isCurrentMonth
                        ? colorScheme.onSurface
                        : colorScheme.onSurface.withValues(alpha: 0.35),
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                const Spacer(),
                Wrap(
                  spacing: 2,
                  runSpacing: 2,
                  children: [
                    ...dayEntries.take(maxDots).map((e) => _buildDot(e)),
                    if (dayEntries.length > maxDots)
                      Text(
                        '+${dayEntries.length - maxDots}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDot(LedgerEntry entry) {
    final color = entry.amount > 0 ? Colors.green.shade600 : Colors.red.shade600;
    final isActual = entry.isConcrete || entry.status == EntryStatus.confirmed;
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isActual ? color : Colors.transparent,
        border: isActual ? null : Border.all(color: color, width: 1.2),
      ),
    );
  }

  // ── Budget banners ──────────────────────────────────────────────────

  /// Whether [budget] has an active period starting at [periodStart].
  ///
  /// Recurring budgets are active for every period from their start
  /// onward (until [Budget.endDate], if any). Non-recurring budgets are
  /// only active for the single period containing their start date.
  bool _budgetActiveInPeriod(Budget budget, DateTime periodStart) {
    final ownPeriodStart = budget.currentPeriodStart(periodStart);
    final budgetStartPeriod = budget.currentPeriodStart(budget.startDate);

    if (ownPeriodStart.isBefore(budgetStartPeriod)) return false;
    if (!budget.isRecurring && !ownPeriodStart.isAtSameMomentAs(budgetStartPeriod)) {
      return false;
    }
    if (budget.endDate != null) {
      final budgetEndPeriod = budget.currentPeriodStart(budget.endDate!);
      if (ownPeriodStart.isAfter(budgetEndPeriod)) return false;
    }
    return true;
  }

  double _spentForBudgetInPeriod(Budget budget, DateTime periodStart, DateTime periodEnd) {
    return widget.entries
        .where((e) =>
            e.category?.toLowerCase() == budget.category.toLowerCase() &&
            !e.date.isBefore(periodStart) &&
            !e.date.isAfter(periodEnd))
        .fold<double>(0.0, (sum, e) => sum + e.amount.abs());
  }

  Widget _buildBanners(
    ThemeData theme,
    List<Budget> budgets,
    DateTime periodStart,
    {required IconData icon}
  ) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        children: budgets.map((budget) {
          final periodEnd = budget.currentPeriodEnd(periodStart);
          final spent = _spentForBudgetInPeriod(budget, periodStart, periodEnd);
          final remaining = budget.effectiveAmount - spent;
          final isOver = remaining < 0;
          final color = isOver ? Colors.red.shade700 : colorScheme.primary;

          return Container(
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${budget.name} · ${_currencyFormat.format(spent)} / '
                    '${_currencyFormat.format(budget.effectiveAmount)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Legend ──────────────────────────────────────────────────────────

  Widget _buildLegend(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    Widget legendItem(Widget marker, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            marker,
            const SizedBox(width: 4),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        );

    Widget legendDot({required bool filled, required Color color}) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : Colors.transparent,
            border: filled ? null : Border.all(color: color, width: 1.2),
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          legendItem(legendDot(filled: true, color: Colors.green.shade600), 'Actual income'),
          legendItem(legendDot(filled: true, color: Colors.red.shade600), 'Actual expense'),
          legendItem(legendDot(filled: false, color: Colors.green.shade600), 'Planned income'),
          legendItem(legendDot(filled: false, color: Colors.red.shade600), 'Planned expense'),
          legendItem(Icon(Icons.flag, size: 12, color: colorScheme.primary), 'Budget'),
        ],
      ),
    );
  }

  // ── Day detail sheet ────────────────────────────────────────────────

  void _showDayDetails(BuildContext context, DateTime day, List<LedgerEntry> entries) {
    final theme = Theme.of(context);
    final dateLabel = DateFormat('EEEE, MMMM d, yyyy').format(day);

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dateLabel,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...entries.map((e) => _buildEntryTile(theme, e)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntryTile(ThemeData theme, LedgerEntry entry) {
    final colorScheme = theme.colorScheme;
    final isIncome = entry.amount > 0;
    final isActual = entry.isConcrete || entry.status == EntryStatus.confirmed;
    final color = isIncome ? Colors.green.shade700 : Colors.red.shade700;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            isActual ? Icons.check_circle : Icons.circle_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                if (entry.category != null)
                  Text(
                    entry.category!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            _currencyFormat.format(entry.amount),
            style: TextStyle(fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  Map<DateTime, List<LedgerEntry>> _groupEntriesByDay(List<LedgerEntry> entries) {
    final map = <DateTime, List<LedgerEntry>>{};
    for (final entry in entries) {
      final key = DateTime(entry.date.year, entry.date.month, entry.date.day);
      map.putIfAbsent(key, () => []).add(entry);
    }
    return map;
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
