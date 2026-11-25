// `@` file mentions: the files and folders of a session's folder, matched as the owner types.
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

void main() {
  const all = [
    FileMention(path: 'README.md'),
    FileMention(path: 'docs', dir: true),
    FileMention(path: 'docs/PRD.md'),
    FileMention(path: 'docs/ui', dir: true),
    FileMention(path: 'docs/ui/model-table.png'),
    FileMention(path: 'lib', dir: true),
    FileMention(path: 'lib/src', dir: true),
    FileMention(path: 'lib/src/session_screen.dart'),
    FileMention(path: 'lib/src/server.dart'),
    FileMention(path: 'notes.txt'),
  ];

  List<String> paths(String q, {int limit = 50}) => [for (final f in matchFiles(all, q, limit: limit)) f.path];

  test('nothing typed: the top of the folder first', () {
    expect(paths('').take(4), ['docs', 'lib', 'notes.txt', 'README.md']);
  });

  test('a name: exact and prefix first, then contains, then letters in order', () {
    expect(paths('notes').first, 'notes.txt');
    expect(paths('ser').first, 'lib/src/server.dart', reason: 'name prefix');
    expect(paths('ser'), contains('lib/src/session_screen.dart'), reason: 'letters in order (s-e-r in session_screen)');
    expect(paths('PRD').single, 'docs/PRD.md', reason: 'case folded');
    expect(paths('sscr').first, 'lib/src/session_screen.dart', reason: 'fuzzy');
    expect(paths('zzz'), isEmpty);
  });

  test('a path: within the folder', () {
    expect(paths('docs/').take(3), ['docs/PRD.md', 'docs/ui', 'docs/ui/model-table.png']);
    expect(paths('lib/src/se').first, 'lib/src/server.dart');
    expect(paths('', limit: 3), hasLength(3));
  });

  test('the text inserted for a mention', () {
    expect(const FileMention(path: 'notes.txt').mention, '@notes.txt');
    expect(const FileMention(path: 'docs', dir: true).mention, '@docs/');
    expect(const FileMention(path: 'my notes/a b.txt').mention, '@"my notes/a b.txt"');
  });

  test('the word being typed after @', () {
    expect(mentionAt('see @no', 7), (start: 4, query: 'no'));
    expect(mentionAt('@', 1), (start: 0, query: ''));
    expect(mentionAt('see @docs/ui and', 12), (start: 4, query: 'docs/ui'));
    expect(mentionAt('mail me@host', 12), isNull, reason: 'an @ inside a word is not a mention');
    expect(mentionAt('see @no more', 12), isNull, reason: 'the cursor is past the word');
    expect(mentionAt('', 0), isNull);
  });

  test('wire', () {
    final c = decodeClient(encodeClient(const ListFiles(sessionId: 's1', query: 'no')))!;
    expect(c.toJson(), const ListFiles(sessionId: 's1', query: 'no').toJson());
    const m = FilesMessage(
        sessionId: 's1', query: 'no', files: [FileMention(path: 'notes.txt'), FileMention(path: 'docs', dir: true)], truncated: true);
    final back = decodeHost(encodeHost(m))! as FilesMessage;
    expect(back.toJson(), m.toJson());
    expect(back.files.last.dir, isTrue);
    expect(FileMention.tryFromJson({'path': ''}), isNull);
    expect(FileMention.tryFromJson({'path': '../up'}), isNull, reason: 'never outside the folder');
  });
}
