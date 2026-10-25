import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/feed_cubit.dart';
import '../model/class_names.dart';
import '../model/feed.dart';

/// Resolver that maps a homework class key to the name to render.
///
/// Reads feeds through [FeedCubit] when it is provided (the app always
/// provides it) and falls back to identity in focused tests and previews,
/// matching how the class pickers already tolerate a missing cubit.
String Function(String key) classNameResolver(BuildContext context) {
  var feeds = const <Feed>[];
  try {
    feeds = context.watch<FeedCubit>().state;
  } catch (_) {
    // No FeedCubit here: show labels/ids unchanged.
  }
  return (key) => classNameFor(key, feeds);
}
