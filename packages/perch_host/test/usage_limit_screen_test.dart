// Reading Claude Code's usage-limit lines. Every screen here is SYNTHETIC: built from the
// wording in Claude Code's docs (interactive-mode "Wait for a usage limit to reset",
// errors "You've hit your session limit", commands "/rate-limit-options"), not copied
// from a real session; no real limit was spent to make them.
import 'dart:io';

import 'package:perch_host/src/dialog_screen.dart';
import 'package:perch_host/src/terminal_prompts.dart' show screenPrompt;
import 'package:perch_host/src/usage_limits.dart';
import 'package:perch_protocol/perch_protocol.dart';
import 'package:test/test.dart';

const rule = '────────────────────────────────────────────────────────────────────────────';

/// SYNTHETIC: Claude Code waiting to continue by itself.
const waitingScreen = '''
● I'll write the docs for each module now.

● Agent(Write module docs)
  ⎿  You've hit your session limit · resets 3:45pm

$rule
❯
$rule
  Usage limit reached · limit resets 3:45pm · /usage for details
  Continuing automatically at 3:45pm · Esc to cancel · /usage-credits to continue now
''';

/// SYNTHETIC: the reset passed, Claude Code is about to continue.
const shortlyScreen = '''
$rule
❯
$rule
  Usage limit reached · limit resets 3:45pm
  Continuing shortly · Esc to cancel
''';

/// SYNTHETIC: the reset passed while the computer slept.
const staleScreen = '''
$rule
❯
$rule
  Your usage limit has reset
  Press enter to continue
''';

/// SYNTHETIC: after Esc.
const cancelledScreen = '''
● Agent(Write module docs)
  ⎿  You've hit your session limit · resets 3:45pm

  Automatic continue cancelled · send a message to continue

$rule
❯
$rule
''';

/// SYNTHETIC: the usage-limit options menu (weekly limit: Claude Code does not wait).
const menuScreen = '''
● You've hit your weekly limit · resets Mon 12:00am

$rule
 Usage limit reached · limit resets Mon 12:00am

 What would you like to do?

 ❯ 1. Wait here, then continue automatically at Mon 12:00am
   2. Add usage credits
   3. Upgrade your plan
   4. Don't continue automatically

 Enter to confirm · Esc to cancel
''';

/// SYNTHETIC: a limit screen in words Perch does not know (a future Claude Code).
const strangeScreen = '''
$rule
❯
$rule
  Usage limit reached · back at a quarter to four
''';

