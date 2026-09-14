import 'package:equatable/equatable.dart';

class Place extends Equatable {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final double radiusM;

  const Place({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.radiusM = 100,
  });

  Place copyWith({String? name, double? lat, double? lng, double? radiusM}) =>
      Place(
        id: id,
        name: name ?? this.name,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        radiusM: radiusM ?? this.radiusM,
      );

  factory Place.fromJson(Map<String, dynamic> json) => Place(
        id: json['id'] as String,
        name: json['name'] as String,
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        radiusM: ((json['radiusM'] as num?) ?? 100).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lng': lng,
        'radiusM': radiusM,
      };

  @override
  List<Object?> get props => [id, name, lat, lng, radiusM];
}
