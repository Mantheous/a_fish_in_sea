import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      try {
        await file.delete();
      } catch (_) {}
      return const [];
    }
    final out = <TrackedPoint>[];
    for (final e in decoded) {
      try {
        if (e is Map) {
          out.add(TrackedPoint.fromJson(Map<String, dynamic>.from(e)));
        }
      } catch (_) {}
    }
    try {
      await file.delete();
    } catch (_) {}
    return out;
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

  /// Foreground GPS via geolocator works on mobile, desktop (macOS/Windows)
  /// and web. Linux has no geolocator implementation, so it stays manual-only.
  static bool get supported {
    if (kIsWeb) return true;
    try {
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows) {
        return true;
      }
    } catch (_) {
      return true;
    }
    return false;
  }

  /// Background service only exists on mobile.
  static bool get supportsBackground {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

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

  static const String trackingChannelId = 'location_tracking';

  static bool get _isAndroid {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Creates the notification channel the foreground service posts to.
  /// The background-service plugin explicitly requires the app to create a
  /// custom channel before configure(): without it startForeground throws
  /// "Bad notification" and Android kills the whole process (not catchable
  /// from Dart).
  static Future<void> ensureTrackingChannel() async {
    if (!_isAndroid) return;
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      final android =
          plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          trackingChannelId,
          'Location tracking',
          description: 'Shows while your path is being recorded',
          importance: Importance.low,
        ),
      );
    } catch (_) {}
  }

  /// Android 13+ needs POST_NOTIFICATIONS to post the foreground-service
  /// notification; without it startForeground throws and kills the app.
  /// Returns true when background recording is allowed to start.
  static Future<bool> ensureNotificationsAllowed() async {
    if (!_isAndroid) return true;
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      final android =
          plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true;
      if (await android.areNotificationsEnabled() ?? true) return true;
      return await android.requestNotificationsPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> bootstrapBackgroundService() async {
    if (!supportsBackground) return false;
    try {
      await ensureTrackingChannel();
      final service = FlutterBackgroundService();
      final configured = await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: trackingServiceEntryPoint,
          autoStart: false,
          isForegroundMode: true,
          autoStartOnBoot: false,
          notificationChannelId: trackingChannelId,
          initialNotificationTitle: 'Recording location',
          initialNotificationContent: 'Saving your path for day review',
          foregroundServiceNotificationId: 888,
          foregroundServiceTypes: const [AndroidForegroundType.location],
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
    if (!supportsBackground) return false;
    try {
      await writeTrackingConfig(intervalMinutes);
      if (_isAndroid && !await ensureNotificationsAllowed()) return false;
      await bootstrapBackgroundService();
      return await FlutterBackgroundService().startService();
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopBackground() async {
    if (!supportsBackground) return;
    try {
      FlutterBackgroundService().invoke('stopService');
    } catch (_) {}
  }
}