void main() {
  // Sunday 15 November 2026, 13:00 on the machine's clock.
  final now = DateTime(2026, 11, 15, 13, 0);

  group('reset times', () {
    test('a clock time today', () {
      expect(parseResetTime('3:45pm', now), DateTime(2026, 11, 15, 15, 45));
      expect(parseResetTime('3pm', now), DateTime(2026, 11, 15, 15, 0));
      expect(parseResetTime('3:45 PM', now), DateTime(2026, 11, 15, 15, 45));
      expect(parseResetTime('15:45', now), DateTime(2026, 11, 15, 15, 45));
    });

    test('a clock time already past is tomorrow', () {
      expect(parseResetTime('9am', now), DateTime(2026, 11, 16, 9, 0));
      expect(parseResetTime('12:00am', now), DateTime(2026, 11, 16, 0, 0));
    });

    test('a weekday and a date', () {
      expect(parseResetTime('Mon 12:00am', now), DateTime(2026, 11, 16, 0, 0));
      expect(parseResetTime('Sun 2pm', now), DateTime(2026, 11, 15, 14, 0));
      expect(parseResetTime('Sun 9am', now), DateTime(2026, 11, 22, 9, 0));
      expect(parseResetTime('Nov 20, 5pm', now), DateTime(2026, 11, 20, 17, 0));
      expect(parseResetTime('Jan 2 9am', now), DateTime(2027, 1, 2, 9, 0));
    });

    test('a time zone in brackets is the machine\'s and is left out', () {
      expect(parseResetTime('3:45pm (Asia/Calcutta)', now), DateTime(2026, 11, 15, 15, 45));
    });

    test('words that are not a time give nothing', () {
      expect(parseResetTime('soon', now), isNull);
      expect(parseResetTime('', now), isNull);
      expect(parseResetTime('25:99', now), isNull);
    });
  });

  group('the messages', () {
    test('the error line names the window and the reset', () {
      final m = parseLimitMessage("You've hit your session limit · resets 3:45pm", now)!;
      expect(m.window, LimitWindows.fiveHour);
      expect(m.resetsAt, DateTime(2026, 11, 15, 15, 45));
      expect(parseLimitMessage("You’ve hit your weekly limit · resets Mon 12:00am", now)!.window, LimitWindows.sevenDay);
      expect(parseLimitMessage("You've hit your Opus limit · resets 6pm", now)!.window, LimitWindows.opus);
      expect(parseLimitMessage("You've hit your Sonnet limit · resets 6pm", now)!.window, LimitWindows.sonnet);
    });

    test('the conversation line of a wait', () {
      final m = parseLimitMessage('Usage limit reached · continuing automatically at 3:45pm · esc to cancel', now)!;
      expect(m.resetsAt, DateTime(2026, 11, 15, 15, 45));
      expect(m.claudeWaiting, isTrue);
    });

    test('ordinary text is not a limit', () {
      expect(parseLimitMessage('I hit a rate limit in the test, retrying', now), isNull);
      expect(parseLimitMessage("You've used 85% of your session limit · resets 3:45pm", now), isNull);
    });

    test('a limit message without a time still counts, with no reset', () {
      final m = parseLimitMessage("You've hit your session limit", now)!;
      expect(m.resetsAt, isNull);
      expect(m.window, LimitWindows.fiveHour);
    });
  });

  group('the screen', () {
    test('waiting to continue by itself', () {
      final r = readLimitScreen(waitingScreen, now);
      expect(r.kind, LimitScreenKind.waiting);
      expect(r.resetsAt, DateTime(2026, 11, 15, 15, 45));
      expect(r.window, LimitWindows.fiveHour);
      expect(r.claudeWaiting, isTrue);
    });

    test('continuing shortly, slept, cancelled', () {
      expect(readLimitScreen(shortlyScreen, now).kind, LimitScreenKind.continuingShortly);
      expect(readLimitScreen(staleScreen, now).kind, LimitScreenKind.stale);
      expect(readLimitScreen(cancelledScreen, now).kind, LimitScreenKind.cancelled);
      expect(readLimitScreen(cancelledScreen, now).claudeWaiting, isFalse);
    });

    test('the options menu: Claude Code is not waiting', () {
      final r = readLimitScreen(menuScreen, now);
      expect(r.kind, LimitScreenKind.menu);
      expect(r.claudeWaiting, isFalse);
      expect(r.resetsAt, DateTime(2026, 11, 16, 0, 0));
      expect(r.window, LimitWindows.sevenDay);
      expect(isUsageLimitMenu(menuScreen), isTrue);
      expect(limitMenuOption(menuScreen, dontContinue)!.number, 4);
    });

    test('the REAL menu of an organization account (Mac, 2.1.326) is the options menu, not a permission', () {
      final real = File('test${Platform.pathSeparator}fixtures${Platform.pathSeparator}screens'
              '${Platform.pathSeparator}rate_limit_options_org_real.txt')
          .readAsStringSync();
      expect(isUsageLimitMenu(real), isTrue);
      expect(readLimitScreen(real, now).kind, LimitScreenKind.menu);
      expect(limitMenuOption(real, dontContinue), isNull);
      expect(screenDrift(real), isNull);
      // Seen on Windows (2.1.327): the menu typed at the terminal became a permission card
      // ("What do you want to do?") on the phone.
      expect(screenPrompt(real, 's'), isNull);
    });

    test('a screen with no limit', () {
      expect(readLimitScreen('$rule\n❯ \n$rule\n', now).kind, LimitScreenKind.none);
      expect(mentionsUsageLimit('$rule\n❯ \n$rule\n'), isFalse);
    });

    test('limit words Perch cannot read are noticed, not guessed', () {
      final r = readLimitScreen(strangeScreen, now);
      expect(r.kind, LimitScreenKind.unreadable);
      expect(r.resetsAt, isNull);
      expect(mentionsUsageLimit(strangeScreen), isTrue);
    });
  });

  group('the dialog reader is not fooled by the waiting lines', () {
    test('Esc to cancel under the input box is not a dialog', () {
      expect(screenDrift(waitingScreen), isNull);
      expect(screenDrift(shortlyScreen), isNull);
      expect(detectDialog(waitingScreen), DialogKind.none);
      expect(isPromptReady(waitingScreen), isTrue);
      expect(isPromptReady(cancelledScreen), isTrue);
    });

    // Shapes seen live on Claude Code 2.1.325 (Windows console); the text is made up.
    test('idle means the box and no "esc to interrupt" under it', () {
      const status = '  ⏵⏵ auto mode on (shift+tab to cycle) · ← 3 agents';
      const idle = '● Done.\n✻ Worked for 5s\n$rule\n❯ Try "write a test"\n$rule\n$status\n';
      const working = '❯ Write an essay.\n✻ Dilly-dallying…\n$rule\n❯\n$rule\n'
          '  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← 3 agents\n';
      const talksAboutIt = '  The check now requires that no "esc to interrupt" line is showing.\n$rule\n❯\n$rule\n$status\n';
      expect(isIdlePrompt(idle), isTrue);
      expect(isPromptReady(working), isTrue, reason: 'the box is drawn for typing ahead');
      expect(isIdlePrompt(working), isFalse);
      expect(isIdlePrompt(talksAboutIt), isTrue, reason: "Claude's words above the box do not count");
    });

    test('the options menu is a known dialog, not drift, and not a prompt', () {
      expect(screenDrift(menuScreen), isNull);
      expect(isPromptReady(menuScreen), isFalse);
    });
  });
}
