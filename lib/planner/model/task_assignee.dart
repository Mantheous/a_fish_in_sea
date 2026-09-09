import 'package:equatable/equatable.dart';

class TaskAssignee extends Equatable {
  final String id;
  final String displayName;
  final String? email;
  final String? photoUrl;
  final String? placeId;

  const TaskAssignee({
    required this.id,
    required this.displayName,
    this.email,
    this.photoUrl,
    this.placeId,
  });

  String get searchKey =>
      '${displayName.toLowerCase()} ${(email ?? '').toLowerCase()}';

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return searchKey.contains(q);
  }

  TaskAssignee copyWith({
    String? displayName,
    String? email,
    bool clearEmail = false,
    String? photoUrl,
    bool clearPhotoUrl = false,
    String? placeId,
    bool clearPlaceId = false,
  }) =>
      TaskAssignee(
        id: id,
        displayName: displayName ?? this.displayName,
        email: clearEmail ? null : (email ?? this.email),
        photoUrl: clearPhotoUrl ? null : (photoUrl ?? this.photoUrl),
        placeId: clearPlaceId ? null : (placeId ?? this.placeId),
      );

  factory TaskAssignee.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'] as String?;
    final rawEmail = json['email'] as String?;
    final rawName = json['displayName'] as String?;
    final id = (rawId ?? '').trim().isNotEmpty
        ? rawId!.trim()
        : (rawEmail ?? '').trim().isNotEmpty
            ? rawEmail!.trim()
            : (rawName ?? '').trim();
    final displayName = (rawName ?? '').trim().isNotEmpty
        ? rawName!.trim()
        : (rawEmail ?? '').trim().isNotEmpty
            ? rawEmail!.trim()
            : id;
    if (id.isEmpty || displayName.isEmpty) {
      throw const FormatException('TaskAssignee needs an id or name');
    }
    final photo = json['photoUrl'] as String?;
    final place = json['placeId'] as String?;
    return TaskAssignee(
      id: id,
      displayName: displayName,
      email: (rawEmail ?? '').trim().isEmpty ? null : rawEmail!.trim(),
      photoUrl: (photo ?? '').trim().isEmpty ? null : photo!.trim(),
      placeId: (place ?? '').trim().isEmpty ? null : place!.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'email': email,
        'photoUrl': photoUrl,
        'placeId': placeId,
      };

  @override
  List<Object?> get props => [id, displayName, email, photoUrl, placeId];
}
