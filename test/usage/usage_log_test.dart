import 'package:a_fish_in_sea/common/usage/usage_event.dart';
import 'package:a_fish_in_sea/common/usage/usage_log.dart';
import 'package:a_fish_in_sea/demo/demo_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryUsageStore store;

  setUp(() async {
    DemoMode.isActive = false;
    await UsageLog.instance.resetForTest();
    store = MemoryUsageStore();
    await UsageLog.instance.openWithStore(store);
  });

  tearDown(() async {
    DemoMode.isActive = false;
    await UsageLog.instance.resetForTest();
  });

  test('screen dwell and actions stay content-free', () async {
    final log = UsageLog.instance;
    log.enterScreen('home');
    log.enterScreen('calendar');
    log.action('calendar.view.set', meta: {'view': 'week'});
    log.action(
      'event.editor.open',
      meta: {
        'mode': 'create',
        // A caller mistake must not smuggle user text into the log.
        'title': 'Quiz 4 study notes',
        'callback': () {},
      },
    );
    await log.settleForTest();

    final batch = await log.takeBatch();
    expect(batch.events, hasLength(3));

    final screen = batch.events[0];
    expect(screen['kind'], 'screen');
    expect(screen['name'], 'home');
    expect(screen['meta'], {'to': 'calendar'});
    expect(screen['duration_ms'], isA<int>());

    final action = batch.events[1];
    expect(action['name'], 'calendar.view.set');
    expect(action['screen'], 'calendar');
    expect(action['meta'], {'view': 'week'});

    final guarded = batch.events[2];
    expect(guarded['meta'], {'mode': 'create'});
  });

  test('usageName collapses free text instead of sanitizing it', () {
    expect(usageName('Calendar'), 'calendar');
    expect(usageName('calendar.view.set'), 'calendar.view.set');
    expect(usageName('Quiz 4 study notes'), 'invalid');
    expect(usageName('café'), 'invalid');
    expect(usageMetaValue('Quiz 4'), isNull);
    expect(usageMetaValue('week'), 'week');
    expect(usageMetaValue(42), 42);
    expect(usageMetaValue(true), true);
  });

  test('batch is oldest-first and ack removes only those keys', () async {
    final log = UsageLog.instance;
    for (var i = 0; i < 5; i++) {
      log.action('test.action', meta: {'i': i});
    }
    await log.settleForTest();

    final first = await log.takeBatch(max: 2);
    expect(first.events, hasLength(2));
    expect((first.events[0]['meta'] as Map)['i'], 0);
    await log.ack(first.keys);

    final rest = await log.takeBatch(max: 10);
    expect(rest.events, hasLength(3));
    expect((rest.events[0]['meta'] as Map)['i'], 2);
  });

  test('ring buffer never exceeds the cap', () async {
    final log = UsageLog.instance;
    for (var i = 0; i < UsageLog.maxEvents + 250; i++) {
      log.action('test.tick');
    }
    await log.settleForTest();
    final batch = await log.takeBatch(max: UsageLog.maxEvents + 1000);
    expect(batch.events.length, lessThanOrEqualTo(UsageLog.maxEvents));
    expect(batch.events.length, greaterThan(UsageLog.maxEvents - 200));
  });

  test('malformed rows are dropped instead of wedging the queue', () async {
    final log = UsageLog.instance;
    log.action('test.ok');
    await log.settleForTest();
    await store.put('e:0000000000001:bad', {'not': 'an event'});
    await store.put('e:0000000000002:bad', 'not json at all');

    final batch = await log.takeBatch();
    expect(batch.events, hasLength(1));
    expect(batch.events.single['name'], 'test.ok');
    // The malformed keys are removed as they are encountered; the valid
    // event remains until the server acks it.
    expect((await store.keys()).length, 1);
    await log.ack(batch.keys);
    expect(await store.keys(), isEmpty);
  });

  test('demo mode records nothing', () async {
    DemoMode.isActive = true;
    UsageLog.instance.action('test.demo');
    UsageLog.instance.enterScreen('calendar');
    await UsageLog.instance.settleForTest();
    expect(await store.keys(), isEmpty);
  });

  test('event reader tolerates unknown kinds and bad metadata', () {
    expect(UsageEvent.tryFromJson({'id': 'x'}), isNull);
    expect(
      UsageEvent.tryFromJson({
        'id': '12345678',
        'at': 1,
        'kind': 'wat',
        'name': 'test',
      }),
      isNull,
    );
    final event = UsageEvent.tryFromJson({
      'id': '12345678',
      'at': 1,
      'kind': 'action',
      'name': 'test.ok',
      'meta': {'ok': 1, 'bad key': 2, 'text': 'user note'},
    });
    expect(event, isNotNull);
    expect(event!.meta, {'ok': 1});
  });
}
