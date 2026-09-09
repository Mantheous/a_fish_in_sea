import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import '../model/tracked_point.dart';

const String _configFileName = 'tracking_config.json';
const String _pendingFileName = 'tracking_pending_points.json';

Future<Directory> _docsDir() => getApplicationDocumentsDirectory();

Future<File> _configFile() async => File('${(await _docsDir()).path}/$_configFileName');

Future<File> _pendingFile() async =>
    File('${(await _docsDir()).path}/$_pendingFileName');

Future<void> writeTrackingConfig(int intervalMinutes) async {
  if (kIsWeb) return;
  try {
    await (await _configFile())
        .writeAsString(jsonEncode({'intervalMinutes': intervalMinutes}));
  } catch (_) {}
}

Future<int> readTrackingInterval({int fallback = 5}) async {
  try {
    final raw = await (await _configFile()).readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return ((json['intervalMinutes'] as num?)?.toInt() ?? fallback)
        .clamp(1, 15);
  } catch (_) {
    return fallback;
  }
}

Future<void> appendPendingPoint(TrackedPoint point) async {
  try {
    final file = await _pendingFile();
    var list = <dynamic>[];
    if (await file.exists()) {
      try {
        list = jsonDecode(await file.readAsString()) as List<dynamic>;
      } catch (_) {}
    }
    list.add(point.toJson());
    await file.writeAsString(jsonEncode(list));
  } catch (_) {}
}

Future<List<TrackedPoint>> takePendingPoints() async {
  try {
    final file = await _pendingFile();
    if (!await file.exists()) return const [];
    final raw = await file.readAsString();
    await file.delete();
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => TrackedPoint.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return const [];
  }
}

Future<TrackedPoint?> samplePosition() async {
  try {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return null;
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 30),
      ),
    );
    return TrackedPoint(
      id: 'pt:${position.timestamp.millisecondsSinceEpoch}',
      timestamp: DateTime.now(),
      lat: position.latitude,
      lng: position.longitude,
      accuracy: position.accuracy,
    );
  } catch (_) {
    return null;
  }
}

Future<bool> ensureLocationPermission() async {
  if (kIsWeb) return false;
  try {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  } catch (_) {
    return false;
  }
}

@pragma('vm:entry-point')
void trackingServiceEntryPoint(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  Timer? timer;

  Future<void> tick() async {
    final point = await samplePosition();
    if (point != null) await appendPendingPoint(point);
    service.invoke('tick', {'at': DateTime.now().toIso8601String()});
  }

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) => service.setAsForegroundService());
    service.on('setAsBackground').listen((_) => service.setAsBackgroundService());
    service.setAsForegroundService();
  }
  service.on('stopService').listen((_) {
    timer?.cancel();
    service.stopSelf();
  });

  final interval = await readTrackingInterval();
  await tick();
  timer = Timer.periodic(Duration(minutes: interval), (_) => tick());
}

@pragma('vm:entry-point')
Future<bool> trackingServiceIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

class LocationService {
  LocationService._();

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Timer? _foregroundTimer;

  static void startForegroundSampling({
    required int intervalMinutes,
    required Future<void> Function() onTick,
  }) {
    stopForegroundSampling();
    onTick();
    _foregroundTimer =
        Timer.periodic(Duration(minutes: intervalMinutes), (_) => onTick());
  }

  static void stopForegroundSampling() {
    _foregroundTimer?.cancel();
    _foregroundTimer = null;
  }

  static Future<bool> bootstrapBackgroundService() async {
    if (!supported) return false;
    try {
      final service = FlutterBackgroundService();
      final configured = await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: trackingServiceEntryPoint,
          autoStart: false,
          isForegroundMode: true,
          autoStartOnBoot: false,
          notificationChannelId: 'location_tracking',
          initialNotificationTitle: 'Recording location',
          initialNotificationContent: 'Saving your path for day review',
          foregroundServiceNotificationId: 888,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: trackingServiceEntryPoint,
          onBackground: trackingServiceIosBackground,
        ),
      );
      return configured;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> startBackground(int intervalMinutes) async {
    if (!supported) return false;
    try {
      await writeTrackingConfig(intervalMinutes);
      await bootstrapBackgroundService();
      return await FlutterBackgroundService().startService();
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopBackground() async {
    if (!supported) return;
    try {
      FlutterBackgroundService().invoke('stopService');
    } catch (_) {}
  }
}
