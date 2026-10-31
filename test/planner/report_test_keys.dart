import 'package:a_fish_in_sea/planner/service/calendar_report.dart';
import 'package:a_fish_in_sea/reporting/reporting_logic.dart';
import 'package:flutter/widgets.dart';

ValueKey<String> acceptedReportKey(String prefix, String entryId) => ValueKey(
  '$prefix:${reportAcceptedDisplayIdFor(dayKey(DateTime.now()), entryId)}',
);
