// Times shown in the app are India Standard Time (UTC+05:30, no daylight saving),
// whatever the phone's own timezone.

const _ist = Duration(hours: 5, minutes: 30);
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _two(int n) => n.toString().padLeft(2, '0');

/// [utcMs] (milliseconds since the epoch) as an IST wall-clock time: `HH:mm` when it falls
/// on today's IST date ([now], default the current time), else `d MMM HH:mm`
/// (`14 Nov 21:11`). 24-hour clock.
String formatIst(int utcMs, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true).add(_ist);
  final n = (now ?? DateTime.now()).toUtc().add(_ist);
  final clock = '${_two(t.hour)}:${_two(t.minute)}';
  final today = t.year == n.year && t.month == n.month && t.day == n.day;
  return today ? clock : '${t.day} ${_months[t.month - 1]} $clock';
}
