import 'package:flutter/widgets.dart';

import 'app_state.dart';

/// UI text in Indonesian (default) and English. Route data, labels and the search
/// explanation come from the API already translated (Accept-Language).
const Map<String, List<String>> _strings = {
  'app.name': ['RuteStrip', 'RuteStrip'],
  'lang.toggle': ['Bahasa', 'Language'],
  'home.question': ['Jalur seperti apa yang kamu cari?', 'What kind of trail are you looking for?'],
  'home.lead': [
    'Tulis dengan bahasa sehari-hari: nama gunung, berapa lama mau jalan, atau seberapa curam jalurnya.',
    'Write it the way you would say it: a mountain, how long you want to walk, or how steep the trail can be.',
  ],
  'search.label': ['Cari jalur', 'Search trails'],
  'search.hint': ['Misalnya: jalur landai untuk pemula', 'For example: gentle trail for beginners'],
  'search.button': ['Cari jalur', 'Find trails'],
  'search.busy': ['Mencari jalur...', 'Searching...'],
  'search.too_short': ['Tulis minimal 3 huruf.', 'Write at least 3 characters.'],
  'search.examples': ['Contoh pencarian', 'Example searches'],
  'browse.title': ['Semua jalur', 'All trails'],
  'browse.cta': ['Lihat semua jalur', 'See all trails'],
  'browse.count': ['{n} jalur di Pulau Jawa, bisa dipilah per gunung atau provinsi.', '{n} trails on Java, sorted by mountain or province.'],
  'n.trail': ['{n} jalur', '{n} trail'],
  'n.trails': ['{n} jalur', '{n} trails'],
  'browse.mountain': ['Gunung', 'Mountain'],
  'browse.province': ['Provinsi', 'Province'],
  'browse.all': ['Semua', 'All'],
  'browse.empty': ['Belum ada jalur dengan pilihan ini.', 'No trails match this choice yet.'],
  'browse.reset': ['Hapus pilihan', 'Clear choice'],
  'browse.more': ['Memuat jalur berikutnya...', 'Loading more trails...'],
  'results.for': ['Hasil pencarian untuk', 'Search results for'],
  'results.one': ['Ada 1 jalur yang cocok.', 'There is 1 matching trail.'],
  'results.many': ['Ini {n} jalur yang paling cocok. Yang paling atas paling pas.', 'These are the {n} closest trails. The top one fits best.'],
  'results.empty.title': ['Belum ketemu jalur yang pas.', 'No good match yet.'],
  'results.empty.body': [
    'Coba tulis dengan cara lain. Sebut nama gunung, berapa lama mau jalan, atau seberapa curam jalurnya.',
    'Try saying it another way. Name a mountain, how long you want to walk, or how steep it can be.',
  ],
  'results.rank': ['Urutan', 'Rank'],
  'stat.distance': ['Jarak', 'Distance'],
  'stat.gain': ['Total naik', 'Total climb'],
  'stat.grade': ['Kemiringan rata-rata', 'Average slope'],
  'stat.steepest': ['Bagian paling curam', 'Steepest stretch'],
  'stat.summit': ['Titik tertinggi', 'Highest point'],
  'stat.difficulty': ['Tingkat kesulitan', 'Difficulty'],
  'time.hm': ['{h} j {m} mnt', '{h} h {m} min'],
  'detail.map': ['Peta jalur', 'Trail map'],
  'detail.map.open': ['Buka peta penuh', 'Open full map'],
  'detail.basecamp': ['Basecamp', 'Trailhead'],
  'detail.summit': ['Puncak', 'Summit'],
  'detail.profile': ['Profil ketinggian', 'Elevation profile'],
  'detail.profile.none': [
    'File GPX jalur ini tidak menyimpan ketinggian, jadi profilnya belum bisa digambar.',
    'This trail\'s GPX file has no elevation data, so the profile cannot be drawn yet.',
  ],
  'detail.profile.sr': [
    'Profil ketinggian: dari {from} m ke titik tertinggi {top} m sepanjang {km} km.',
    'Elevation profile: from {from} m to a high point of {top} m over {km} km.',
  ],
  'detail.about': ['Tentang jalur', 'About this trail'],
  'detail.similar': ['Jalur yang mirip', 'Similar trails'],
  'detail.similar.none': ['Belum ada jalur lain yang mirip.', 'No similar trails yet.'],
  'detail.web': ['Buka di rutestrip.ai.id', 'Open on rutestrip.ai.id'],
  'detail.no_track': ['Jalur ini belum punya jejak GPS untuk peta.', 'This trail has no GPS track to map yet.'],
  'like.add': ['Suka', 'Like'],
  'like.remove': ['Disukai', 'Liked'],
  'like.login': ['Masuk dulu untuk menyukai jalur.', 'Log in to like trails.'],
  'like.login.action': ['Masuk', 'Log in'],
  'like.count': ['{n} suka', '{n} likes'],
  'state.loading': ['Memuat...', 'Loading...'],
  'state.retry': ['Coba lagi', 'Try again'],
  'error.network': [
    'Tidak bisa terhubung ke RuteStrip. Periksa koneksi internet, lalu coba lagi.',
    'Cannot reach RuteStrip. Check your connection and try again.',
  ],
  'error.server': ['Server sedang bermasalah. Coba lagi sebentar lagi.', 'The server has a problem right now. Try again in a moment.'],
  'error.throttled': ['Terlalu banyak permintaan. Tunggu sebentar, lalu coba lagi.', 'Too many requests. Wait a moment and try again.'],
  'error.not_found': ['Jalur ini tidak ditemukan. Mungkin sudah dihapus.', 'This trail was not found. It may have been removed.'],
  'account': ['Akun', 'Account'],
  'login': ['Masuk', 'Log in'],
  'login.title': ['Masuk ke RuteStrip', 'Log in to RuteStrip'],
  'login.lead': ['Akun yang sama dengan situs dan chat RuteStrip.', 'The same account as the RuteStrip site and chat.'],
  'login.button': ['Masuk', 'Log in'],
  'login.busy': ['Sedang masuk...', 'Logging in...'],
  'login.to_register': ['Belum punya akun? Daftar', 'No account yet? Sign up'],
  'register': ['Daftar', 'Sign up'],
  'register.title': ['Buat akun', 'Create an account'],
  'register.button': ['Buat akun', 'Create account'],
  'register.busy': ['Membuat akun...', 'Creating account...'],
  'register.check': ['Memeriksa bahwa kamu bukan robot...', 'Checking that you are not a robot...'],
  'register.to_login': ['Sudah punya akun? Masuk', 'Have an account? Log in'],
  'field.name': ['Nama', 'Name'],
  'field.email': ['Email', 'Email'],
  'field.password': ['Kata sandi', 'Password'],
  'field.password2': ['Ulangi kata sandi', 'Repeat password'],
  'field.required': ['Kolom ini wajib diisi.', 'This field is required.'],
  'field.email_bad': ['Tulis alamat email yang benar.', 'Enter a valid email address.'],
  'field.password_short': ['Kata sandi minimal 8 karakter.', 'Password needs at least 8 characters.'],
  'field.password_mismatch': ['Kedua kata sandi belum sama.', 'The two passwords do not match.'],
  'field.show': ['Tampilkan kata sandi', 'Show password'],
  'field.hide': ['Sembunyikan kata sandi', 'Hide password'],
  'account.likes': ['Jalur yang kamu suka', 'Trails you like'],
  'account.likes.empty': ['Belum ada. Ketuk Suka di halaman jalur untuk menyimpannya di sini.', 'None yet. Tap Like on a trail page to keep it here.'],
  'account.logout': ['Keluar', 'Log out'],
  'account.welcome': ['Halo, {name}', 'Hi, {name}'],
};

