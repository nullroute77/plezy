import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/models/livetv_program.dart';

void main() {
  test('broadcast designation, not current airing, controls LIVE; LIVE wins', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final airing = LiveTvProgram(title: 'Repeat', beginsAt: now - 60, endsAt: now + 60);
    expect(airing.isCurrentlyAiring, isTrue);
    expect(airing.guideBadge, isNull);
    for (final live in [null, false, true]) {
      for (final isNew in [null, false, true]) {
        for (final premiere in [null, false, true]) {
          for (final repeat in [null, false, true]) {
            final program = LiveTvProgram(title: 'Show', live: live, isNew: isNew, premiere: premiere, repeat: repeat);
            expect(
              program.guideBadge,
              live == true
                  ? GuideProgramBadge.live
                  : repeat != true && (isNew == true || premiere == true)
                  ? GuideProgramBadge.newProgram
                  : null,
            );
          }
        }
      }
    }
  });

  test('Plex selected airing flags override metadata flags, including explicit false', () {
    final json = <String, dynamic>{
      'title': 'The 100',
      'grandparentTitle': 'Science',
      'parentIndex': 2,
      'index': 3,
      'live': 1,
      'premiere': true,
      'new': '1',
      'repeat': false,
      'Media': [
        {'live': '0', 'premiere': 0, 'new': false, 'repeat': 1},
      ],
    };
    expect(LiveTvProgram.fromJson(json).guideBadge, isNull);
    final program = LiveTvProgram.fromJson(
      json,
      mediaOverride: {'live': 'true', 'premiere': 'false', 'new': 0, 'repeat': '0', 'beginsAt': 10, 'endsAt': 1810},
    ).copyWith(serverId: ServerId('server'));
    expect(program.guideBadge, GuideProgramBadge.live);
    expect(program.guideTitle, 'Science');
    expect(program.guideSubtitle, 'The 100');
    expect(program.title, 'The 100');
    expect(program.parentIndex, 2);
    expect(program.index, 3);
    expect(program.durationMinutes, 30);
    expect(LiveTvProgram.fromJson({'title': 'Movie', 'premiere': 1}).guideBadge, GuideProgramBadge.newProgram);
    expect(LiveTvProgram.fromJson({'title': 'Movie', 'repeat': false}).guideBadge, isNull);
    expect(LiveTvProgram.fromJson({'title': 'Movie'}).guideSubtitle, isNull);
  });

  for (final secondary in ['', '  ', 'Episode 2000', ' episode 002 ', 'EPISODE\t12']) {
    test('suppresses only standalone placeholder/empty subtext: "$secondary"', () {
      final plex = LiveTvProgram.fromJson({
        'title': secondary,
        'grandparentTitle': 'Series',
        'index': 2000,
        'parentIndex': 5,
      });
      final normalized = LiveTvProgram(title: 'Series', programTitle: 'Series', episodeTitle: secondary);
      expect(plex.guideSubtitle, isNull);
      expect(normalized.guideSubtitle, isNull);
    });
  }
  for (final secondary in [
    'The 100',
    '2000',
    'Episode 2000: A New Beginning',
    'Episode 9 from Outer Space',
    'Part 2',
    '2001: A Space Odyssey',
    'Season 2 Finale',
  ]) {
    test('keeps meaningful numeric title "$secondary" without S/E prefix', () {
      final plex = LiveTvProgram.fromJson({
        'title': ' $secondary ',
        'grandparentTitle': 'Series',
        'index': 9,
        'parentIndex': 1,
      });
      expect(plex.guideSubtitle, secondary);
      expect(plex.copyWith(serverName: 'Server').guideSubtitle, secondary);
    });
  }
}
