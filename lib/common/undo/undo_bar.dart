import 'package:a_fish_in_sea/common/undo/undo_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class UndoRedoActions extends StatelessWidget {
  const UndoRedoActions({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UndoCubit, UndoState>(
      buildWhen: (previous, current) =>
          previous.undoStack.isNotEmpty != current.undoStack.isNotEmpty ||
          previous.redoStack.isNotEmpty != current.redoStack.isNotEmpty,
      builder: (context, state) {
        final undoCubit = context.read<UndoCubit>();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Undo',
              onPressed: undoCubit.canUndo ? undoCubit.undo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: undoCubit.canRedo ? undoCubit.redo : null,
              icon: const Icon(Icons.redo),
            ),
          ],
        );
      },
    );
  }
}
