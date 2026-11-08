import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../sync_engine.dart';

/// Covers the Navigator too, including existing dialogs and Undo snackbars.
/// Store-level fences take effect synchronously; this also retires focus and
/// stops pointer/keyboard interaction during asynchronous account writes.
class AccountTransitionGate extends StatelessWidget {
  const AccountTransitionGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: context.read<SyncEngine>().accountTransitioning,
    child: child,
    builder: (context, busy, child) => Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: busy,
          child: AbsorbPointer(absorbing: busy, child: child),
        ),
        if (busy)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.white,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    ),
  );
}
