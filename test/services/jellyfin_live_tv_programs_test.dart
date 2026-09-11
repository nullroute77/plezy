import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/models/livetv_program.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

void main() {
  for (final dialect in MediaBrowserDialect.values) {
    test('${dialect.name} requests popup descriptions and preserves program/channel age ratings', () async {
      final requests = <Uri>[];
      final client = testJellyfinClient(
        connection: testJellyfinConnection(dialect: dialect),
        handler: (request) async {
          requests.add(request.url);
          if (request.url.path.endsWith('/Channels')) {
            return jsonResponse({
              'Items': [
                {'Id': 'channel', 'Name': 'News', 'OfficialRating': 'TV-14'},
              ],
            });
          }
          // Model the servers' opt-in field: an unrequested overview is absent.
          final fields = request.url.queryParameters['fields']?.split(',') ?? [];
          return jsonResponse({
            'Items': [
              {
                'Id': 'program',
                'Name': 'News',
                'OfficialRating': 'US/TV-PG',
                if (fields.contains('Overview')) 'Overview': 'The latest headlines.',
              },
              {'Id': 'unrated', 'Name': 'No description or rating'},
            ],
          });
        },
      );
      addTearDown(client.close);
      final programs = await client.liveTv.fetchSchedule();
      expect(requests.single.queryParameters['fields'], contains('Overview'));
      expect(programs.first.summary, 'The latest headlines.');
      expect(programs.first.contentRating, 'US/TV-PG');
      final copied = programs.first.copyWith(serverName: 'Tagged');
      expect(copied.summary, programs.first.summary);
      expect(copied.contentRating, programs.first.contentRating);
      expect(programs.last.summary, isNull);
      expect(programs.last.contentRating, isNull);
      final channels = await client.fetchLiveTvChannels();
      expect(channels.single.contentRating, 'TV-14');
      expect(channels.single.copyWith(serverName: 'Tagged').contentRating, 'TV-14');
    });

    test('${dialect.name} preserves primary/episode titles and normalizes explicit broadcast flags', () async {
      final client = testJellyfinClient(
        connection: testJellyfinConnection(dialect: dialect),
        handler: (_) async => jsonResponse({
          'Items': [
            {
              'Name': 'Primary',
              'EpisodeTitle': 'The 100',
              'SeriesName': 'Different series metadata',
              'IndexNumber': 3,
              'ParentIndexNumber': 2,
              'IsLive': true,
              'IsNew': true,
              'IsPremiere': true,
            },
            {'Name': 'Series', 'EpisodeTitle': ' Episode 2000 ', 'IsSeries': true, 'IsRepeat': false},
            {
              'Name': 'Series',
              'EpisodeTitle': 'Episode 2000: The Return',
              'IsSeries': true,
              'IsRepeat': true,
              'IsNew': true,
            },
            {'Name': 'Series with omitted repeat', 'IsSeries': true},
            {'Name': 'Premiere', 'IsPremiere': true},
            {'Name': 'New', 'IsNew': true},
            {'Name': 'Explicit old', 'IsNew': false, 'IsSeries': true, 'IsRepeat': false},
            {'Name': 'Not a series', 'IsRepeat': false},
            {'Name': 'No episode', 'SeriesName': 'Other', 'IndexNumber': 3},
          ],
        }),
      );
      addTearDown(client.close);
      final programs = await client.liveTv.fetchSchedule();
      expect(programs.map((p) => p.guideBadge), [
        GuideProgramBadge.live,
        GuideProgramBadge.newProgram,
        null,
        dialect == MediaBrowserDialect.jellyfin ? GuideProgramBadge.newProgram : null,
        GuideProgramBadge.newProgram,
        GuideProgramBadge.newProgram,
        null,
        null,
        null,
      ]);
      expect(programs.first.guideTitle, 'Primary');
      expect(programs.first.title, 'Primary');
      expect(programs.first.episodeTitle, 'The 100');
      expect(programs.first.guideSubtitle, 'The 100');
      expect(programs.first.index, 3);
      expect(programs.first.parentIndex, 2);
      expect(programs[1].episodeTitle, ' Episode 2000 ');
      expect(programs[1].guideSubtitle, isNull);
      expect(programs[2].guideSubtitle, 'Episode 2000: The Return');
      expect(programs.last.guideTitle, 'No episode');
      expect(programs.last.guideSubtitle, isNull);
      expect(programs.first.copyWith(serverName: 'Tagged').guideSubtitle, 'The 100');
    });
  }

  for (final dialect in MediaBrowserDialect.values) {
    test('${dialect.name} sparse repeat flags retain explicit NEW, LIVE, and unknown metadata rules', () async {
      final client = testJellyfinClient(
        connection: testJellyfinConnection(dialect: dialect),
        handler: (_) async => jsonResponse({
          'Items': [
            {'Name': 'Missing repeat', 'IsSeries': true},
            {'Name': 'Null repeat', 'IsSeries': true, 'IsRepeat': null},
            {'Name': 'Repeat', 'IsSeries': true, 'IsRepeat': true},
            {'Name': 'Explicit old', 'IsSeries': true, 'IsNew': false},
            {'Name': 'Live series', 'IsSeries': true, 'IsLive': true},
            {'Name': 'Explicit new', 'IsNew': true},
            {'Name': 'No flags'},
            {'Name': 'Not a series', 'IsSeries': false},
            {'Name': 'Null series', 'IsSeries': null},
          ],
        }),
      );
      addTearDown(client.close);
      final programs = await client.liveTv.fetchSchedule();
      expect(
        programs.map((p) => p.guideBadge),
        dialect == MediaBrowserDialect.jellyfin
            ? [
                GuideProgramBadge.newProgram,
                GuideProgramBadge.newProgram,
                null,
                null,
                GuideProgramBadge.live,
                GuideProgramBadge.newProgram,
                null,
                null,
                null,
              ]
            : [null, null, null, null, GuideProgramBadge.live, GuideProgramBadge.newProgram, null, null, null],
      );
      expect(programs.first.repeat, isNull);
      expect(programs.first.copyWith(serverName: 'Decorated').guideBadge, programs.first.guideBadge);
    });
  }

  test('guide window lower bound is minEndDate so currently-airing programmes are kept', () async {
    // Jellyfin translates MinStartDate to `StartDate >= …`, which drops a
    // programme that began before the window even though it is still running
    // over "now". MinEndDate (`EndDate >= …`) is the overlap filter.
    final captured = <Uri>[];
    final client = testJellyfinClient(
      handler: (request) async {
        captured.add(request.url);
        return jsonResponse({'Items': const <Object?>[]});
      },
    );
    addTearDown(client.close);

    final from = DateTime.utc(2026, 8, 20, 19);
    final to = DateTime.utc(2026, 8, 21, 1);
    await client.fetchLiveTvPrograms(
      channelIds: const ['ch-1', 'ch-2'],
      beginsAt: from.millisecondsSinceEpoch ~/ 1000,
      endsAt: to.millisecondsSinceEpoch ~/ 1000,
    );

    final request = captured.single;
    expect(request.path, '/LiveTv/Programs');
    expect(request.queryParameters['channelIds'], 'ch-1,ch-2');
    expect(request.queryParameters['minEndDate'], from.toIso8601String());
    expect(request.queryParameters['maxStartDate'], to.toIso8601String());
    expect(request.queryParameters.containsKey('minStartDate'), isFalse);
  });

  test('LiveTvSupport.fetchSchedule forwards the window through the same overlap bounds', () async {
    final captured = <Uri>[];
    final client = testJellyfinClient(
      handler: (request) async {
        captured.add(request.url);
        return jsonResponse({'Items': const <Object?>[]});
      },
    );
    addTearDown(client.close);

    final from = DateTime.utc(2026, 8, 20, 19);
    final to = DateTime.utc(2026, 8, 21, 1);
    await client.liveTv.fetchSchedule(from: from, to: to);

    final request = captured.single;
    expect(request.path, '/LiveTv/Programs');
    expect(request.queryParameters['minEndDate'], from.toIso8601String());
    expect(request.queryParameters['maxStartDate'], to.toIso8601String());
    expect(request.queryParameters.containsKey('minStartDate'), isFalse);
  });

  test('programs carry recording state: guid seed, timer key, and series key', () async {
    final client = testJellyfinClient(
      handler: (_) async => jsonResponse({
        'Items': [
          // Scheduled through a series rule: both keys stamped.
          {'Id': 'p-1', 'Name': 'Ep 1', 'TimerId': 't-1', 'SeriesTimerId': 's-1'},
          // One-off recording: timer key only.
          {'Id': 'p-2', 'Name': 'Ep 2', 'TimerId': 't-2'},
          // Series rule exists but skips this airing (cancelled child):
          // must NOT read as scheduled or the guide shows a false red dot.
          {'Id': 'p-3', 'Name': 'Ep 3', 'SeriesTimerId': 's-1'},
          // Untouched airing.
          {'Id': 'p-4', 'Name': 'Ep 4'},
        ],
      }),
    );
    addTearDown(client.close);

    final programs = await client.fetchLiveTvPrograms();

    // The program id doubles as the recording seed for Timers/Defaults.
    expect(programs.map((p) => p.guid), ['p-1', 'p-2', 'p-3', 'p-4']);

    final scheduledViaSeries = programs[0];
    expect(scheduledViaSeries.subscriptionId, 'timer:t-1');
    expect(scheduledViaSeries.grandparentSubscriptionId, 'series:s-1');
    // Manage targets the series rule when one covers the airing.
    expect(scheduledViaSeries.recordingRuleKey, 'series:s-1');

    final oneOff = programs[1];
    expect(oneOff.subscriptionId, 'timer:t-2');
    expect(oneOff.grandparentSubscriptionId, isNull);
    expect(oneOff.recordingRuleKey, 'timer:t-2');

    final skipped = programs[2];
    expect(skipped.subscriptionId, isNull);
    expect(skipped.grandparentSubscriptionId, isNull);
    expect(skipped.recordingRuleKey, isNull);

    expect(programs[3].recordingRuleKey, isNull);
  });
}
