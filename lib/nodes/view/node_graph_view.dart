import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../planner/bloc/calendar_cubit.dart';
import '../bloc/node_cubit.dart';
import '../model/node.dart';
import '../service/node_event_link.dart';
import '../service/node_graph_fold.dart';
import '../service/node_graph_layout.dart';
import 'node_editor.dart';
import 'node_finish_sheet.dart';
import 'node_graph_action_bar.dart';
import 'node_graph_canvas.dart';
import 'node_graph_chrome.dart';
import 'node_graph_multi_action_bar.dart';
import 'node_graph_selection_actions.dart';
import 'node_graph_viewport.dart';

/// Graphical top-down view of the goal DAG, following the board in
/// `docs/goal-tree-issue-4.png`: layered cards joined by curved connectors.
///
/// An alternative to the list views, not a replacement: tap a card to select
/// it, tap it again to edit (same editor as everywhere else). A selected
/// card floats an action bar with the goal's quick controls — record time
/// toward it, edit, add a subgoal or parent, mark it complete — while the
/// −/+ badge under a card collapses or expands that subtree. Each card also
/// grows the tree in place: its `↓` button creates a subgoal beneath it and
/// its `↑` button creates a parent goal above it.
///
/// Pan is the default tool: dragging moves the graph, while tapping a card
/// still selects it (tap again to edit). The Select tool button (or V) turns
/// empty-canvas drags into marquee selection; shift/ctrl/cmd-click adds
/// cards, and long-press enters tap-to-toggle selection on touch. Two or
/// more selected goals float a bulk bar that opens the multi-goal editor
/// (titles stay individual) and can mark the group done or delete it in one
/// undoable step. Pan and zoom around large trees; repeating templates and
/// goals with a very wide fan-out start collapsed so their generated
/// instances or subgoal walls don't flood the graph. Folding is reported through [onCollapsedChanged]
/// and can be restored with [collapsedIds], so leaving the Goals tab and
/// coming back shows the same graph.
class NodeGraphView extends StatefulWidget {
  const NodeGraphView({
    super.key,
    required this.nodes,
    required this.progress,
    this.visibleIds,
    this.contextIds = const <String>{},
    this.matchedIds = const <String>{},
    this.filterActive = false,
    this.filterSummary,
    this.fitToken = 0,
    this.expandAll = false,
    this.expandToken = 0,
    this.collapsedIds,
    this.onCollapsedChanged,
    this.onClearFilters,
  });

  /// Goal-tree nodes (see [goalNodes]).
  final List<Node> nodes;

  /// Progress per node id, from `progressForest`.
  final Map<String, double> progress;

  /// Restriction from search/filter; null = show everything. When set, the
  /// graph ignores manual collapse so matches are always reachable.
  final Set<String>? visibleIds;

  /// Filtered-out ancestors of the matches. These render as compact path
  /// markers instead of full cards, preserving "this connects to this".
  final Set<String> contextIds;

  /// Goals that passed the active filter/search; these get the match
  /// outline and a full card.
  final Set<String> matchedIds;

  /// True when [contextIds] came from the filter menu (not plain search).
  final bool filterActive;

  /// Human summary of the active filter, shown in the stats pill.
  final String? filterSummary;

  /// Bumped when the filter changes so the viewport re-fits the new graph
  /// instead of keeping the previous pan/zoom.
  final int fitToken;

  /// Mirrors the page-level expand/collapse-all button. [expandToken] bumps
  /// on every tap; [expandAll] is the new state.
  final bool expandAll;
  final int expandToken;

  /// Folded subtree ids carried across page visits. Null means "seed the
  /// defaults": repeating templates and goals with more than five direct
  /// subgoals start collapsed. A non-null set is the user's own fold state
  /// and is used as-is, so a manual expand survives a tab switch.
  final Set<String>? collapsedIds;

  /// Reports the folded set whenever it changes (default seed, a toggle, or
  /// the page-level expand/collapse-all), so the owner can keep it.
  final ValueChanged<Set<String>>? onCollapsedChanged;

  /// Clears the active filter from the graph's empty state.
  final VoidCallback? onClearFilters;

