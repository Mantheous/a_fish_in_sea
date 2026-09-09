import 'package:a_fish_in_sea/common/undo/revertable_hydrated_cubit.dart';
import 'package:a_fish_in_sea/goals/model/tag.dart';

class TagCubit extends RevertableHydratedCubit<List<GoalTag>> {
  TagCubit() : super(const []);

  void addTag(GoalTag tag) => emitChange([...state, tag]);

  void updateTag(GoalTag updated) => emitChange(
      state.map((t) => t.id == updated.id ? updated : t).toList());

  void deleteTag(String id) {
    if (createsCycle(id, null)) return;
    emitChange(state.where((t) => t.id != id).toList());
  }

  GoalTag? byId(String id) {
    try {
      return state.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  List<GoalTag> childrenOf(String? parentId) =>
      state.where((t) => t.parentId == parentId).toList();

  List<GoalTag> get roots => childrenOf(null);

  bool createsCycle(String tagId, String? newParentId) {
    var current = newParentId;
    final byIdMap = {for (final t in state) t.id: t};
    while (current != null) {
      if (current == tagId) return true;
      current = byIdMap[current]?.parentId;
    }
    return false;
  }

  String? nameFor(String id) => byId(id)?.name;

  @override
  List<GoalTag>? fromJson(Map<String, dynamic> json) {
    final list = json['tags'] as List<dynamic>?;
    if (list == null) return null;
    final out = <GoalTag>[];
    for (final item in list) {
      try {
        out.add(GoalTag.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Map<String, dynamic> toJson(List<GoalTag> state) =>
      {'tags': state.map((t) => t.toJson()).toList()};
}
