/// Ebeveynin Firestore'daki `child_policies` belgesine göre yerel kilit (uyku / ders saati).
class PolicyEvaluator {
  PolicyEvaluator._();

  static bool isQuietHoursLocked(Map<String, dynamic>? m) {
    if (m == null) return false;
    final now = DateTime.now();
    final wd = now.weekday;

    final weekdays =
        List<int>.from(m['schoolWeekdays'] ?? const [1, 2, 3, 4, 5]);
    final ss = m['schoolBlockStart'] as String?;
    final se = m['schoolBlockEnd'] as String?;
    if (ss != null && se != null && weekdays.contains(wd)) {
      if (_minutesInRange(now, ss, se)) return true;
    }

    final bs = m['bedTimeStart'] as String?;
    final be = m['bedTimeEnd'] as String?;
    if (bs != null && be != null && _bedLocked(now, bs, be)) return true;

    return false;
  }

  static int? _parseMinutes(String s) {
    final p = s.trim().split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]);
    final min = int.tryParse(p[1]);
    if (h == null || min == null) return null;
    return h * 60 + min;
  }

  static int _nowMinutes(DateTime d) => d.hour * 60 + d.minute;

  static bool _minutesInRange(DateTime now, String start, String end) {
    final a = _parseMinutes(start);
    final b = _parseMinutes(end);
    if (a == null || b == null) return false;
    final n = _nowMinutes(now);
    if (a <= b) return n >= a && n <= b;
    return n >= a || n <= b;
  }

  static bool _bedLocked(DateTime now, String start, String end) {
    return _minutesInRange(now, start, end);
  }
}
