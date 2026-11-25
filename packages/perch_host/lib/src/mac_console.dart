// macOS: operates terminal Claude Code sessions that are already open, in the terminal
// app that holds them, without closing them or bringing that app to the front.
//
// - Terminal.app: the tab is found by the session's tty (AppleScript); its screen is the
//   tab's `contents`; keys and text are posted to Terminal (MacHelper) after the tab is
//   made the selected tab of Terminal's front window.
// - Warp: no scripting interface. The session's tab is found by writing a marker title to
//   its tty (an OSC 0 sequence, invisible on screen) and looking for a Warp window showing
//   that title; a tab that is not in front is reached by switching tabs (Cmd-Shift-]).
//   Only the front tab of a window can be read, through Accessibility. Reading the screen
//   never switches tabs; typing and answering do.
// - tmux (in any terminal): through TmuxTerminalConsole.
// Anything else (iTerm2, VS Code, a session with no terminal) cannot be operated: the
// calls return false or null and the app offers the take-over.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'console_typer.dart';
import 'dialog_screen.dart';
import 'mac_helper.dart';
import 'tmux_console.dart';

enum MacTerminalApp { terminal, warp, tmux }

/// Where a session's `claude` runs: the app, its process id, and the session's tty.
class MacTarget {
  final MacTerminalApp app;
  final int appPid;
  final String? tty;
  const MacTarget(this.app, this.appPid, this.tty);
  @override
  String toString() => 'MacTarget($app, $appPid, $tty)';
}

/// One row of `ps -Ao pid=,ppid=,tty=,comm=`.
typedef PsRow = ({int pid, int ppid, String tty, String command});

/// Writes [data] to the terminal device [tty] (as output: it shows on that terminal).
typedef TtyWriter = Future<void> Function(String tty, String data);

Future<void> writeTty(String tty, String data) async {
  final f = await File(tty).open(mode: FileMode.writeOnly);
  try {
    await f.writeFrom(utf8.encode(data));
  } finally {
    await f.close();
  }
}

class MacTerminalConsole implements TerminalConsole {
  final MacHelper helper;
  final MacRunner _run;
  final TtyWriter _writeTty;
  final TmuxTerminalConsole? tmux;
  final bool _available;

  /// Pause after a Warp tab switch or a title change before reading titles again.
  final Duration settle;

  /// Pause before the Enter that submits a typed message (Claude Code takes quick input
  /// for a paste, in which Enter is a new line).
  final Duration beforeSubmit;

  /// How many tabs of one Warp window are tried before giving up.
  final int maxTabs;

  /// Told why a message could not be typed (the host's console).
  final void Function(String line)? log;

  /// Warp's own database (window, tab order and each tab's folder, for session restore).
  final String warpDb;

  MacTerminalConsole({
    required this.helper,
    this.tmux,
    MacRunner? run,
    TtyWriter? writeTty,
    bool? available,
    this.settle = const Duration(milliseconds: 250),
    this.beforeSubmit = const Duration(milliseconds: 400),
    this.maxTabs = 12,
    this.log,
    String? warpDb,
  })  : warpDb = warpDb ??
            '${Platform.environment['HOME']}/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite',
        _run = run ?? runProcess,
        _writeTty = writeTty ?? _defaultWriteTty,
        _available = available ?? Platform.isMacOS;

  static Future<void> _defaultWriteTty(String tty, String data) => writeTty(tty, data);

  @override
  bool get supported => _available;

  // ---------------------------------------------------------------- locating

