import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:clock/clock.dart';
import 'package:flutter/rendering.dart';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/focus/dpad_navigator.dart';
import 'package:plezy/focus/dpad_select_long_press_controller.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/widgets/status_pill.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/utils/formatters.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';

Future<void> _captureGuide(WidgetTester tester, String name) async {
  const screenshotDir = String.fromEnvironment('GUIDE_SCREENSHOT_DIR');
  if (screenshotDir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('guide-capture')));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(screenshotDir).createSync(recursive: true);
      File('$screenshotDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

const _selectDown = KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.enter,
  logicalKey: LogicalKeyboardKey.enter,
  timeStamp: Duration.zero,
);

LiveTvChannel _channel({String key = 'channel/7'}) =>
    LiveTvChannel(key: key, identifier: 'station-7', callSign: 'SEVEN', serverId: 'server-a', liveDvrKey: 'dvr-a');

LiveTvProgram _program({String ratingKey = 'program/42', int beginsAt = 1_800_000_000, int endsAt = 1_800_003_600}) =>
    LiveTvProgram(
      ratingKey: ratingKey,
      title: 'Evening News',
      beginsAt: beginsAt,
      endsAt: endsAt,
      channelIdentifier: 'station-7',
      serverId: 'server-a',
      liveDvrKey: 'dvr-a',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('en');
    if (const String.fromEnvironment('GUIDE_SCREENSHOT_DIR').isNotEmpty) {
      const previewFontPath = String.fromEnvironment('GUIDE_PREVIEW_FONT_PATH');
      final font = previewFontPath.isEmpty
          ? rootBundle.load('assets/go-noto-current-regular.ttf')
          : Future.value(ByteData.sublistView(File(previewFontPath).readAsBytesSync()));
      await (FontLoader('GuidePreview')..addFont(font)).load();
      await (FontLoader(
        'packages/material_symbols_icons/MaterialSymbolsRounded',
      )..addFont(rootBundle.load('packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf'))).load();
    }
  });
  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugSetAppleTVOverride(false);
  });
  tearDown(() {
    SelectKeyUpSuppressor.clearSuppression();
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  test('half-hour floor covers boundaries, fractions, midnight, month/year changes', () {
    for (final time in [
      DateTime(2026, 9, 10, 20),
      DateTime(2026, 9, 10, 20, 29, 59, 999, 999),
      DateTime(2026, 9, 10, 20, 30),
      DateTime(2026, 9, 10, 20, 51),
      DateTime(2026, 12, 31, 23, 59),
      DateTime(2027, 1, 1, 0, 1),
      DateTime(2026, 10, 1, 0, 29),
    ]) {
      expect(guideHalfHourStart(time), DateTime(time.year, time.month, time.day, time.hour, time.minute ~/ 30 * 30));
    }
  });

  test('half-hour floor preserves both occurrences of a repeated DST hour', () {
    // Run with TZ=America/Chicago as well as the ordinary suite. Epochs remove
    // the ambiguity of constructing the repeated 01:xx wall-clock hour.
    for (final utc in [
      DateTime.utc(2026, 11, 1, 6, 51),
      DateTime.utc(2026, 11, 1, 7, 51),
      DateTime.utc(2026, 3, 8, 7, 59),
      DateTime.utc(2026, 3, 8, 8, 1),
    ]) {
      final time = utc.toLocal();
      final floor = guideHalfHourStart(time);
      expect(floor.timeZoneOffset, time.timeZoneOffset);
      expect(floor.minute, time.minute ~/ 30 * 30);
      expect(floor.hour, time.hour);
      expect(time.difference(floor), Duration(minutes: time.minute % 30));
      expect(floor.isUtc, isFalse);
    }
  });

  for (final is24Hour in [false, true]) {
    testWidgets('entry and Now start at local half hour (${is24Hour ? 24 : 12}-hour labels)', (tester) async {
      var now = DateTime(2026, 9, 10, 20, 51);
      await withClock(Clock(() => now), () async {
        final harness = _GuideHarness.oneServer();
        addTearDown(harness.dispose);
        await harness.pump(tester, size: const Size(480, 400), is24Hour: is24Hour);
        await harness.completeInitial(tester);
        expect(harness.serverA.schedule.requests.first.from, DateTime(2026, 9, 10, 20, 30).toUtc());
        final label = find.text(formatClockTime(DateTime(2026, 9, 10, 20, 30), is24Hour: is24Hour)).last;
        expect(label, findsOneWidget);
        expect(tester.getTopLeft(label).dx, closeTo(140, 1));
        await tester.tap(_leftTimeButton());
        harness.serverA.schedule.complete(1, 'History');
        await tester.pumpAndSettle();
        now = DateTime(2026, 9, 11, 0, 29, 59);
        // Open the day picker by mouse and explicitly choose Now.
        await tester.tap(find.text(t.liveTv.today));
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.liveTv.now));
        harness.serverA.schedule.complete(2, 'Back to now');
        await tester.pumpAndSettle();
        expect(harness.serverA.schedule.requests.last.from, DateTime(2026, 9, 11).toUtc());
        expect(
          tester.getTopLeft(find.text(formatClockTime(DateTime(2026, 9, 11), is24Hour: is24Hour)).last).dx,
          closeTo(140, 1),
        );
      });
    });
  }

  testWidgets('backward schedule remains browsable across refresh after live window expires', (tester) async {
    var now = DateTime(2026, 9, 10, 20, 51);
    await withClock(Clock(() => now), () async {
      final harness = _GuideHarness.oneServer();
      addTearDown(harness.dispose);
      await harness.pump(tester);
      await harness.completeInitial(tester);
      await tester.tap(_leftTimeButton());
      final history = harness.serverA.schedule.requests.last;
      expect(history.from, DateTime(2026, 9, 10, 18, 30).toUtc());
      harness.serverA.schedule.complete(1, 'Earlier program');
      await tester.pumpAndSettle();
      // This manual window includes Now initially; it still must not follow it.
      now = now.add(const Duration(hours: 8));
      tester.state<GuideTabState>(find.byType(GuideTab)).onRefreshTick();
      await tester.pump();
      expect(harness.serverA.schedule.requests, hasLength(2));
      expect(find.text('Earlier program'), findsOneWidget);
      await tester.tap(_rightTimeButton());
      expect(harness.serverA.schedule.requests.last.from, history.from.add(const Duration(hours: 2)));
      harness.serverA.schedule.complete(2, 'Forward again');
      await tester.pumpAndSettle();
    });
  });

  for (final appearance in [
    (name: 'light', dark: false, oled: false),
    (name: 'dark', dark: true, oled: false),
    (name: 'oled', dark: true, oled: true),
  ]) {
    for (final tv in [false, true]) {
      testWidgets(
        '${appearance.name} guide badges and subtext fit short cards with pointer and ${tv ? 'TV remote' : 'keyboard'} focus',
        (tester) async {
          TvDetectionService.debugSetAppleTVOverride(tv);
          final harness = _GuideHarness.oneServer();
          addTearDown(harness.dispose);
          await harness.pump(tester, dark: appearance.dark, oled: appearance.oled);
          final request = harness.serverA.schedule.requests.single;
          final start = request.from.millisecondsSinceEpoch ~/ 1000;
          request.completer.complete([
            LiveTvProgram(
              title: 'Live sports',
              episodeTitle: 'Final 2026',
              live: true,
              isNew: true,
              beginsAt: start,
              endsAt: start + 1800,
              channelIdentifier: 'station-a',
              serverId: 'server-a',
            ),
            LiveTvProgram(
              title: 'New series',
              episodeTitle: 'The 100',
              isNew: true,
              beginsAt: start + 1800,
              endsAt: start + 3600,
              channelIdentifier: 'station-a',
              serverId: 'server-a',
            ),
            LiveTvProgram(
              title: 'Tiny recording',
              episodeTitle: 'Episode 2000',
              live: true,
              subscriptionId: 'recording',
              beginsAt: start + 3600,
              endsAt: start + 3660,
              channelIdentifier: 'station-a',
              serverId: 'server-a',
            ),
            LiveTvProgram(
              title: 'Narrow series',
              episodeTitle: 'Episode 9 from Outer Space',
              premiere: true,
              subscriptionId: 'recording',
              beginsAt: start + 3660,
              endsAt: start + 4560,
              channelIdentifier: 'station-a',
              serverId: 'server-a',
            ),
            LiveTvProgram(
              title: 'Missing metadata',
              beginsAt: start + 4560,
              endsAt: start + 6360,
              channelIdentifier: 'station-a',
              serverId: 'server-a',
            ),
            LiveTvProgram(
              title: 'Upcoming episode',
              episodeTitle: 'A New Chapter',
              isNew: true,
              beginsAt: start + 6360,
              endsAt: start + 8160,
              channelIdentifier: 'station-a',
              serverId: 'server-a',
            ),
          ]);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text(t.liveTv.live), findsOneWidget);
          final newCard = find.ancestor(of: find.text('New series'), matching: find.byType(InkWell)).first;
          expect(find.descendant(of: newCard, matching: find.text(t.liveTv.newProgram)), findsOneWidget);
          final unfocusedPill = tester.widget<StatusPill>(
            find.descendant(of: newCard, matching: find.byType(StatusPill)),
          );
          final unfocusedFill = tester
              .widget<Material>(find.ancestor(of: newCard, matching: find.byType(Material)).first)
              .color!;
          expect(
            unfocusedPill.color,
            Color.alphaBlend(unfocusedPill.foregroundColor.withValues(alpha: 0.2), unfocusedFill),
          );
          expect(
            unfocusedPill.foregroundColor.computeLuminance() > unfocusedPill.color.computeLuminance(),
            appearance.dark,
          );
          final tinyCard = find.ancestor(of: find.text('Tiny recording'), matching: find.byType(InkWell)).first;
          expect(find.descendant(of: tinyCard, matching: find.text(t.liveTv.live)), findsNothing);
          expect(find.text('Episode 2000'), findsNothing);
          expect(find.text('Final 2026'), findsOneWidget);
          expect(find.text('The 100'), findsOneWidget);
          final card = find.ancestor(of: find.text('Live sports'), matching: find.byType(InkWell)).first;
          expect(find.descendant(of: card, matching: find.byType(Text)), findsNWidgets(3));
          expect(tester.getSize(card).width, closeTo(236, 4));
          final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
          await mouse.addPointer(location: tester.getCenter(card));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await mouse.removePointer();
          await _focusGrid(tester);
          for (var i = 0; i < 5; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          for (var i = 0; i < 3; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
            await tester.pumpAndSettle();
          }
          expect(find.ancestor(of: find.text('New series'), matching: _focusedCellFinder(tester)), findsOneWidget);
          final focusedBadge = tester.widget<Text>(
            find.descendant(of: newCard, matching: find.text(t.liveTv.newProgram)),
          );
          final theme = Theme.of(tester.element(newCard));
          expect(focusedBadge.style?.color, theme.colorScheme.onPrimary);
          final newPill = tester.widget<StatusPill>(find.descendant(of: newCard, matching: find.byType(StatusPill)));
          expect(
            newPill.color,
            Color.alphaBlend(theme.colorScheme.onPrimary.withValues(alpha: 0.2), theme.colorScheme.primary),
          );
          expect(newPill.color, isNot(unfocusedPill.color));
          expect(newPill.foregroundColor.computeLuminance() > newPill.color.computeLuminance(), !appearance.dark);
          for (final neutral in [unfocusedPill, newPill]) {
            final luminances = [neutral.foregroundColor.computeLuminance(), neutral.color.computeLuminance()]..sort();
            expect((luminances.last + 0.05) / (luminances.first + 0.05), greaterThanOrEqualTo(4.5));
          }
          final livePill = tester.widget<StatusPill>(find.descendant(of: card, matching: find.byType(StatusPill)));
          expect(livePill.color, Colors.red);
          expect(livePill.foregroundColor, Colors.white);
          for (final pill in [newPill, livePill]) {
            final decoration =
                tester
                        .widget<Container>(find.descendant(of: find.byWidget(pill), matching: find.byType(Container)))
                        .decoration!
                    as BoxDecoration;
            expect(decoration.color, pill.color);
            expect(decoration.border, isNull);
            expect(decoration.borderRadius, BorderRadius.circular(3));
          }
          // Capture actual Flutter rendering when explicitly requested; no golden
          // baseline tied to the machine's wall clock or font rasterizer.
          await _captureGuide(tester, 'guide-${appearance.name}-${tv ? 'remote' : 'keyboard'}');
          // The very narrow card and its recording indicator also survive scaling.
          tester.platformDispatcher.textScaleFactorTestValue = 1.5;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final device in [
    (name: 'Android phone', platform: TargetPlatform.android, tv: false, column: 96.0),
    (name: 'iPhone', platform: TargetPlatform.iOS, tv: false, column: 96.0),
    (name: 'Windows', platform: TargetPlatform.windows, tv: false, column: 132.0),
    (name: 'Android TV', platform: TargetPlatform.android, tv: true, column: 132.0),
  ]) {
    testWidgets('${device.name} aligns the channel column and Now line at 240 pixels per half hour', (tester) async {
      TvDetectionService.debugSetAppleTVOverride(device.tv);
      final now = DateTime(2026, 9, 10, 20, 15);
      await withClock(Clock.fixed(now), () async {
        final harness = _GuideHarness.oneServer();
        addTearDown(harness.dispose);
        await harness.pump(tester, platform: device.platform, size: const Size(430, 720));
        final request = harness.serverA.schedule.requests.single;
        final start = request.from.millisecondsSinceEpoch ~/ 1000;
        request.completer.complete([
          LiveTvProgram(
            title: 'First program',
            beginsAt: start,
            endsAt: start + 1800,
            channelIdentifier: 'station-a',
            serverId: 'server-a',
          ),
          LiveTvProgram(
            title: 'Second program',
            beginsAt: start + 1800,
            endsAt: start + 3600,
            channelIdentifier: 'station-a',
            serverId: 'server-a',
          ),
        ]);
        await tester.pumpAndSettle();
        final first = find.ancestor(of: find.text('First program'), matching: find.byType(InkWell)).first;
        final second = find.ancestor(of: find.text('Second program'), matching: find.byType(InkWell)).first;
        expect(tester.getTopLeft(first).dx, device.column);
        expect(tester.getTopLeft(second).dx - tester.getTopLeft(first).dx, 240);
        final label = find.text(formatClockTime(now.subtract(const Duration(minutes: 15)), is24Hour: false)).last;
        expect(tester.getTopLeft(label).dx, device.column + 8);
        final nowLine = find.byWidgetPredicate(
          (widget) => widget is Container && widget.color == Colors.red && widget.constraints?.maxWidth == 2,
        );
        expect(nowLine, findsOneWidget);
        expect(tester.getTopLeft(nowLine).dx, device.column + 120);
        await _captureGuide(tester, 'guide-${device.name.toLowerCase().replaceAll(' ', '-')}');
        // The timeline and header remain synchronized after a horizontal drag.
        await tester.drag(first, const Offset(-100, 0));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(label).dx - tester.getTopLeft(first).dx, closeTo(8, 0.01));
        expect(tester.getTopLeft(nowLine).dx - tester.getTopLeft(first).dx, closeTo(120, 0.01));
        expect(tester.takeException(), isNull);
      });
    });
  }

  test('SELECT hold survives equivalent fresh guide objects and opens details once', () {
    fakeAsync((async) {
      final controller = DpadSelectLongPressController();
      var focusedChannel = _channel();
      var focusedProgram = _program();
      final pressedIdentity = guideAiringIdentity(focusedChannel, focusedProgram);
      var detailsOpened = 0;

      controller.handleKeyEvent(
        _selectDown,
        isOwnerActive: () => guideAiringIdentity(focusedChannel, focusedProgram) == pressedIdentity,
        onShortPress: () {},
        onLongPress: () {
          controller.reset();
          detailsOpened++;
        },
      );

      async.elapse(const Duration(milliseconds: 250));
      final replacementChannel = _channel();
      final replacementProgram = _program();
      expect(identical(replacementChannel, focusedChannel), isFalse);
      expect(identical(replacementProgram, focusedProgram), isFalse);
      focusedChannel = replacementChannel;
      focusedProgram = replacementProgram;

      async.elapse(const Duration(milliseconds: 249));
      expect(detailsOpened, 0);
      async.elapse(const Duration(milliseconds: 1));
      expect(detailsOpened, 1);

      async.elapse(const Duration(seconds: 1));
      expect(detailsOpened, 1);
      controller.dispose();
    });
  });

  test('SELECT hold does not open details after focus moves to a different airing', () {
    fakeAsync((async) {
      final controller = DpadSelectLongPressController();
      final focusedChannel = _channel();
      var focusedProgram = _program();
      final pressedIdentity = guideAiringIdentity(focusedChannel, focusedProgram);
      var detailsOpened = 0;

      controller.handleKeyEvent(
        _selectDown,
        isOwnerActive: () => guideAiringIdentity(focusedChannel, focusedProgram) == pressedIdentity,
        onShortPress: () {},
        onLongPress: () => detailsOpened++,
      );

      async.elapse(const Duration(milliseconds: 250));
      focusedProgram = _program(beginsAt: 1_800_003_600, endsAt: 1_800_007_200);
      expect(guideAiringIdentity(focusedChannel, focusedProgram), isNot(pressedIdentity));

      async.elapse(const Duration(milliseconds: 250));
      expect(detailsOpened, 0);
      async.elapse(const Duration(seconds: 1));
      expect(detailsOpened, 0);
      controller.dispose();
    });
  });

  testWidgets('superseded guide load keeps one interval and cannot replace current programs', (tester) async {
    final harness = _GuideHarness.twoServers();
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.completeInitial(tester);

    final rightButton = _rightTimeButton();
    expect(rightButton, findsOneWidget);
    await tester.tap(rightButton);
    await tester.tap(rightButton);

    expect(harness.serverA.schedule.requests, hasLength(3));
    final older = harness.serverA.schedule.requests[1];
    final newer = harness.serverA.schedule.requests[2];
    expect(older.to.difference(older.from), const Duration(hours: 6));
    expect(newer.to.difference(newer.from), const Duration(hours: 6));
    expect(newer.from.difference(older.from), const Duration(hours: 2));

    harness.serverA.schedule.complete(2, 'Current A');
    await tester.pump();
    expect(harness.serverB!.schedule.requests, hasLength(2));
    final currentB = harness.serverB!.schedule.requests[1];
    expect(currentB.from, newer.from);
    expect(currentB.to, newer.to);

    harness.serverB!.schedule.complete(1, 'Current B');
    await tester.pumpAndSettle();
    expect(find.text('Current A'), findsOneWidget);
    expect(find.text('Current B'), findsOneWidget);

    harness.serverA.schedule.complete(1, 'Obsolete A');
    await tester.pump();
    await tester.pump();
    expect(harness.serverB!.schedule.requests, hasLength(2));
    expect(find.text('Obsolete A'), findsNothing);
    expect(find.text('Current A'), findsOneWidget);
    expect(find.text('Current B'), findsOneWidget);
  });

  testWidgets('obsolete completion cannot clear loading owned by a newer guide request', (tester) async {
    final harness = _GuideHarness.oneServer();
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.completeInitial(tester);

    final rightButton = _rightTimeButton();
    await tester.tap(rightButton);
    await tester.tap(rightButton);
    expect(harness.serverA.schedule.requests, hasLength(3));

    harness.serverA.schedule.complete(1, 'Obsolete');
    await tester.pump();
    await tester.pump();
    // In-session reloads keep the guide mounted: the indicator is the
    // lightweight overlay rather than a full-screen spinner, and the guide
    // Focus + day chip stay in the tree so D-pad navigation survives.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is Focus && widget.focusNode?.debugLabel == 'guide_tab'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((widget) => widget is AppIcon && widget.icon == Symbols.arrow_drop_down_rounded),
      findsOneWidget,
    );
    expect(find.text('Obsolete'), findsNothing);
  });

  testWidgets('picking a day applies it immediately and slot-menu dismissal keeps it', (tester) async {
    final harness = _GuideHarness.oneServer();
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.completeInitial(tester);

    _guideTabFocusNode(tester).requestFocus();
    await tester.pump();

    await _openDayPicker(tester);
    // The day menu labels tomorrow via the translation.
    expect(find.text(t.liveTv.tomorrow), findsOneWidget);
    await _selectTomorrowInDayMenu(tester);

    // The picked day is applied right away: a fetch for it already went out,
    // keeping the current window's time-of-day.
    final requests = harness.serverA.schedule.requests;
    expect(requests, hasLength(2));
    final first = requests[0];
    final dayRequest = requests[1];
    final gridStartLocal = first.from.toLocal();
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final expectedFrom = DateTime(
      tomorrow.year,
      tomorrow.month,
      tomorrow.day,
      gridStartLocal.hour,
      gridStartLocal.minute,
    ).toUtc();
    expect(dayRequest.from, expectedFrom);
    expect(dayRequest.to, expectedFrom.add(const Duration(hours: 6)));

    // Dismissing the refinement menu keeps the already-applied day, and the
    // day chip renders the picked day via the translation too.
    await tester.tapAt(const Offset(1270, 700));
    await _pumpMenuTransition(tester);
    expect(harness.serverA.schedule.requests, hasLength(2));
    expect(find.text(t.liveTv.tomorrow), findsOneWidget);
  });

  testWidgets('picking a slot after the day refines the window to that slot', (tester) async {
    final harness = _GuideHarness.oneServer();
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.completeInitial(tester);

    _guideTabFocusNode(tester).requestFocus();
    await tester.pump();
    await _openDayPicker(tester);
    await _selectTomorrowInDayMenu(tester);
    expect(harness.serverA.schedule.requests, hasLength(2));

    await tester.tap(find.text(t.liveTv.morning));
    await _pumpMenuTransition(tester);

    final requests = harness.serverA.schedule.requests;
    expect(requests, hasLength(3));
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final expectedFrom = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 6).toUtc();
    expect(requests[2].from, expectedFrom);
    expect(requests[2].to, expectedFrom.add(const Duration(hours: 6)));
  });

  testWidgets('after a day change completes the guide keeps D-pad focus', (tester) async {
    final harness = _GuideHarness.oneServer();
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.completeInitial(tester);

    _guideTabFocusNode(tester).requestFocus();
    await tester.pump();
    await _openDayPicker(tester);
    await _selectTomorrowInDayMenu(tester);

    // Dismiss the refinement menu without picking: focus returns to the guide.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpMenuTransition(tester);
    expect(_guideTabFocusNode(tester).hasFocus, isTrue);

    // Completing the day fetch must not drop focus (the remote stays alive).
    harness.serverA.schedule.complete(1, 'Tomorrow Programs');
    await tester.pumpAndSettle();
    expect(_guideTabFocusNode(tester).hasFocus, isTrue);
    expect(find.text('Tomorrow Programs'), findsOneWidget);
  });

  testWidgets('horizontal guide virtualization keeps the D-pad focus target rendered', (tester) async {
    final harness = _GuideHarness.oneServer();
    addTearDown(harness.dispose);
    await harness.pump(tester);

    harness.serverA.schedule.completeSlots(0, 12);
    await tester.pumpAndSettle();
    expect(find.text('Slot 12'), findsNothing);

    final guideFocus = tester.widget<Focus>(
      find.byWidgetPredicate((widget) => widget is Focus && widget.focusNode?.debugLabel == 'guide_tab'),
    );
    guideFocus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }

    final primary = Theme.of(tester.element(find.byType(GuideTab))).colorScheme.primary;
    final focusedMaterial = find.byWidgetPredicate((widget) => widget is Material && widget.color == primary);
    expect(find.text('Slot 1'), findsNothing);
    expect(find.text('Slot 12'), findsOneWidget);
    expect(find.ancestor(of: find.text('Slot 12'), matching: focusedMaterial), findsOneWidget);
  });

  testWidgets('vertical navigation follows displayed source-group order, not flat channel order', (tester) async {
    // Flat list mirrors live_tv_screen ordering: number-sorted across servers,
    // which interleaves the two source groups when numbers overlap.
    final harness = _GuideHarness.twoServersWithChannels([
      _guideChannel(serverId: 'server-a', stationId: 'st-a1', callSign: 'A1', number: '1'),
      _guideChannel(serverId: 'server-a', stationId: 'st-a2', callSign: 'A2', number: '2'),
      _guideChannel(serverId: 'server-b', stationId: 'st-b21', callSign: 'B21', number: '2.1'),
      _guideChannel(serverId: 'server-a', stationId: 'st-a3', callSign: 'A3', number: '3'),
      _guideChannel(serverId: 'server-a', stationId: 'st-a4', callSign: 'A4', number: '4'),
      _guideChannel(serverId: 'server-b', stationId: 'st-b41', callSign: 'B41', number: '4.1'),
      _guideChannel(serverId: 'server-b', stationId: 'st-b43', callSign: 'B43', number: '4.3'),
      _guideChannel(serverId: 'server-b', stationId: 'st-b44', callSign: 'B44', number: '4.4'),
      _guideChannel(serverId: 'server-a', stationId: 'st-a5', callSign: 'A5', number: '5'),
      _guideChannel(serverId: 'server-b', stationId: 'st-b51', callSign: 'B51', number: '5.1'),
    ]);
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.completeInitialEmpty(tester);

    await _focusGrid(tester);
    _expectFocusedChannel(tester, 'A1');

    const displayOrder = ['A1', 'A2', 'A3', 'A4', 'A5', 'B21', 'B41', 'B43', 'B44', 'B51'];
    for (final callSign in displayOrder.skip(1)) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      _expectFocusedChannel(tester, callSign);
    }

    // Down on the last displayed row is a no-op.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    _expectFocusedChannel(tester, 'B51');

    for (final callSign in displayOrder.reversed.skip(1)) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      _expectFocusedChannel(tester, callSign);
    }
  });

  testWidgets('down reaches the last displayed row when the flat-last channel sits mid-guide', (tester) async {
    // Flat order: 1 (A), 2 (B), 10 (A). Displayed order groups by source:
    // A1, A10, then B2 — the flat-last channel is not the displayed-last row.
    final harness = _GuideHarness.twoServersWithChannels([
      _guideChannel(serverId: 'server-a', stationId: 'st-a1', callSign: 'A1', number: '1'),
      _guideChannel(serverId: 'server-b', stationId: 'st-b2', callSign: 'B2', number: '2'),
      _guideChannel(serverId: 'server-a', stationId: 'st-a10', callSign: 'A10', number: '10'),
    ]);
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.completeInitialEmpty(tester);

    await _focusGrid(tester);
    _expectFocusedChannel(tester, 'A1');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    _expectFocusedChannel(tester, 'A10');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    _expectFocusedChannel(tester, 'B2');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    _expectFocusedChannel(tester, 'B2');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    _expectFocusedChannel(tester, 'A10');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    _expectFocusedChannel(tester, 'A1');

    // Up on the first displayed row exits the grid to the time navigation.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_focusedCellFinder(tester), findsNothing);
  });

  testWidgets('guide-search jump during load is stashed, wins over default anchoring, and lands focus', (tester) async {
    final harness = _GuideHarness.twoServers();
    addTearDown(harness.dispose);
    await harness.pump(tester);

    // Keyboard mode while the initial load is still in flight; the jump is
    // stashed and replayed once the load commits.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    tester.state<GuideTabState>(find.byType(GuideTab)).jumpToChannel(harness.channels[1]);

    await harness.completeInitialEmpty(tester);

    _expectFocusedChannel(tester, 'B');
  });

  testWidgets('jumpToProgram shifts the guide window to the airing and lands focus on its block', (tester) async {
    final harness = _GuideHarness.oneServer();
    addTearDown(harness.dispose);
    await harness.pump(tester);
    await harness.completeInitial(tester);

    await _focusGrid(tester);
    _expectFocusedChannel(tester, 'A');

    // An airing 8 hours past the window start, outside the visible 6 hours.
    final initial = harness.serverA.schedule.requests[0];
    final beginEpoch = initial.from.millisecondsSinceEpoch ~/ 1000 + 8 * 3600;
    final target = LiveTvProgram(
      ratingKey: 'search-target',
      title: 'Search Target',
      beginsAt: beginEpoch,
      endsAt: beginEpoch + 1800,
      channelIdentifier: 'station-a',
      serverId: 'server-a',
    );

    final state = tester.state<GuideTabState>(find.byType(GuideTab));
    unawaited(state.jumpToProgram(harness.channels.single, target));
    await tester.pump();

    // A fresh 6-hour window anchored one slot before the airing was requested.
    expect(harness.serverA.schedule.requests, hasLength(2));
    final shifted = harness.serverA.schedule.requests[1];
    final expectedFrom = DateTime.fromMillisecondsSinceEpoch((beginEpoch - 1800) * 1000, isUtc: true);
    expect(shifted.from, expectedFrom);
    expect(shifted.to, expectedFrom.add(const Duration(hours: 6)));

    // Slot 2 of the completed window begins exactly at the airing's start, so
    // the jump re-resolves onto it and lands D-pad focus on the block.
    harness.serverA.schedule.completeSlots(1, 2);
    await tester.pumpAndSettle();
    expect(find.ancestor(of: find.text('Slot 2'), matching: _focusedCellFinder(tester)), findsOneWidget);
  });
}

