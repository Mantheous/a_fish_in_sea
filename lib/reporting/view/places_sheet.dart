import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/places_cubit.dart';
import '../model/place.dart';
import '../service/location_service.dart';

Future<void> showPlacesSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _PlacesSheet(),
  );
}

class _PlacesSheet extends StatelessWidget {
  const _PlacesSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, controller) {
          final places = context.watch<PlacesCubit>().state;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Saved places',
                          style:
                              Theme.of(context).textTheme.titleMedium),
                    ),
                    IconButton(
                      tooltip: 'Add place',
                      icon: const Icon(Icons.add),
                      onPressed: () => showPlaceEditor(context),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: places.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No places yet. Add Home, Work, the library… '
                            'Events linked to a place are auto-reported '
                            'when you spend time there.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: controller,
                        itemCount: places.length,
                        itemBuilder: (context, index) {
                          final place = places[index];
                          return ListTile(
                            leading: const Icon(Icons.place_outlined),
                            title: Text(place.name),
                            subtitle: Text(
                              '${place.lat.toStringAsFixed(5)}, '
                              '${place.lng.toStringAsFixed(5)} · '
                              '${place.radiusM.round()} m',
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'edit') {
                                  showPlaceEditor(context, existing: place);
                                } else if (value == 'delete') {
                                  context
                                      .read<PlacesCubit>()
                                      .deletePlace(place.id);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                    value: 'edit', child: Text('Edit')),
                                PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete')),
                              ],
                            ),
                            onTap: () =>
                                showPlaceEditor(context, existing: place),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

Future<void> showPlaceEditor(BuildContext context, {Place? existing}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _PlaceEditorSheet(existing: existing),
    ),
  );
}

class _PlaceEditorSheet extends StatefulWidget {
  final Place? existing;

  const _PlaceEditorSheet({this.existing});

  @override
  State<_PlaceEditorSheet> createState() => _PlaceEditorSheetState();
}

class _PlaceEditorSheetState extends State<_PlaceEditorSheet> {
  late final TextEditingController _name;
  late final TextEditingController _lat;
  late final TextEditingController _lng;
  late double _radius;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _lat = TextEditingController(
        text: widget.existing == null ? '' : '${widget.existing!.lat}');
    _lng = TextEditingController(
        text: widget.existing == null ? '' : '${widget.existing!.lng}');
    _radius = widget.existing?.radiusM ?? 100;
  }

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    try {
      final granted = await ensureLocationPermission();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied')),
          );
        }
        return;
      }
      final point = await samplePosition();
      if (point != null && mounted) {
        setState(() {
          _lat.text = '${point.lat}';
          _lng.text = '${point.lng}';
        });
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not get a GPS fix')),
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null ? 'New place' : 'Edit place',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              decoration: const InputDecoration(
                labelText: 'Name (e.g. Home, Library)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _lat,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Latitude',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _lng,
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Longitude',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed:
                  (_locating || !LocationService.supported) ? null : _useCurrentLocation,
              icon: _locating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location, size: 18),
              label: Text(LocationService.supported
                  ? 'Use current location'
                  : 'GPS available on mobile only'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Radius'),
                Expanded(
                  child: Slider(
                    min: 25,
                    max: 500,
                    divisions: 19,
                    value: _radius,
                    label: '${_radius.round()} m',
                    onChanged: (v) => setState(() => _radius = v),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text('${_radius.round()} m',
                      textAlign: TextAlign.end),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _save(context),
                  child: Text(
                      widget.existing == null ? 'Add' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _save(BuildContext context) {
    final name = _name.text.trim();
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    if (name.isEmpty || lat == null || lng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enter a name and valid coordinates')),
      );
      return;
    }
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Coordinates out of range')),
      );
      return;
    }
    final cubit = context.read<PlacesCubit>();
    if (widget.existing == null) {
      cubit.addPlace(Place(
        id: 'place:${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        lat: lat,
        lng: lng,
        radiusM: _radius,
      ));
    } else {
      cubit.updatePlace(
        widget.existing!.copyWith(
          name: name,
          lat: lat,
          lng: lng,
          radiusM: _radius,
        ),
      );
    }
    Navigator.of(context).pop();
  }
}