String tr(BuildContext context, String key, [Map<String, Object?> params = const {}]) {
  final lang = AppScope.of(context).lang;
  return trLang(lang, key, params);
}

String trLang(String lang, String key, [Map<String, Object?> params = const {}]) {
  final pair = _strings[key];
  var text = pair == null ? key : pair[lang == 'en' ? 1 : 0];
  params.forEach((k, v) => text = text.replaceAll('{$k}', '$v'));
  return text;
}

/// Numbers as the site prints them: 1.424 and 12,8 in Indonesian, 1,424 and 12.8 in English.
String fmtNum(BuildContext context, num? value, [int decimals = 0]) {
  if (value == null) return '-';
  final en = AppScope.of(context).lang == 'en';
  final fixed = value.toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final intPart = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => en ? ',' : '.');
  return parts.length > 1 ? '$intPart${en ? '.' : ','}${parts[1]}' : intPart;
}

String fmtHours(BuildContext context, double? hours) {
  if (hours == null) return '-';
  var h = hours.floor();
  var m = ((hours - h) * 60).round();
  if (m == 60) {
    h++;
    m = 0;
  }
  return tr(context, 'time.hm', {'h': h, 'm': m});
}

String trailCount(BuildContext context, int n) => tr(context, n == 1 ? 'n.trail' : 'n.trails', {'n': fmtNum(context, n)});