  static List<PsRow> parsePs(String out) {
    final rows = <PsRow>[];
    for (final line in const LineSplitter().convert(out)) {
      final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.+?)\s*$').firstMatch(line);
      if (m == null) continue;
      rows.add((pid: int.parse(m[1]!), ppid: int.parse(m[2]!), tty: m[3]!, command: m[4]!));
    }
    return rows;
  }

  /// Which terminal app holds [pid], from its ancestors in [rows] (null: none Perch knows).
  static MacTarget? targetFrom(List<PsRow> rows, int pid) {
    final byPid = {for (final r in rows) r.pid: r};
    final self = byPid[pid];
    if (self == null) return null;
    final tty = self.tty.startsWith('ttys') ? '/dev/${self.tty}' : null;
    var cur = self;
    for (var i = 0; i < 24; i++) {
      final up = byPid[cur.ppid];
      if (up == null) return null;
      if (up.command.contains('/Terminal.app/')) return MacTarget(MacTerminalApp.terminal, up.pid, tty);
      if (up.command.contains('/Warp.app/') || up.command.contains('/WarpPreview.app/')) {
        // Warp runs each tab's shell under a helper process of its own app; the app is
        // the topmost Warp process.
        var app = up;
        while (true) {
          final next = byPid[app.ppid];
          if (next == null || !(next.command.contains('/Warp.app/') || next.command.contains('/WarpPreview.app/'))) break;
          app = next;
        }
        return MacTarget(MacTerminalApp.warp, app.pid, tty);
      }
      cur = up;
    }
    return null;
  }

  Future<MacTarget?> locate(int pid) async {
    if (!supported) return null;
    // Inside tmux (whatever terminal shows it): tmux is the way in.
    final t = tmux;
    if (t != null && await t.paneOf(pid) != null) return MacTarget(MacTerminalApp.tmux, 0, null);
    try {
      final r = await _run('/bin/ps', ['-Ao', 'pid=,ppid=,tty=,comm=']);
      if (r.exitCode != 0) return null;
      final target = targetFrom(parsePs(r.stdout), pid);
      if (target?.tty case final tty?) _claudeByTty[tty] = pid;
      return target?.tty == null && target?.app != MacTerminalApp.tmux ? null : target;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- Terminal.app

  /// AppleScript: finds Terminal's tab with tty `item 1`; `screen` prints `ok` then the
  /// tab's visible text; `front` makes it the selected tab of the front window (without
  /// activating Terminal) and prints `ok` when it is.
  static const terminalScript = r'''
on run argv
  set want to item 1 of argv
  set act to item 2 of argv
  tell application "Terminal"
    repeat with i from 1 to count of windows
      repeat with j from 1 to count of tabs of window i
        if tty of tab j of window i is want then
          if act is "screen" then return "ok" & linefeed & (contents of tab j of window i)
          set selected of tab j of window i to true
          set index of window i to 1
          if tty of selected tab of front window is want then return "ok"
          return "error not-front"
        end if
      end repeat
    end repeat
  end tell
  return "error not-found"
end run
''';

  Future<String?> _terminal(String tty, String action) async {
    try {
      final r = await _run('/usr/bin/osascript', ['-e', terminalScript, tty, action]);
      if (r.exitCode != 0) return null;
      final out = r.stdout;
      if (!out.startsWith('ok')) return null;
      final nl = out.indexOf('\n');
      return nl < 0 ? '' : out.substring(nl + 1);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- Warp

  final _random = Random();

  /// A title no real tab has.
  String _marker() => 'Perch ${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';

  /// OSC 0 (icon name and title), ended with ST: Warp shows it as the tab's title.
  static String titleSequence(String title) => '\x1b]0;$title\x1b\\';

  /// Marks [t]'s tab with a new title and returns the index of the Warp window whose front
  /// tab it is (front first), or null. With [switchTabs] it also tries the other tabs of
  /// every window, leaving the found tab in front; tabs it went through without finding it
  /// are put back. The tab's previous title is written back when it was seen.
  Future<int?> _findWarp(MacTarget t, {required bool switchTabs}) async {
    final tty = t.tty!;
    // The helper writes the marker and watches the titles in one process: a busy
    // session's spinner rewrites the title within a fraction of a second.
    Future<({int? index, String? before})> look() async {
      for (var attempt = 0; attempt < 2; attempt++) {
        final r = await helper.mark(t.appPid, tty, _marker());
        if (r == null) return (index: null, before: null);
        final i = r.index;
        if (i != null) {
          final old = i < r.before.length ? r.before[i] : null;
          return (index: i, before: old != null && !old.startsWith('Perch ') ? old : null);
        }
      }
      return (index: null, before: null);
    }

    Future<int?> found(({int? index, String? before}) r) async {
      final b = r.before;
      if (b != null) {
        try {
          await _writeTty(tty, titleSequence(b));
        } catch (_) {}
      }
      return r.index;
    }

    final first = await look();
    if (first.index != null || !switchTabs) return found(first);
    final count = (await helper.titles(t.appPid))?.length ?? 0;
    for (var w = 0; w < count; w++) {
      if (!await helper.raise(t.appPid, w)) continue;
      await Future<void>.delayed(settle);
      var steps = 0;
      for (; steps < maxTabs; steps++) {
        if (!await helper.post(t.appPid, const [KeyPress(MacKeys.rightBracket, MacKeys.command | MacKeys.shift)])) break;
        await Future<void>.delayed(settle);
        final r = await look();
        if (r.index == 0) return found(r);
      }
      // Not in this window: back to the tab that was in front.
      await helper.post(t.appPid, List.filled(steps, const KeyPress(MacKeys.leftBracket, MacKeys.command | MacKeys.shift)));
    }
    return null;
  }

  /// Makes [t]'s tab the one that receives keys: the selected tab of its app's front window.
  /// With [needsInputBox] (typing a message) a Warp tab matched by folder must also show
  /// Claude Code's input box.
  Future<bool> _front(MacTarget t, {bool needsInputBox = false}) async {
    switch (t.app) {
      case MacTerminalApp.terminal:
        return await _terminal(t.tty!, 'front') != null;
      case MacTerminalApp.warp:
        final shown = await _findWarp(t, switchTabs: false);
        if (shown != null) return shown == 0 || await helper.raise(t.appPid, shown);
        // While Claude waits for the owner (a question, or idle for a minute) Warp shows
        // its own title ("Wants to run …", "Claude is waiting for your input") and ignores
        // the marker. The tab is then the one Warp's database lists in the session's folder
        // (one window, one such tab). Before a key press the answerer checks the screen shows
        // the expected dialog; a message needs Claude Code's input box on that tab.
        final tab = await _warpTabFor(t);
        if (tab == null) {
          final i = await _findWarp(t, switchTabs: true);
          return i != null && (i == 0 || await helper.raise(t.appPid, i));
        }
        if (tab.index != tab.active) {
          if (tab.index > 8) return false;
          if (!await helper.post(t.appPid, [KeyPress(digitKeys[tab.index], MacKeys.command)])) return false;
          await Future<void>.delayed(settle);
        }
        if (needsInputBox) {
          final ws = await helper.windows(t.appPid);
          if (ws == null || ws.isEmpty || !isPromptReady(screenText(ws.first.text))) return false;
        }
        _folderMatched[t.tty!] = DateTime.now();
        return true;
      case MacTerminalApp.tmux:
        return true;
    }
  }

  /// Mac key codes of the digits 1 to 9 (Warp: `Cmd-n` shows tab n).
  static const digitKeys = [18, 19, 20, 21, 23, 22, 26, 28, 25];

  /// When a tty's Warp tab was last brought forward by its folder (see [_front]).
  final Map<String, DateTime> _folderMatched = {};

  /// The working folder of process [pid].
  Future<String?> _cwdOf(int pid) async {
    try {
      final r = await _run('/usr/sbin/lsof', ['-a', '-p', '$pid', '-d', 'cwd', '-Fn']);
      for (final l in const LineSplitter().convert(r.stdout)) {
        if (l.startsWith('n/')) return l.substring(1);
      }
    } catch (_) {}
    return null;
  }

  /// Warp's tabs from its database: window id, tab position, the tab's folder, and the
  /// window's front tab position.
  static const warpTabsQuery = 'select t.window_id, t.id, coalesce(tp.cwd, \'\'), w.active_tab_index '
      'from terminal_panes tp join pane_nodes pn on pn.id = tp.id join tabs t on t.id = pn.tab_id '
      'join windows w on w.id = t.window_id order by t.window_id, t.id';

  static List<({int window, int index, String cwd, int active})> parseWarpTabs(String out) {
    final rows = <({int window, int index, String cwd, int active})>[];
    final positions = <int, int>{};
    final seenTabs = <int>{};
    for (final line in const LineSplitter().convert(out)) {
      final f = line.split('\t');
      if (f.length != 4) continue;
      final w = int.tryParse(f[0]), tab = int.tryParse(f[1]), active = int.tryParse(f[3]);
      if (w == null || tab == null || active == null) continue;
      // A tab split into panes has several rows; its position counts once.
      if (!seenTabs.add(tab)) continue;
      final index = positions[w] = (positions[w] ?? -1) + 1;
      rows.add((window: w, index: index, cwd: f[2], active: active));
    }
    return rows;
  }

  Future<({int index, int active})?> _warpTabFor(MacTarget t) async {
    final cwd = await _cwdOf(await _claudePidFor(t) ?? -1);
    if (cwd == null) return null;
    final RunResult r;
    try {
      r = await _run('/usr/bin/sqlite3', ['-readonly', '-separator', '\t', 'file:$warpDb?mode=ro', warpTabsQuery]);
    } catch (_) {
      return null;
    }
    if (r.exitCode != 0) return null;
    final tabs = parseWarpTabs(r.stdout);
    final windows = tabs.map((x) => x.window).toSet();
    final titles = await helper.titles(t.appPid);
    if (windows.length != 1 || titles == null || titles.length != 1) return null;
    final matches = tabs.where((x) => x.cwd == cwd).toList();
    if (matches.length != 1) return null;
    return (index: matches.single.index, active: matches.single.active);
  }

  /// The `claude` process of a target (remembered by [locate]).
  final Map<String, int> _claudeByTty = {};
  Future<int?> _claudePidFor(MacTarget t) async => _claudeByTty[t.tty];

  // ---------------------------------------------------------------- keys

  /// [ConsoleKeys] special characters as Mac key codes.
  static final Map<String, int> keyCodes = {
    ConsoleKeys.up: MacKeys.up,
    ConsoleKeys.down: MacKeys.down,
    ConsoleKeys.left: MacKeys.left,
    ConsoleKeys.right: MacKeys.right,
    ConsoleKeys.escape: MacKeys.escape,
    ConsoleKeys.tab: MacKeys.tab,
    ConsoleKeys.enter: MacKeys.enter,
  };

  /// The helper steps that press [keys]: special keys by key code, the rest typed as text.
  static List<KeyStep> stepsFor(String keys) {
    final steps = <KeyStep>[];
    final text = StringBuffer();
    void flush() {
      if (text.isEmpty) return;
      steps.add(TextStep(text.toString()));
      text.clear();
    }

    for (final rune in keys.runes) {
      final ch = String.fromCharCode(rune);
      final code = keyCodes[ch];
      if (code != null) {
        flush();
        steps.add(KeyPress(code));
      } else {
        text.write(ch);
      }
    }
    flush();
    return steps;
  }

  /// A message as a bracketed paste (line breaks stay line breaks, nothing is submitted),
  /// so Claude Code takes it exactly as if the owner pasted it.
  static String pasteOf(String text) =>
      '\x1b[200~${text.replaceAll('\r\n', '\n').replaceAll('\r', '\n')}\x1b[201~';

  Future<bool> _post(int pid, MacTarget t, List<KeyStep> steps, {bool needsInputBox = false}) async {
    if (t.app == MacTerminalApp.tmux) return false;
    if (!await _front(t, needsInputBox: needsInputBox)) return false;
    return helper.post(t.appPid, steps);
  }

  @override
  Future<bool> canOperate(int pid) async => await locate(pid) != null;

  @override
  Future<bool> bringForward(int pid) async {
    final t = await locate(pid);
    if (t == null) return false;
    if (t.app == MacTerminalApp.tmux) return true;
    return _front(t);
  }

  @override
  Future<bool> type(int pid, String text) async {
    final t = await locate(pid);
    if (t == null) {
      log?.call('Cannot type into claude (pid $pid): it does not run in Terminal, Warp or tmux.');
      return false;
    }
    if (t.app == MacTerminalApp.tmux) return tmux!.type(pid, text);
    if (!await helper.trusted()) {
      log?.call('Cannot type into claude (pid $pid): the Accessibility permission is off for the app the host runs in.');
      return false;
    }
    if (!await _front(t, needsInputBox: true)) {
      log?.call('Cannot type into claude (pid $pid, ${t.app.name}, ${t.tty}): its tab was not found, '
          'or (matched by folder) it does not show the input box.');
      return false;
    }
    // The tab is identified by its marker title, or matched by folder and showing Claude
    // Code's input box. The message, then Enter on its own.
    if (text.isNotEmpty && !await helper.post(t.appPid, [TextStep(pasteOf(text))])) return false;
    await Future<void>.delayed(beforeSubmit);
    return _post(pid, t, const [KeyPress(MacKeys.enter)], needsInputBox: true);
  }

  @override
  Future<bool> keys(int pid, String keys) async {
    final t = await locate(pid);
    if (t == null) return false;
    if (t.app == MacTerminalApp.tmux) return tmux!.keys(pid, keys);
    return _post(pid, t, stepsFor(keys));
  }

  @override
  Future<bool> pressEnter(int pid) => keys(pid, ConsoleKeys.enter);

  // ---------------------------------------------------------------- screen

  /// The last [rows] non-empty rows of [text], trailing spaces trimmed (the shape of the
  /// Windows console reader).
  static String screenText(String text, {int rows = 60}) {
    final lines = const LineSplitter().convert(text).map((l) => l.trimRight()).toList();
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    final visible = lines.length > rows ? lines.sublist(lines.length - rows) : lines;
    final kept = visible.where((l) => l.isNotEmpty);
    return kept.isEmpty ? '' : '${kept.join('\n')}\n';
  }

  @override
  Future<String?> screen(int pid) async {
    final t = await locate(pid);
    if (t == null) return null;
    switch (t.app) {
      case MacTerminalApp.tmux:
        return tmux!.screen(pid);
      case MacTerminalApp.terminal:
        final s = await _terminal(t.tty!, 'screen');
        return s == null ? null : screenText(s, rows: 1000);
      case MacTerminalApp.warp:
        // Only a tab in front can be read; reading never switches tabs.
        var i = await _findWarp(t, switchTabs: false);
        if (i == null) {
          // Brought forward by folder for an answer in the last two minutes, and still the
          // front tab per Warp: read it (the answerer checks what it shows).
          final at = _folderMatched[t.tty];
          if (at == null || DateTime.now().difference(at) > const Duration(minutes: 2)) return null;
          final tab = await _warpTabFor(t);
          if (tab == null || tab.index != tab.active) return null;
          i = 0;
        }
        final ws = await helper.windows(t.appPid);
        if (ws == null || i >= ws.length) return null;
        return screenText(ws[i].text);
    }
  }
}
