import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/contour_header.dart';

/// Signed-in account: who is signed in, the liked trails, and log out.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  Future<List<RouteSummary>>? _likes;
  String? _lang;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_lang != state.lang) {
      _lang = state.lang;
      _load();
    }
  }

  void _load() {
    final future = AppScope.read(context).api.likes();
    setState(() {
      _likes = future;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final user = state.user;
    if (user == null) {
      // Signed out (here or after an expired token): leave the screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold();
    }
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => _load(),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: ContourHeader(
                seed: 21,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const HeaderBar(),
                    const SizedBox(height: 14),
                    Semantics(
                      header: true,
                      child: Text(tr(context, 'account.welcome', {'name': user.name}).toUpperCase(), style: RS.head(38, color: Colors.white)),
                    ),
                    const SizedBox(height: 6),
                    Text(user.email, style: const TextStyle(color: RS.onDarkSoft, fontSize: 15)),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: () => state.signOut(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white70),
                      ),
                      icon: const Icon(Icons.logout),
                      label: Text(tr(context, 'account.logout')),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Text(tr(context, 'account.likes').toUpperCase(), style: RS.head(28, color: RS.z9)),
              ),
            ),
            FutureBuilder<List<RouteSummary>>(
              future: _likes,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const SliverToBoxAdapter(child: LoadingView());
                if (snap.hasError) {
                  final e = snap.error;
                  if (e is ApiException && e.kind == ApiError.unauthorized) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => state.signOut());
                  }
                  return SliverToBoxAdapter(
                    child: ErrorView(error: snap.error!, onRetry: _load),
                  );
                }
                final routes = snap.data!;
                if (routes.isEmpty) {
                  return SliverToBoxAdapter(
                    child: MessageView(title: tr(context, 'account.likes.empty'), icon: Icons.favorite_border),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  sliver: SliverList.separated(
                    itemCount: routes.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (context, i) => RouteCard(route: routes[i]),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