Finder _leftTimeButton() => find
    .ancestor(
      of: find.byWidgetPredicate((widget) => widget is AppIcon && widget.icon == Symbols.chevron_left_rounded),
      matching: find.byType(IconButton),
    )
    .first;

Finder _rightTimeButton() {
  final icon = find.byWidgetPredicate((widget) => widget is AppIcon && widget.icon == Symbols.chevron_right_rounded);
  return find.ancestor(of: icon, matching: find.byType(IconButton));
}

Future<void> _focusGrid(WidgetTester tester) async {
  final guideFocus = tester.widget<Focus>(
    find.byWidgetPredicate((widget) => widget is Focus && widget.focusNode?.debugLabel == 'guide_tab'),
  );
  guideFocus.focusNode!.requestFocus();
  await tester.pump();
  // Enters the grid from the time navigation zone.
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
  await tester.pumpAndSettle();
}

Finder _focusedCellFinder(WidgetTester tester) {
  final primary = Theme.of(tester.element(find.byType(GuideTab))).colorScheme.primary;
  return find.byWidgetPredicate((widget) => widget is Material && widget.color == primary);
}

void _expectFocusedChannel(WidgetTester tester, String callSign) {
  expect(
    find.ancestor(of: find.text(callSign), matching: _focusedCellFinder(tester)),
    findsOneWidget,
    reason: 'expected focused channel $callSign',
  );
}

