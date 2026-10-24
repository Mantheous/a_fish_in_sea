import 'package:flutter/material.dart';

import '../../planner/model/feed.dart';

/// Result of [showColorPickerSheet]. A null [color] means "automatic" (let
/// the app pick); the whole result is null when the sheet was dismissed.
class ColorChoice {
  final int? color;
  const ColorChoice(this.color);
}

Future<ColorChoice?> showColorPickerSheet(
  BuildContext context, {
  required String title,
  int? selected,
  bool allowAuto = true,
  String autoLabel = 'Automatic',
}) {
  return showModalBottomSheet<ColorChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _ColorPickerSheet(
      title: title,
      selected: selected,
      allowAuto: allowAuto,
      autoLabel: autoLabel,
    ),
  );
}

/// Shared palette swatches plus a hue/saturation/lightness custom color.
///
/// Custom colors pass through [mutedCalendarColor] before they are saved,
/// the same guard feed and Google colors use: calendar tiles always paint
/// white text, so an arbitrary bright color would be unreadable.
class _ColorPickerSheet extends StatefulWidget {
  final String title;
  final int? selected;
  final bool allowAuto;
  final String autoLabel;

  const _ColorPickerSheet({
    required this.title,
    required this.selected,
    required this.allowAuto,
    required this.autoLabel,
  });

  @override
  State<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends State<_ColorPickerSheet> {
  int? _selected;
  late HSLColor _custom;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected;
    _custom = HSLColor.fromColor(
      widget.selected == null
          ? const Color(0xFF6B8F8A)
          : Color(widget.selected!),
    );
  }

  Color get _customColor => mutedCalendarColor(_custom.toColor());

  void _pick(int? value) => Navigator.of(context).pop(ColorChoice(value));

  void _setCustom({double? hue, double? saturation, double? lightness}) {
    setState(() {
      _custom = _custom
          .withHue(hue ?? _custom.hue)
          .withSaturation(saturation ?? _custom.saturation)
          .withLightness(lightness ?? _custom.lightness);
      _selected = _customColor.toARGB32();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.title, style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            if (widget.allowAuto)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.auto_awesome_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: Text(widget.autoLabel),
                subtitle: const Text('Follow class and calendar colors'),
                trailing: _selected == null
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                onTap: () => _pick(null),
              ),
            const SizedBox(height: 4),
            Text('Palette', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final value in Feed.palette)
                  _Swatch(
                    key: ValueKey(value),
                    colorValue: value,
                    selected: _selected == value,
                    onTap: () => _pick(value),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Custom color', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _customColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Preview on a calendar tile. Custom colors are muted the '
                    'same amount as imported calendars so the white text '
                    'stays readable.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            _SliderRow(
              label: 'Hue',
              value: _custom.hue,
              max: 360,
              format: (v) => '${v.round()}°',
              onChanged: (v) => _setCustom(hue: v),
            ),
            _SliderRow(
              label: 'Saturation',
              value: _custom.saturation,
              max: 1,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) => _setCustom(saturation: v),
            ),
            _SliderRow(
              label: 'Lightness',
              value: _custom.lightness,
              max: 1,
              format: (v) => '${(v * 100).round()}%',
              onChanged: (v) => _setCustom(lightness: v),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _pick(_customColor.toARGB32()),
                child: const Text('Use custom color'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 82, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(0, max),
            max: max,
            label: format(value),
            semanticFormatterCallback: format,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final int colorValue;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    super.key,
    required this.colorValue,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Color ${colorValue.toRadixString(16)}',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Color(colorValue),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 3,
            ),
          ),
          child: selected
              ? const Icon(Icons.check, size: 20, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}
