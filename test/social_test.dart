import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rutestrip/api.dart';
import 'package:rutestrip/app_state.dart';
import 'package:rutestrip/outbox.dart';
import 'package:rutestrip/theme.dart';
import 'package:rutestrip/widgets/common.dart';
import 'package:rutestrip/widgets/social.dart';

/// The Post JSON from the shared contract (D:\dev\notes\social_api.md).
Map<String, Object?> contractPost() => {
  'id': 12,
  'type': 'recording',
  'body': 'Merbabu via Selo, cerah sampai puncak',
  'photo_url': 'https://rutestrip.ai.id/storage/posts/ab12.jpg',
  'track': [
    [-7.45, 110.43],
    [-7.44, 110.435],
    [-7.43, 110.44],
  ],
  'stats': {'distance_km': 9.4, 'gain_m': 1320, 'moving_s': 18600},
  'place': {'lat': -7.45, 'lng': 110.43, 'label': 'Sumber air'},
  'route': {'id': 21, 'name': 'Mt. Merbabu via Selo'},
  'author': {'id': 3, 'name': 'Rama', 'bio': 'Pendaki akhir pekan'},
  'likes_count': 4,
  'comments_count': 2,
  'liked': true,
  'saved': false,
  'is_mine': false,
  'created_at': '2026-11-22T08:30:00+07:00',
  'expires_at': null,
  'share_url': 'https://rutestrip.ai.id/p/12',
};

class _MemoryStore implements OutboxStore {
  List<PostDraft> saved = [];

  @override
  Future<List<PostDraft>> load() async => [for (final d in saved) PostDraft.fromJson(d.toJson())];

  @override
  Future<void> save(List<PostDraft> items) async => saved = [for (final d in items) PostDraft.fromJson(d.toJson())];

  @override
  Future<String> keepPhoto(String path, String clientId) async => '/docs/outbox/$clientId.jpg';

  @override
  Future<void> dropPhoto(String? path) async {}
}

