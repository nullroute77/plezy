import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/utils/video_player_navigation.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/pump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TV Back removes the live player and disposes even a late native initialization', (tester) async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
    final manager = MultiServerManager();
    addTearDown(manager.dispose);
    final initialize = Completer<bool>();
    final calls = <MethodCall>[];
    final navigator = GlobalKey<NavigatorState>();
    final channel = LiveTvChannel(key: 'one', title: 'One');
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) {
        calls.add(call);
        return call.method == 'initialize' ? initialize.future : Future<Object?>.value(null);
      },
      testBody: () async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
              ChangeNotifierProvider(create: (_) => OfflineModeProvider(manager)),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              home: const Scaffold(body: Text('Guide')),
            ),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            buildVideoPlayerRoute(
              builder: (_) => VideoPlayerScreen(
                metadata: testMediaItem(),
                live: LiveTvSessionArgs(channel: channel, channels: [channel], currentChannelIndex: 0),
              ),
            ),
          ),
        );
        await pumpUntil(tester, () => calls.any((call) => call.method == 'initialize'));
        expect(find.text('Guide'), findsNothing);
        await tester.binding.handlePopRoute();
        await pumpUntil(tester, () => find.byType(VideoPlayerScreen).evaluate().isEmpty);
        expect(find.text('Guide'), findsOneWidget);
        expect(navigator.currentState!.canPop(), isFalse);

        // Finishing native creation after Back must not leave a hidden player.
        initialize.complete(true);
        await pumpUntil(tester, () => calls.any((call) => call.method == 'dispose'));
        expect(find.byType(VideoPlayerScreen), findsNothing);
        expect(calls.where((call) => call.method == 'initialize'), hasLength(1));
        expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
