// macOS: a small Swift helper, compiled on first use with the Xcode command-line tools,
// that posts keyboard events to an app (CGEventPostToPid: the app need not be in front)
// and reads or raises its windows through Accessibility. Both need the Accessibility
// permission for the app the host runs in (System Settings > Privacy & Security >
// Accessibility: Terminal).
import 'dart:convert';
import 'dart:io';

/// Result of running a program: its exit code and stdout.
typedef RunResult = ({int exitCode, String stdout});

/// Runs [executable] with [args].
typedef MacRunner = Future<RunResult> Function(String executable, List<String> args);

Future<RunResult> runProcess(String executable, List<String> args) async {
  final r = await Process.run(executable, args, stdoutEncoding: const Utf8Codec(allowMalformed: true))
      .timeout(const Duration(seconds: 20));
  return (exitCode: r.exitCode, stdout: '${r.stdout}');
}

/// One window of an app, front first: its title and the text of its first text area
/// (Warp: the front tab's screen and scrollback, last 400 lines).
class AxWindow {
  final String title;
  final String text;
  const AxWindow(this.title, this.text);
}

/// Mac virtual key codes and modifier flags used by the helper.
abstract final class MacKeys {
  static const up = 126, down = 125, left = 123, right = 124, escape = 53, tab = 48, enter = 36, backspace = 51;
  static const rightBracket = 30, leftBracket = 33;
  static const command = 1 << 20, shift = 1 << 17;
}

/// One step for `post`: text typed character by character, a key, or a pause.
sealed class KeyStep {
  const KeyStep();
  String get arg;
}

class TextStep extends KeyStep {
  final String text;
  const TextStep(this.text);
  @override
  String get arg => 't:${base64Encode(utf8.encode(text))}';
}

class KeyPress extends KeyStep {
  final int code;
  final int flags;
  const KeyPress(this.code, [this.flags = 0]);
  @override
  String get arg => flags == 0 ? 'k:$code' : 'k:$code:$flags';
}

class Pause extends KeyStep {
  final int ms;
  const Pause(this.ms);
  @override
  String get arg => 'd:$ms';
}

class MacHelper {
  /// Folder for the compiled helper (`<state dir>/bin`).
  final String binDir;

  /// Folders searched for a prebuilt helper of this source (the release ships one next to
  /// the compiled host, so no Xcode tools are needed). Default: the host executable's folder.
  final List<String> prebuiltDirs;
  final MacRunner _run;
  String? _path;

  MacHelper({required this.binDir, List<String>? prebuiltDirs, MacRunner? run})
      : prebuiltDirs = prebuiltDirs ?? [File(Platform.resolvedExecutable).parent.path],
        _run = run ?? runProcess;

  /// The helper's file name carries a hash of its source, so a changed source is rebuilt.
  static String get fileName => 'perch-mac-helper-${_hash(helperSource)}';

  static String _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in utf8.encode(s)) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// The compiled helper, building it when missing; null when it cannot be built.
  Future<String?> path() async {
    final known = _path;
    if (known != null && File(known).existsSync()) return known;
    for (final d in prebuiltDirs) {
      final shipped = File('$d${Platform.pathSeparator}$fileName');
      if (shipped.existsSync()) return _path = shipped.path;
    }
    final dir = Directory(binDir)..createSync(recursive: true);
    final exe = '${dir.path}/$fileName';
    if (!File(exe).existsSync()) {
      final src = File('${dir.path}/perch_mac_helper.swift')..writeAsStringSync(helperSource);
      try {
        final r = await _run('/usr/bin/swiftc', ['-O', src.path, '-o', exe]);
        if (r.exitCode != 0 || !File(exe).existsSync()) return null;
      } catch (_) {
        return null;
      }
    }
    return _path = exe;
  }

  Future<RunResult?> _call(List<String> args) async {
    final exe = await path();
    if (exe == null) return null;
    try {
      return await _run(exe, args);
    } catch (_) {
      return null;
    }
  }

  /// Whether the host may post keys and read other apps' windows.
  Future<bool> trusted() async => (await _call(['trusted']))?.stdout.trim() == 'yes';

  /// Posts [steps] to app [pid]; true when the helper says ok.
  Future<bool> post(int pid, List<KeyStep> steps) async {
    if (steps.isEmpty) return true;
    final r = await _call(['post', '$pid', ...steps.map((s) => s.arg)]);
    return r != null && r.exitCode == 0 && r.stdout.trim() == 'ok';
  }

  /// The app's windows, front first; null when they cannot be read.
  Future<List<AxWindow>?> windows(int pid) async {
    final r = await _call(['windows', '$pid']);
    if (r == null || r.exitCode != 0) return null;
    return parseWindows(r.stdout);
  }

  static List<AxWindow>? parseWindows(String out) {
    try {
      final j = jsonDecode(out.trim());
      if (j is! List) return null;
      return [
        for (final w in j)
          if (w is Map) AxWindow('${w['title'] ?? ''}', '${w['text'] ?? ''}')
      ];
    } catch (_) {
      return null;
    }
  }

  /// The app's window titles, front first; null when they cannot be read.
  Future<List<String>?> titles(int pid) async {
    final r = await _call(['titles', '$pid']);
    if (r == null || r.exitCode != 0) return null;
    try {
      final j = jsonDecode(r.stdout.trim());
      return j is List ? [for (final t in j) '$t'] : null;
    } catch (_) {
      return null;
    }
  }

  /// Sets terminal [tty]'s title to [marker] and returns which of app [pid]'s windows
  /// (front first) then shows it (null: none) and the titles just before; null when the
  /// helper cannot run. Writing and watching in one process beats a busy session's spinner.
  Future<({int? index, List<String> before})?> mark(int pid, String tty, String marker) async {
    final r = await _call(['mark', '$pid', tty, marker]);
    if (r == null || r.exitCode != 0) return null;
    try {
      final j = jsonDecode(r.stdout.trim()) as Map<String, dynamic>;
      final i = (j['index'] as num).toInt();
      return (index: i < 0 ? null : i, before: [for (final t in j['before'] as List) '$t']);
    } catch (_) {
      return null;
    }
  }

  /// Raises window [index] (front first) to the front of its app, without activating the app.
  Future<bool> raise(int pid, int index) async {
    final r = await _call(['raise', '$pid', '$index']);
    return r != null && r.exitCode == 0 && r.stdout.trim() == 'ok';
  }
}

