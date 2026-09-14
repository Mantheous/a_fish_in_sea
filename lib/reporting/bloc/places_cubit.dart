import '../../common/undo/revertable_hydrated_cubit.dart';
import '../model/place.dart';

class PlacesCubit extends RevertableHydratedCubit<List<Place>> {
  PlacesCubit() : super(const []);

  void addPlace(Place place) => emitChange([...state, place]);

  void updatePlace(Place place) => emitChange(
        state.map((p) => p.id == place.id ? place : p).toList(),
      );

  void deletePlace(String id) =>
      emitChange(state.where((p) => p.id != id).toList());

  Place? byId(String? id) {
    if (id == null) return null;
    for (final place in state) {
      if (place.id == id) return place;
    }
    return null;
  }

  Map<String, String> get names => {for (final p in state) p.id: p.name};

  @override
  List<Place>? fromJson(Map<String, dynamic> json) {
    final list = json['places'] as List<dynamic>?;
    if (list == null) return const [];
    final out = <Place>[];
    for (final item in list) {
      try {
        out.add(Place.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<Place> state) =>
      {'places': state.map((p) => p.toJson()).toList()};
}