FocusNode _guideTabFocusNode(WidgetTester tester) {
  final guideFocus = tester.widget<Focus>(
    find.byWidgetPredicate((widget) => widget is Focus && widget.focusNode?.debugLabel == 'guide_tab'),
  );
  return guideFocus.focusNode!;
}

/// Opens the day picker menu via SELECT on the focused time-nav day chip.
Future<void> _openDayPicker(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

/// Selects 'Tomorrow' in the open day menu by tapping its entry; the slot
/// refinement menu opens on top. The keyboard open/close paths are covered by
/// the focus test; menu entry taps keep this selection deterministic.
Future<void> _selectTomorrowInDayMenu(WidgetTester tester) async {
  await tester.tap(find.text(t.liveTv.tomorrow));
  await _pumpMenuTransition(tester);
}

/// Pumps through a menu open/close transition (120ms). Cannot pumpAndSettle:
/// while a guide load is in flight the overlay's indeterminate spinner keeps
/// scheduling frames forever.
Future<void> _pumpMenuTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

final class _GuideHarness {
  _GuideHarness._({required this.serverA, required this.serverB, required this.provider, required this.channels});

  factory _GuideHarness.oneServer() => _GuideHarness._create(includeServerB: false);

  factory _GuideHarness.twoServers() => _GuideHarness._create(includeServerB: true);

  factory _GuideHarness.twoServersWithChannels(List<LiveTvChannel> channels) =>
      _GuideHarness._create(includeServerB: true, channels: channels);

  factory _GuideHarness._create({required bool includeServerB, List<LiveTvChannel>? channels}) {
    final serverA = _FakeMediaServerClient(serverId: 'server-a', stationId: 'station-a');
    final serverB = includeServerB ? _FakeMediaServerClient(serverId: 'server-b', stationId: 'station-b') : null;
    final manager = MultiServerManager()..debugRegisterClientForTesting(serverA);
    if (serverB != null) manager.debugRegisterClientForTesting(serverB);
    final provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([
        LiveTvServerInfo(serverId: 'server-a', dvrKey: 'dvr-a'),
        if (serverB != null) LiveTvServerInfo(serverId: 'server-b', dvrKey: 'dvr-b'),
      ]);
    return _GuideHarness._(
      serverA: serverA,
      serverB: serverB,
      provider: provider,
      channels:
          channels ??
          [
            _guideChannel(serverId: 'server-a', stationId: 'station-a', callSign: 'A'),
            if (serverB != null) _guideChannel(serverId: 'server-b', stationId: 'station-b', callSign: 'B'),
          ],
    );
  }

  final _FakeMediaServerClient serverA;
  final _FakeMediaServerClient? serverB;
  final MultiServerProvider provider;
  final List<LiveTvChannel> channels;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    bool is24Hour = false,
    bool dark = true,
    bool oled = false,
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(
              theme: const String.fromEnvironment('GUIDE_SCREENSHOT_DIR').isEmpty
                  ? monoTheme(dark: dark, oled: oled).copyWith(platform: platform)
                  : monoTheme(dark: dark, oled: oled).copyWith(
                      platform: platform,
                      textTheme: monoTheme(dark: dark, oled: oled).textTheme.apply(fontFamily: 'GuidePreview'),
                    ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: is24Hour),
                child: child!,
              ),
              home: RepaintBoundary(
                key: const ValueKey('guide-capture'),
                child: Scaffold(body: GuideTab(channels: channels)),
              ),
            ),
          ),
        ),
      ),
    );
    expect(serverA.schedule.requests, hasLength(1));
  }

  Future<void> completeInitial(WidgetTester tester) async {
    serverA.schedule.complete(0, 'Initial A');
    await tester.pump();
    final serverB = this.serverB;
    if (serverB != null) {
      expect(serverB.schedule.requests, hasLength(1));
      serverB.schedule.complete(0, 'Initial B');
    }
    await tester.pumpAndSettle();
    expect(find.text('Initial A'), findsOneWidget);
    if (serverB != null) expect(find.text('Initial B'), findsOneWidget);
  }

  Future<void> completeInitialEmpty(WidgetTester tester) async {
    serverA.schedule.completeEmpty(0);
    await tester.pump();
    final serverB = this.serverB;
    if (serverB != null) {
      expect(serverB.schedule.requests, hasLength(1));
      serverB.schedule.completeEmpty(0);
    }
    await tester.pumpAndSettle();
  }

  void dispose() => provider.dispose();
}

