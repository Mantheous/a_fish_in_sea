import 'package:intl/intl.dart';

// Hoisted: DateFormat construction parses ICU skeletons — doing it per tile
// per frame (30+ tiles) showed up in profiles.
final calendarTimeFormat = DateFormat('h:mm a');
final calendarMoveFormat = DateFormat('EEE, MMM d · h:mm a');
final calendarDayFormat = DateFormat('EEE, MMM d');