  @override
  State<NodeGraphView> createState() => _NodeGraphViewState();
}

class _NodeGraphViewState extends State<NodeGraphView> {
  final Set<String> _collapsed = <String>{};
  bool _seeded = false;

  /// Selected goal ids. Selection is transient view state (never persisted):
  /// it clears on a background tap, the bar's ✕, a collapse that hides a
  /// selected card, and a tab switch.
  final Set<String> _selected = <String>{};

  /// True after a long-press: on touch there are no modifier keys, so taps
  /// toggle membership until the selection is closed.
  bool _multiSelectMode = false;

  /// Selection that existed when an additive marquee started. Marquee ids
  /// replace the live selection, but this base is kept while the drag grows
  /// and shrinks.
  Set<String> _marqueeBase = const {};

  /// Most recently added goal. The viewport pans just enough to show it
  /// without changing zoom, so growing the tree is visible even when the
  /// new card lands outside the current view (e.g. a new parent root to
  /// the right of the tree).
  String? _revealId;
  int _revealToken = 0;

  @override
  void didUpdateWidget(covariant NodeGraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pruneSelection();
    if (widget.expandToken != oldWidget.expandToken) {
      final withKids = parentIds(widget.nodes);
      _seeded = true;
      _collapsed
        ..clear()
        ..addAll(widget.expandAll ? const <String>[] : withKids);
      // Collapse-all folds selected cards out of view.
      if (!widget.expandAll) _clearSelectionState();
      _reportCollapsed();
    }
  }

  void _pruneSelection() {
    final present = {for (final node in widget.nodes) node.id};
    _selected.removeWhere((id) => !present.contains(id));
    final visible = widget.visibleIds;
    if (visible != null) {
      _selected.removeWhere((id) => !visible.contains(id));
    }
    if (_selected.isEmpty) _multiSelectMode = false;
  }

  void _clearSelectionState() {
    _selected.clear();
    _multiSelectMode = false;
    _marqueeBase = const {};
  }

  /// One-time seed, once goals exist. A set carried in
  /// [NodeGraphView.collapsedIds] wins: that is the fold state from an
  /// earlier visit to the page. Otherwise habits/budgets generate an
  /// instance per period and goals with more than [kGraphAutoCollapseSubgoals]
  /// direct subgoals flood the canvas, so both start folded — the first
  /// screen shows the shape of the tree, not one goal's whole fan-out.
  void _seedIfNeeded() {
    if (_seeded || widget.nodes.isEmpty) return;
    _seeded = true;
    final saved = widget.collapsedIds;
    _collapsed.addAll(saved ?? defaultCollapsedIds(widget.nodes));
    if (saved == null) _reportCollapsed();
  }