LiveTvChannel _guideChannel({
  required String serverId,
  required String stationId,
  required String callSign,
  String? number,
}) => LiveTvChannel(
  key: 'channel-$stationId',
  identifier: stationId,
  callSign: callSign,
  serverId: serverId,
  liveDvrKey: 'dvr-$serverId',
  number: number,
);

final class _FakeMediaServerClient implements MediaServerClient {
  _FakeMediaServerClient({required String serverId, required String stationId})
    : serverId = ServerId(serverId),
      schedule = _ControllableLiveTvSupport(serverId: serverId, stationId: stationId);

  @override
  final ServerId serverId;
  final _ControllableLiveTvSupport schedule;

  @override
  LiveTvSupport get liveTv => schedule;

  @override
  String get serverName => serverId.value;

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(liveTv: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ControllableLiveTvSupport implements LiveTvSupport {
  _ControllableLiveTvSupport({required this.serverId, required this.stationId});

  final String serverId;
  final String stationId;
  final List<_ScheduleRequest> requests = [];

  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) {
    final request = _ScheduleRequest(from: from!, to: to!);
    requests.add(request);
    return request.completer.future;
  }

  void complete(int index, String title) {
    final request = requests[index];
    final beginsAt = request.from.millisecondsSinceEpoch ~/ 1000 + 600;
    request.completer.complete([
      LiveTvProgram(
        ratingKey: '$serverId-$index',
        title: title,
        beginsAt: beginsAt,
        endsAt: beginsAt + 3600,
        channelIdentifier: stationId,
        serverId: serverId,
      ),
    ]);
  }

  void completeEmpty(int index) => requests[index].completer.complete(const []);

  void completeSlots(int index, int count) {
    final request = requests[index];
    final startEpoch = request.from.millisecondsSinceEpoch ~/ 1000;
    request.completer.complete([
      for (var slot = 0; slot < count; slot++)
        LiveTvProgram(
          ratingKey: '$serverId-$index-$slot',
          title: 'Slot ${slot + 1}',
          beginsAt: startEpoch + slot * 30 * 60,
          endsAt: startEpoch + (slot + 1) * 30 * 60,
          channelIdentifier: stationId,
          serverId: serverId,
        ),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ScheduleRequest {
  _ScheduleRequest({required this.from, required this.to});

  final DateTime from;
  final DateTime to;
  final Completer<List<LiveTvProgram>> completer = Completer<List<LiveTvProgram>>();
}
