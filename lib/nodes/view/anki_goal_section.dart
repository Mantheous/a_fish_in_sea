import 'package:a_fish_in_sea/anki/anki_reports.dart';
import 'package:a_fish_in_sea/finances/model/time_scale.dart';
import 'package:flutter/material.dart';

/// The "Memorization (Anki)" block in the goal editor.
///
/// Extracted from node_editor.dart so the add-on flow (live count preview,
/// refresh, paste fallback) has one owner. The parent keeps the text
/// controllers and the save/parse rules; this widget only renders them.
class AnkiGoalSection extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;

  final TextEditingController deck;
  final VoidCallback onDeckChanged;
  final List<String> deckOptions;
  final TextEditingController targetReviews;
  final TextEditingController manualReviews;
  final TextEditingController customPeriodDays;
  final TimeScale? period;
  final ValueChanged<TimeScale?> onPeriodChanged;

  final DateTime? syncedAt;
  final bool syncing;
  final VoidCallback onSync;
  final VoidCallback onPaste;

  /// Live reading for the deck/period currently in the form. Null when
  /// the add-on has not reported that deck yet.
  final AnkiFacetCount? serverCount;

  const AnkiGoalSection({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
    required this.deck,
    required this.onDeckChanged,
    this.deckOptions = const [],
    required this.targetReviews,
    required this.manualReviews,
    required this.customPeriodDays,
    required this.period,
    required this.onPeriodChanged,
    required this.syncedAt,
    required this.syncing,
    required this.onSync,
    required this.onPaste,
    this.serverCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            'Memorization (Anki)',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Has memorization target'),
          subtitle: const Text(
            'Review N Anki cards per period — counts come from the Anki '
            'add-on through the server',
          ),
          value: enabled,
          onChanged: onEnabledChanged,
        ),
        if (enabled) ...[
          TextField(
            controller: deck,
            onChanged: (_) => onDeckChanged(),
            decoration: const InputDecoration(
              labelText: 'Deck (blank = all decks)',
              helperText:
                  'Subdecks count too: “Japanese” includes '
                  '“Japanese::Vocab”.',
              border: OutlineInputBorder(),
            ),
          ),
          if (deckOptions.isNotEmpty) ...[
            const SizedBox(height: 4),
            DropdownButton<String>(
              value: deckOptions.contains(deck.text.trim())
                  ? deck.text.trim()
                  : null,
              hint: const Text('Pick a deck the add-on has reported'),
              isExpanded: true,
              items: [
                for (final name in deckOptions)
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: (value) {
                if (value == null) return;
                deck.text = value;
                onDeckChanged();
              },
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: targetReviews,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Target cards',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<TimeScale?>(
            initialValue: period,
            decoration: const InputDecoration(labelText: 'Period (optional)'),
            items: [
              const DropdownMenuItem(value: null, child: Text('One-time')),
              for (final scale in TimeScale.values)
                DropdownMenuItem(value: scale, child: Text(scale.displayName)),
            ],
            onChanged: onPeriodChanged,
          ),
          if (period == TimeScale.custom) ...[
            const SizedBox(height: 8),
            TextField(
              controller: customPeriodDays,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Custom period (days, from goal start)',
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: manualReviews,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Manual count (fallback)',
              helperText: 'Used only until the add-on reports this deck.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          if (serverCount != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Add-on reports ${serverCount!.cards} '
                'card${serverCount!.cards == 1 ? '' : 's'} '
                '(${serverCount!.reviews} answer'
                '${serverCount!.reviews == 1 ? '' : 's'}) for this '
                'deck and period.'
                '${serverCount!.lastDay == null ? '' : ' Latest day: '
                          '${ankiIsoDay(serverCount!.lastDay!)}.'}',
                style: theme.textTheme.bodySmall,
              ),
            )
          else if (syncedAt != null)
            Text(
              'Last counted ${MaterialLocalizations.of(context).formatFullDate(syncedAt!)}',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: syncing ? null : onSync,
                icon: syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 16),
                label: const Text('Refresh from add-on'),
              ),
              TextButton.icon(
                onPressed: onPaste,
                icon: const Icon(Icons.upload_outlined, size: 16),
                label: const Text('Paste stats'),
              ),
            ],
          ),
          Text(
            'Reports are sent by the Anki add-on. The server keeps one '
            'daily total per deck and device clocks never enter the count.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