void main() {
  group('contract JSON', () {
    test('a full recording post', () {
      final p = Post.fromJson(contractPost());
      expect(p.id, 12);
      expect(p.type, 'recording');
      expect(p.track, hasLength(3));
      expect(p.track!.first, [-7.45, 110.43]);
      expect(p.stats!.distanceKm, 9.4);
      expect(p.stats!.gainM, 1320);
      expect(p.stats!.movingS, 18600);
      expect(p.place!.label, 'Sumber air');
      expect(p.routeId, 21);
      expect(p.routeName, 'Mt. Merbabu via Selo');
      expect(p.author.name, 'Rama');
      expect(p.author.bio, 'Pendaki akhir pekan');
      expect(p.liked, isTrue);
      expect(p.saved, isFalse);
      expect(p.createdAt!.toUtc(), DateTime.utc(2026, 11, 22, 1, 30));
      expect(p.expiresAt, isNull);
      expect(p.shareUrl, 'https://rutestrip.ai.id/p/12');
    });

    test('a status post with every optional field null', () {
      final p = Post.fromJson({
        ...contractPost(),
        'type': 'status',
        'body': null,
        'photo_url': null,
        'track': null,
        'stats': null,
        'place': null,
        'route': null,
        'author': {'id': 5, 'name': 'Sari', 'bio': null},
        'expires_at': null,
      });
      expect(p.body, isNull);
      expect(p.photoUrl, isNull);
      expect(p.track, isNull);
      expect(p.stats, isNull);
      expect(p.place, isNull);
      expect(p.routeId, isNull);
      expect(p.author.bio, isNull);
    });

    test('a story with an expiry', () {
      final p = Post.fromJson({...contractPost(), 'type': 'story', 'expires_at': '2026-11-23T08:30:00+07:00'});
      expect(p.expiresAt!.toUtc(), DateTime.utc(2026, 11, 23, 1, 30));
    });

    test('pages, comments, profiles, users and stories', () {
      final page = SocialPage.fromJson({
        'data': [contractPost()],
        'next_cursor': 'eyJpZCI6MTJ9',
      }, Post.fromJson);
      expect(page.items.single.id, 12);
      expect(page.nextCursor, 'eyJpZCI6MTJ9');
      final last = SocialPage.fromJson({'data': [], 'next_cursor': null}, Post.fromJson);
      expect(last.items, isEmpty);
      expect(last.nextCursor, isNull);

      final c = Comment.fromJson({
        'id': 7,
        'body': 'Airnya masih ada?',
        'author': {'id': 4, 'name': 'Dewi'},
        'created_at': '2026-11-22T09:00:00+07:00',
        'is_mine': true,
      });
      expect(c.author.name, 'Dewi');
      expect(c.isMine, isTrue);

      final pr = Profile.fromJson({
        'id': 3,
        'name': 'Rama',
        'bio': null,
        'followers_count': 10,
        'following_count': 2,
        'posts_count': 5,
        'is_following': false,
        'follows_me': true,
        'is_me': false,
      });
      expect(pr.bio, isNull);
      expect(pr.followersCount, 10);
      expect(pr.followsMe, isTrue);

      final u = UserBrief.fromJson({'id': 9, 'name': 'Budi Santoso', 'bio': null, 'is_following': true});
      expect(u.isFollowing, isTrue);
      expect(UserAvatar.initials(u.name), 'BS');

      final s = StoryGroup.fromJson({
        'author': {'id': 3, 'name': 'Rama'},
        'items': [
          {...contractPost(), 'type': 'story', 'track': null, 'stats': null},
        ],
      });
      expect(s.items.single.type, 'story');
    });

    test('an outbox draft survives a round trip through JSON', () {
      final d = PostDraft(
        clientId: newClientId(),
        type: 'recording',
        body: 'Turun lewat Wekas',
        track: [
          [-7.45, 110.43],
          [-7.44, 110.44],
        ],
        stats: const PostStats(distanceKm: 4.567, gainM: 300, movingS: 3600),
        place: const Place(lat: -7.45, lng: 110.43, label: 'Pos 2'),
        userId: 3,
      );
      expect(d.clientId, matches(RegExp(r'^[0-9a-f]{32}$')));
      final back = PostDraft.fromJson(d.toJson());
      expect(back.clientId, d.clientId);
      expect(back.track, d.track);
      expect(back.stats!.distanceKm, 4.57);
      expect(back.place!.label, 'Pos 2');
      expect(back.userId, 3);
    });

    test('long tracks are thinned to 600 points, keeping both ends', () {
      final pts = [
        for (var i = 0; i < 5000; i++) <double>[-7 - i / 1e4, 110 + i / 1e4],
      ];
      final thin = thinTrack(pts);
      expect(thin, hasLength(600));
      expect(thin.first, pts.first);
      expect(thin.last, pts.last);
      expect(thinTrack(pts.take(10).toList()), hasLength(10));
    });
  });

  group('outbox', () {
    late _MemoryStore store;
    late Outbox box;
    late List<String> calls;
    late List<Object> answers; // a Post map to succeed, an ApiException to fail

    setUp(() {
      store = _MemoryStore();
      box = Outbox(store: store);
      calls = [];
      answers = [];
      box.sender = (d) async {
        calls.add(d.clientId);
        final a = answers.removeAt(0);
        if (a is ApiException) throw a;
        return Post.fromJson({...contractPost(), 'body': d.body});
      };
    });

    PostDraft draft(String body) => PostDraft(clientId: newClientId(), type: 'status', body: body, photoPath: '/cache/pick.jpg');

    test('sent at once when there is signal', () async {
      answers.add(contractPost());
      final post = await box.submit(draft('Cerah'));
      expect(post, isNotNull);
      expect(box.items, isEmpty);
    });

    test('queued without network, then sent with the same client_id', () async {
      answers.add(const ApiException(ApiError.network));
      final d = draft('Kabut di pos 3');
      expect(await box.submit(d), isNull);
      expect(box.items.single.clientId, d.clientId);
      expect(box.items.single.photoPath, '/docs/outbox/${d.clientId}.jpg'); // copied out of the picker cache
      expect(store.saved, hasLength(1));

      // Still no signal: stays queued.
      answers.add(const ApiException(ApiError.network));
      expect(await box.flush(), 0);
      expect(box.items, hasLength(1));

      // A new app start reads the queue from storage.
      final again = Outbox(store: store)..sender = box.sender;
      answers.add(contractPost());
      expect(await again.flush(), 1);
      expect(again.items, isEmpty);
      expect(again.sentCount, 1);
      expect(store.saved, isEmpty);
      expect(calls, [d.clientId, d.clientId, d.clientId]);
    });

    test('other errors go back to the composer, nothing is queued', () async {
      answers.add(const ApiException(ApiError.validation, status: 422, message: 'Tulisan terlalu panjang.'));
      await expectLater(box.submit(draft('x')), throwsA(isA<ApiException>()));
      expect(box.items, isEmpty);
    });

    test('a refused post is kept with its reason and skipped; cancel removes it', () async {
      answers.add(const ApiException(ApiError.network));
      answers.add(const ApiException(ApiError.network));
      final a = draft('satu');
      final b = draft('dua');
      await box.submit(a);
      await box.submit(b);

      answers.add(const ApiException(ApiError.validation, status: 422, message: 'Batas 30 kiriman per hari.'));
      answers.add(contractPost());
      expect(await box.flush(), 1);
      expect(box.items.single.clientId, a.clientId);
      expect(box.items.single.error, 'Batas 30 kiriman per hari.');
      expect(box.pending, isEmpty);

      expect(await box.flush(), 0); // not retried
      await box.cancel(a.clientId);
      expect(box.items, isEmpty);
      expect(store.saved, isEmpty);
    });

    test('a server error stops the run and keeps the order', () async {
      answers.addAll([const ApiException(ApiError.network), const ApiException(ApiError.network)]);
      final a = draft('satu');
      final b = draft('dua');
      await box.submit(a);
      await box.submit(b);
      answers.add(const ApiException(ApiError.server, status: 500));
      expect(await box.flush(), 0);
      expect(box.items.map((d) => d.clientId), [a.clientId, b.clientId]);
      expect(answers, isEmpty); // the second one was not tried
    });
  });

  testWidgets('a recording card without a photo shows the track and its numbers', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final post = Post.fromJson({...contractPost(), 'photo_url': null, 'place': null, 'route': null});
    final state = AppState(Api())..user = AppUser.fromJson({'id': 1, 'name': 'Pendaki Uji', 'email': 'uji@example.com'});
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: ListView(children: [PostCard(post: post)]),
          ),
        ),
      ),
    );
    expect(find.byType(TrackThumb), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text('Rama'), findsOneWidget);
    expect(find.text('9,4 km'), findsOneWidget);
    expect(find.text('1.320 m'), findsOneWidget);
    expect(find.textContaining('Merbabu via Selo'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Unlike is optimistic; the test server answers 400, so it rolls back and says so.
    await tester.tap(find.byIcon(Icons.favorite));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(post.liked, isTrue);
    expect(post.likesCount, 4);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
