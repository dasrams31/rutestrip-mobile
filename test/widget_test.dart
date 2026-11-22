import 'package:flutter_test/flutter_test.dart';
import 'package:rutestrip/i18n.dart';

void main() {
  test('UI text exists in both languages', () {
    expect(trLang('id', 'search.button'), 'Cari jalur');
    expect(trLang('en', 'search.button'), 'Find trails');
    expect(trLang('en', 'time.hm', {'h': 5, 'm': 54}), '5 h 54 min');
  });
}