/// The helper's Swift source.
const helperSource = r'''
// Perch's macOS helper (written and compiled by the Perch host).
//   trusted                 yes or no: may this process use Accessibility
//   post <pid> <step>...    t:<base64 UTF-8> types text, k:<code>[:<flags>] presses a key,
//                           d:<ms> waits; prints ok
//   windows <pid>           JSON array, front window first: {"title", "text"}
//   titles <pid>            JSON array of the window titles, front first
//   mark <pid> <tty> <title>  sets that terminal's title (OSC 0) and watches the window
//                           titles for it for up to 0.5 s; prints {"index", "before"}
//                           (index -1: not shown in front in any window)
//   raise <pid> <index>     raises that window within its app; prints ok
import ApplicationServices
import CoreGraphics
import Foundation

func fail(_ why: String) -> Never { print("error \(why)"); exit(1) }
let a = CommandLine.arguments
guard a.count >= 2 else { fail("usage") }
if a[1] == "trusted" { print(AXIsProcessTrusted() ? "yes" : "no"); exit(0) }
guard a.count >= 3, let p = Int32(a[2]) else { fail("usage") }
if !AXIsProcessTrusted() { fail("not-trusted") }
let pid = pid_t(p)

func post(_ key: CGKeyCode, _ flags: UInt64, _ text: [UInt16]?) {
  for down in [true, false] {
    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { fail("event") }
    e.flags = CGEventFlags(rawValue: flags)
    if var t = text { e.keyboardSetUnicodeString(stringLength: t.count, unicodeString: &t) }
    e.postToPid(pid)
  }
  usleep(6000)
}

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
  var v: AnyObject?
  return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func windows() -> [AXUIElement] {
  let app = AXUIElementCreateApplication(pid)
  return (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

func textOf(_ e: AXUIElement, _ depth: Int) -> String? {
  if (attr(e, kAXRoleAttribute) as? String) == (kAXTextAreaRole as String) { return attr(e, kAXValueAttribute) as? String }
  if depth > 4 { return nil }
  for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
    if let t = textOf(c, depth + 1) { return t }
  }
  return nil
}

switch a[1] {
case "post":
  for step in a.dropFirst(3) {
    let body = String(step.dropFirst(2))
    if step.hasPrefix("t:") {
      guard let d = Data(base64Encoded: body), let s = String(data: d, encoding: .utf8) else { fail("text") }
      for ch in s { post(0, 0, Array(String(ch).utf16)) }
    } else if step.hasPrefix("k:") {
      let parts = body.split(separator: ":")
      guard let k = UInt16(parts[0]) else { fail("key") }
      post(CGKeyCode(k), parts.count > 1 ? UInt64(parts[1]) ?? 0 : 0, nil)
    } else if step.hasPrefix("d:") {
      usleep(useconds_t((Int(body) ?? 0) * 1000))
    } else { fail("step") }
  }
  print("ok")
case "windows":
  var out: [[String: String]] = []
  for w in windows() {
    var text = textOf(w, 0) ?? ""
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count > 400 { text = lines.suffix(400).joined(separator: "\n") }
    out.append(["title": (attr(w, kAXTitleAttribute) as? String) ?? "", "text": text])
  }
  let data = try! JSONSerialization.data(withJSONObject: out)
  print(String(data: data, encoding: .utf8)!)
case "titles":
  let titles = windows().map { (attr($0, kAXTitleAttribute) as? String) ?? "" }
  let data = try! JSONSerialization.data(withJSONObject: titles)
  print(String(data: data, encoding: .utf8)!)
case "mark":
  guard a.count >= 5, let tty = FileHandle(forWritingAtPath: a[3]) else { fail("usage") }
  let marker = a[4]
  let before = windows().map { (attr($0, kAXTitleAttribute) as? String) ?? "" }
  tty.write(Data("\u{1b}]0;\(marker)\u{1b}\\".utf8))
  try? tty.close()
  var index = -1
  for _ in 0..<25 {
    let now = windows().map { (attr($0, kAXTitleAttribute) as? String) ?? "" }
    if let i = now.firstIndex(of: marker) { index = i; break }
    usleep(20000)
  }
  let data = try! JSONSerialization.data(withJSONObject: ["index": index, "before": before] as [String: Any])
  print(String(data: data, encoding: .utf8)!)
case "raise":
  guard a.count >= 4, let i = Int(a[3]) else { fail("usage") }
  let ws = windows()
  guard i >= 0 && i < ws.count else { fail("no-window") }
  if AXUIElementPerformAction(ws[i], kAXRaiseAction as CFString) != .success { fail("raise") }
  print("ok")
default:
  fail("usage")
}
''';