  /// Hands the current folded set to the owner. Deferred to after the frame:
  /// the seed runs during build and the expand-all path runs inside
  /// [didUpdateWidget], so the owner must not rebuild mid-frame.
  void _reportCollapsed() {
    final notify = widget.onCollapsedChanged;
    if (notify == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) notify(Set<String>.unmodifiable(_collapsed));
    });
  }

  /// Parent ids that have at least one child in [nodes].
  @override
  Widget build(BuildContext context) {
    _seedIfNeeded();
    final restricted = widget.visibleIds != null;
    final layout = layoutNodeGraph(
      nodes: widget.nodes,
      collapsedIds: restricted ? const <String>{} : _collapsed,
      visibleIds: widget.visibleIds,
      compactIds: widget.contextIds,
    );
    if (layout.isEmpty) {
      return GraphEmptyState(
        filtering: widget.filterActive,
        restricting: restricted,
        onClearFilters: widget.onClearFilters,
      );
    }
    // Selection is only actionable while its card is on screen: a collapse
    // or filter that hides it also hides the bar.
    final placeable = {
      for (final placement in layout.placements) placement.node.id,
    };
    final selected = _selected.where(placeable.contains).toSet();
    final selectedNodes = [
      for (final node in widget.nodes)
        if (selected.contains(node.id)) node,
    ];
    final single = selectedNodes.length == 1 ? selectedNodes.single : null;
    final multi = selectedNodes.length > 1;
    final allDone =
        selectedNodes.isNotEmpty && selectedNodes.every((node) => node.isDone);
    final canToggleDone = selectedNodes.every((node) => !node.isUnbounded);

    final canvas = NodeGraphCanvas(
      layout: layout,
      progress: widget.progress,
      matches: widget.matchedIds,
      selectedIds: selected,
      showToggles: !restricted,
      onCardTap: _onCardTap,
      onCardLongPress: _onCardLongPress,
      onBackgroundTap: _clearSelection,
      onToggle: _toggleCollapsed,
      onAddSubgoal: _addSubgoal,
      onAddParent: _addParent,
    );
    final shown = restricted
        ? widget.matchedIds.length
        : layout.placements.length;
    GraphNodePlacement? reveal;
    if (_revealId != null) {
      for (final placement in layout.placements) {
        if (placement.node.id == _revealId) {
          reveal = placement;
          break;
        }
      }
    }
    return Stack(
      children: [
        Positioned.fill(
          child: NodeGraphViewport(
            layoutSize: layout.size,
            placements: layout.placements,
            fitToken: widget.fitToken,
            revealRect: reveal?.rect,
            revealToken: _revealToken,
            onMarqueeStart: _onMarqueeStart,
            onMarqueeChanged: _onMarqueeChanged,
            onMarqueeEnd: () => _marqueeBase = const {},
            onSelectAll: () => _selectAll(layout.placements),
            onClearSelection: _clearSelection,
            child: canvas,
          ),
        ),
        Positioned(
          left: 12,
          right: 224,
          top: 10,
          child: Align(
            alignment: Alignment.centerLeft,
            child: GraphPill(
              text: widget.filterActive
                  ? '$shown of ${widget.nodes.length} goals · '
                        '${widget.filterSummary ?? 'filtered'}'
                  : '$shown of ${widget.nodes.length} goals',
            ),
          ),
        ),
        if (multi)
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: NodeGraphMultiActionBar(
                count: selectedNodes.length,
                allDone: allDone,
                canToggleDone: canToggleDone,
                onEdit: () => _editSelected(selectedNodes),
                onToggleDone: () =>
                    _toggleSelectedDone(selectedNodes, allDone: allDone),
                onDelete: () => _deleteSelected(selectedNodes),
                onClose: _clearSelection,
              ),
            ),
          )
        else if (single != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: NodeGraphActionBar(
                key: nodeGraphActionBarKey,
                node: single,
                onRecord: () => _toggleRecording(single),
                onEdit: () => showNodeEditor(context, existing: single),
                onAddSubgoal: single.instanceOfId == null
                    ? () => _addSubgoal(single)
                    : null,
                onAddParent: single.instanceOfId == null
                    ? () => _addParent(single)
                    : null,
                onToggleDone: single.isUnbounded
                    ? null
                    : () => _toggleDone(single),
                onClose: _clearSelection,
              ),
            ),
          )
        else
          Positioned(
            left: 12,
            bottom: 10,
            child: GraphPill(
              text: widget.filterActive
                  ? 'Filtered-out goals collapse · links stay visible'
                  : 'Drag to pan · tap to select · Select tool for marquee · long-press multi-select',
            ),
          ),
      ],
    );
  }

  bool get _additivePressed =>
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  /// Card tap: the first tap selects the goal and opens its action bar; a
  /// tap on the only selected card opens the editor, the same as before.
  /// With a modifier (or once touch multi-select started) the tap toggles
  /// membership instead.
  void _onCardTap(Node node) {
    final additive = _additivePressed;
    final sole = _selected.length == 1 && _selected.contains(node.id);
    if (!additive && !_multiSelectMode && sole) {
      showNodeEditor(context, existing: node);
      return;
    }
    setState(() {
      if (additive || _multiSelectMode) {
        if (!_selected.remove(node.id)) _selected.add(node.id);
        if (_selected.isEmpty) _multiSelectMode = false;
      } else {
        _selected
          ..clear()
          ..add(node.id);
        _multiSelectMode = false;
      }
    });
  }

  /// Long-press is the touch entry to multi-select: it selects the card and
  /// makes subsequent taps toggle instead of replacing the selection.
  void _onCardLongPress(Node node) {
    setState(() {
      _multiSelectMode = true;
      _selected.add(node.id);
    });
  }

  void _onMarqueeStart(bool additive) {
    _marqueeBase = additive ? Set.of(_selected) : const {};
    if (!additive) {
      setState(_clearSelectionState);
    }
  }

  void _onMarqueeChanged(Set<String> ids) {
    setState(() {
      _selected
        ..clear()
        ..addAll(_marqueeBase)
        ..addAll(ids);
      _multiSelectMode = false;
    });
  }

  void _selectAll(List<GraphNodePlacement> placements) {
    setState(() {
      _selected
        ..clear()
        ..addAll([
          for (final placement in placements)
            if (!placement.compact) placement.node.id,
        ]);
      _multiSelectMode = false;
    });
  }

  void _clearSelection() {
    if (_selected.isEmpty && !_multiSelectMode) return;
    setState(_clearSelectionState);
  }

  /// Folds or unfolds [id] and drops every selection the fold hides.
  void _toggleCollapsed(String id) {
    final collapsing = !_collapsed.contains(id);
    setState(() {
      if (!_collapsed.remove(id)) _collapsed.add(id);
      if (collapsing) {
        _selected.removeWhere(
          (selectedId) =>
              selectedId != id && hasAncestor(widget.nodes, selectedId, id),
        );
        if (_selected.isEmpty) _multiSelectMode = false;
      }
    });
    _reportCollapsed();
  }

  Future<void> _editSelected(List<Node> nodes) async {
    final changed = await editSelectedGoals(context, nodes);
    if (mounted && changed) _clearSelection();
  }

  /// Marks the group complete, or reopens it when every selected goal was
  /// already done. One undoable write mirroring linked calendar events.
  void _toggleSelectedDone(List<Node> nodes, {required bool allDone}) {
    markSelectedGoalsDone(context, nodes, allDone: allDone);
    if (mounted) _clearSelection();
  }

  Future<void> _deleteSelected(List<Node> nodes) async {
    final deleted = await deleteSelectedGoals(context, nodes);
    if (mounted && deleted) _clearSelection();
  }

  /// Starts the selected goal's timer, or stops it through the same finish
  /// flow the task rows use (which mirrors the run onto linked events).
  void _toggleRecording(Node node) {
    if (node.isTracking) {
      stopNodeAndFinish(context, node.id);
      return;
    }
    try {
      NodeEventLink.startNodeTracking(
        context.read<NodeCubit>(),
        context.read<CalendarCubit>(),
        node.id,
      );
    } catch (_) {}
  }

  /// Marks the selected goal complete, or reopens it when it is done.
  void _toggleDone(Node node) {
    try {
      NodeEventLink.toggleNodeDone(
        context.read<NodeCubit>(),
        context.read<CalendarCubit>(),
        node.id,
      );
    } catch (_) {
      try {
        context.read<NodeCubit>().toggleDone(node.id);
      } catch (_) {}
    }
  }

  /// "Add subgoal": the new goal is created with [parent] pre-selected as
  /// its parent. A collapsed parent is expanded on success so the new card
  /// is actually visible instead of hidden behind its own count badge.
  Future<void> _addSubgoal(Node parent) async {
    final created = await showNodeEditor(
      context,
      initialParentIds: [parent.id],
    );
    if (!mounted || created == null) return;
    setState(() {
      _collapsed.remove(parent.id);
      _revealId = created.id;
      _revealToken++;
    });
    _reportCollapsed();
  }

  /// "Add parent goal": the new goal is created as a parent of [child] in
  /// one write, so the edge exists the moment the card appears.
  Future<void> _addParent(Node child) async {
    final created = await showNodeEditor(context, initialChildIds: [child.id]);
    if (!mounted || created == null) return;
    setState(() {
      _revealId = created.id;
      _revealToken++;
    });
  }
}
