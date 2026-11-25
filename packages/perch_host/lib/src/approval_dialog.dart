// The second check when a new device pairs: a dialog on the machine's desktop with
// Allow / Watch only / Deny. The console keys, the CLI and a full-control device can decide
// the same request; whichever answers first wins and the dialog is closed.
//
// macOS: `osascript display dialog`, its answer read from stdout. Windows: a PowerShell
// WinForms window (plain ASCII script, like the console helpers). Other systems: none.
// Test hosts turn it off with PERCH_APPROVAL_DIALOG=0.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:perch_protocol/perch_protocol.dart';

/// One dialog on screen: [decision] completes with a [DeviceDecisions] value, or null when
/// it gave up, was closed or failed; [cancel] closes it.
class ApprovalPrompt {
  final Future<String?> decision;
  final void Function() cancel;
  ApprovalPrompt(this.decision, this.cancel);
}

abstract class ApprovalPrompter {
  ApprovalPrompt show({required String machineName, required PendingDevice request});
}

/// How a request reached the machine, in words.
String routeText(String route) => route == 'relay' ? 'over the relay' : 'from $route';

/// The short code shown for a device: the first 4 characters of its id.
String shortDeviceId(String id) => id.length <= 4 ? id : id.substring(0, 4);

/// The dialog's question.
String approvalText(String machineName, PendingDevice r) =>
    'A new device "${r.name}" (${shortDeviceId(r.id)}, ${routeText(r.route)}) wants to pair with $machineName.\n\n'
    'Allow: full control of Claude Code here. Watch only: it can see sessions but not act. '
    'Deny if you did not just scan the pairing code.';

/// Off with PERCH_APPROVAL_DIALOG=0 (test hosts).
bool approvalDialogEnabled(Map<String, String> env) => env['PERCH_APPROVAL_DIALOG'] != '0';

/// Seconds before the dialog gives up (the request stays pending): PERCH_APPROVAL_DIALOG_SECONDS
/// or 300.
int approvalDialogSeconds(Map<String, String> env) {
  final v = int.tryParse(env['PERCH_APPROVAL_DIALOG_SECONDS'] ?? '');
  return v != null && v > 0 ? v : 300;
}

String _appleQuote(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// The osascript line for [text].
String macDialogScript(String text, int seconds) =>
    'display dialog ${_appleQuote(text)} buttons {"Deny", "Watch only", "Allow"} default button "Deny" '
    'with title "Perch" with icon caution giving up after $seconds';

/// `button returned:Allow, gave up:false` → `full`; a give-up or anything else → null.
String? parseMacDialog(String out) {
  if (RegExp(r'gave up:\s*true').hasMatch(out)) return null;
  final m = RegExp(r'button returned:([^,\n]*)').firstMatch(out);
  return switch (m?.group(1)?.trim()) {
    'Allow' => DeviceDecisions.full,
    'Watch only' => DeviceDecisions.watch,
    'Deny' => DeviceDecisions.deny,
    _ => null,
  };
}

String _ascii(String s) => String.fromCharCodes(s.runes.map((r) => r >= 32 && r < 127 ? r : (r == 10 ? 10 : 63)));

String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

/// The PowerShell script for Windows (plain ASCII: Windows PowerShell 5.1 reads a script
/// without a byte-order mark as ANSI). Prints `decision:<full|watch|deny>` or `decision:`.
String windowsDialogScript(String text, int seconds) {
  final msg = _psQuote(_ascii(text)).replaceAll('\n', "' + [char]10 + '");
  return [
    'Add-Type -AssemblyName System.Windows.Forms',
    r'$f = New-Object System.Windows.Forms.Form',
    r"$f.Text = 'Perch'; $f.TopMost = $true; $f.Width = 480; $f.Height = 230",
    r"$f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false",
    r'$l = New-Object System.Windows.Forms.Label; $l.SetBounds(14, 12, 440, 110)',
    '\$l.Text = $msg; \$f.Controls.Add(\$l)',
    r"$script:r = ''",
    r"foreach ($b in @(@('Deny', 'deny', 14), @('Watch only', 'watch', 170), @('Allow', 'full', 326))) {",
    r'  $btn = New-Object System.Windows.Forms.Button; $btn.Text = $b[0]; $btn.Tag = $b[1]; $btn.SetBounds($b[2], 135, 130, 32)',
    r'  $btn.Add_Click({ $script:r = $this.Tag; $f.Close() }); $f.Controls.Add($btn)',
    '}',
    r'$t = New-Object System.Windows.Forms.Timer',
    '\$t.Interval = ${seconds * 1000}; \$t.Add_Tick({ \$f.Close() }); \$t.Start()',
    r'[void]$f.ShowDialog()',
    r"Write-Output ('decision:' + $script:r)",
  ].join('\n');
}

String? parseWindowsDialog(String out) {
  final m = RegExp(r'decision:(\w*)').firstMatch(out);
  final d = m?.group(1) ?? '';
  return DeviceDecisions.all.contains(d) ? d : null;
}

/// The real dialog. Failures are logged to stderr and count as no answer.
class OsApprovalDialog implements ApprovalPrompter {
  final int seconds;
  OsApprovalDialog({this.seconds = 300});

  @override
  ApprovalPrompt show({required String machineName, required PendingDevice request}) {
    final text = approvalText(machineName, request);
    final done = Completer<String?>();
    Process? proc;
    var cancelled = false;
    Future<void> run() async {
      try {
        final String exe;
        final List<String> args;
        final String? Function(String) parse;
        if (Platform.isMacOS) {
          exe = 'osascript';
          args = ['-e', macDialogScript(text, seconds)];
          parse = parseMacDialog;
        } else if (Platform.isWindows) {
          exe = 'powershell';
          args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', windowsDialogScript(text, seconds)];
          parse = parseWindowsDialog;
        } else {
          if (!done.isCompleted) done.complete(null);
          return;
        }
        final p = proc = await Process.start(exe, args);
        if (cancelled) p.kill();
        final out = p.stdout.transform(utf8.decoder).join();
        final err = p.stderr.transform(utf8.decoder).join();
        final code = await p.exitCode;
        final answer = await out;
        if (code != 0 && !cancelled) {
          final e = (await err).trim();
          if (e.isNotEmpty && !e.contains('User canceled')) stderr.writeln('Approval dialog: $e');
        }
        if (!done.isCompleted) done.complete(cancelled ? null : parse(answer));
      } catch (e) {
        stderr.writeln('Approval dialog failed: $e');
        if (!done.isCompleted) done.complete(null);
      }
    }

    unawaited(run());
    return ApprovalPrompt(done.future, () {
      cancelled = true;
      proc?.kill();
      if (!done.isCompleted) done.complete(null);
    });
  }
}
