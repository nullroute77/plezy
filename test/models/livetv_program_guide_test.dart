import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/models/livetv_program.dart';

void main() {
  test('Plex guide keeps episode metadata and timing when attaching a server', () {
    final program = LiveTvProgram.fromJson(
      {
        'title': 'Heat Day',
        'grandparentTitle': 'Cooking Contest',
        'parentIndex': '1',
        'index': 9,
        'summary': 'Cooking in the summer.',
        'contentRating': 'TV-PG',
      },
      mediaOverride: {'beginsAt': 10, 'endsAt': 1810, 'contentRating': 'TV-14'},
    ).copyWith(serverId: ServerId('server'));
    expect(program.guideTitle, 'Cooking Contest');
    expect(program.guideSubtitle, 'Heat Day');
    expect(program.title, 'Heat Day');
    expect(program.parentIndex, 1);
    expect(program.index, 9);
    expect(program.durationMinutes, 30);
    expect(program.summary, 'Cooking in the summer.');
    expect(program.contentRating, 'TV-14');
  });

  test('Plex guide filters standalone placeholders while retaining meaningful numbered titles', () {
    const titles = ['', ' episode 002 ', 'EPISODE\t12', '2000', 'Part 2', 'Episode 2000: Heat Day'];
    final programs = titles.map(
      (title) => LiveTvProgram.fromJson({'title': title, 'grandparentTitle': 'Series', 'parentIndex': 1, 'index': 2}),
    );
    expect(programs.map((p) => p.guideTitle), everyElement('Series'));
    expect(programs.map((p) => p.guideSubtitle), [null, null, null, '2000', 'Part 2', 'Episode 2000: Heat Day']);
    final missing = LiveTvProgram.fromJson({'grandparentTitle': 'Series'});
    expect(missing.guideTitle, 'Series');
    expect(missing.guideSubtitle, isNull);
  });
}
