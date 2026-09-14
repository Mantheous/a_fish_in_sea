import 'package:equatable/equatable.dart';

class TrackedPoint extends Equatable {
  final String id;
  final DateTime timestamp;
  final double lat;
  final double lng;
  final double? accuracy;

  const TrackedPoint({
    required this.id,
    required this.timestamp,
    required this.lat,
    required this.lng,
    this.accuracy,
  });

  factory TrackedPoint.fromJson(Map<String, dynamic> json) => TrackedPoint(
        id: json['id'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        accuracy: (json['accuracy'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'lat': lat,
        'lng': lng,
        'accuracy': accuracy,
      };

  @override
  List<Object?> get props => [id, timestamp, lat, lng, accuracy];
}
