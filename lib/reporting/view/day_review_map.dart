import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../model/place.dart';
import '../model/tracked_point.dart';

/// Keep route geometry and place layers stable while the scrub marker moves.
class DayReviewMap extends StatefulWidget {
  final List<TrackedPoint> points;
  final List<Place> places;
  final LatLng? atScrub;

  const DayReviewMap({
    super.key,
    required this.points,
    required this.places,
    required this.atScrub,
  });

  @override
  State<DayReviewMap> createState() => _DayReviewMapState();
}

class _DayReviewMapState extends State<DayReviewMap> {
  List<TrackedPoint>? _pointsSource;
  List<Place>? _placesSource;
  Widget? _route;
  Widget? _circles;
  Widget? _placeMarkers;

  void _updateLayers() {
    if (!identical(_pointsSource, widget.points)) {
      _pointsSource = widget.points;
      _route = widget.points.length < 2
          ? null
          : PolylineLayer(
              polylines: [
                Polyline(
                  points: [for (final p in widget.points) LatLng(p.lat, p.lng)],
                  color: Colors.blue,
                  strokeWidth: 4,
                ),
              ],
            );
    }
    if (!identical(_placesSource, widget.places)) {
      _placesSource = widget.places;
      _circles = widget.places.isEmpty
          ? null
          : CircleLayer(
              circles: [
                for (final place in widget.places)
                  CircleMarker(
                    point: LatLng(place.lat, place.lng),
                    radius: place.radiusM,
                    useRadiusInMeter: true,
                    color: Colors.teal.withValues(alpha: 0.15),
                    borderColor: Colors.teal,
                    borderStrokeWidth: 2,
                  ),
              ],
            );
      _placeMarkers = MarkerLayer(
        markers: [
          for (final place in widget.places)
            Marker(
              point: LatLng(place.lat, place.lng),
              width: 120,
              height: 28,
              child: Container(
                alignment: Alignment.topCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.teal),
                  ),
                  child: Text(
                    place.name,
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _updateLayers();
    final points = widget.points;
    final places = widget.places;
    final center =
        widget.atScrub ??
        (points.isNotEmpty
            ? LatLng(points.last.lat, points.last.lng)
            : places.isNotEmpty
            ? LatLng(places.first.lat, places.first.lng)
            : const LatLng(40.23, -111.66));
    return SizedBox(
      height: 240,
      child: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: center,
              initialZoom: points.isEmpty ? 11 : 14,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'a_fish_in_sea',
              ),
              if (_circles != null) _circles!,
              if (_route != null) _route!,
              MarkerLayer(
                markers: [
                  if (widget.atScrub != null)
                    Marker(
                      point: widget.atScrub!,
                      width: 36,
                      height: 36,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.red,
                        size: 32,
                      ),
                    ),
                ],
              ),
              _placeMarkers!,
            ],
          ),
          if (points.isEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.all(8),
                child: const Text(
                  'No points this day — press Start on Home, or add a test point below.',
                  style: TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
