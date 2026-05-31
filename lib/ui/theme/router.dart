import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/crypto/identity_manager.dart';
import '../../core/crypto/prekey_manager.dart';
import '../../core/crypto/relay_auth_manager.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/models/contact.dart';
import '../../core/models/conversation.dart';
import '../../core/storage/secure_database.dart';
import '../../services/message_service.dart';
import '../../services/network/prekey_service.dart';
import '../../services/network/relay_service.dart';
import '../screens/chat_screen.dart';
import '../screens/contact_screen.dart';
import '../screens/conversation_list_screen.dart';
import '../screens/onboarding_screen.dart';
import '../screens/settings_screen.dart';
import 'app_theme.dart';

class SpectreServices {
  const SpectreServices({
    required this.identityManager,
    required this.database,
    required this.hasIdentity,
    required this.onInitiate,
    required this.onWiped,
    this.currentUserId,
    this.preKeyManager,
    this.sessionManager,
    this.relayAuthManager,
    this.relayService,
    this.prekeyService,
    this.messageService,
    this.relayUrl,
  });

  final IdentityManager identityManager;
  final SecureDatabase database;
  final bool hasIdentity;
  final VoidCallback onInitiate;
  final VoidCallback onWiped;

  final String? currentUserId;
  final PreKeyManager? preKeyManager;
  final SessionManager? sessionManager;
  final RelayAuthManager? relayAuthManager;
  final RelayService? relayService;
  final PrekeyService? prekeyService;
  final MessageService? messageService;
  final Uri? relayUrl;
}

class RouteExtras {
  const RouteExtras({
    required this.services,
    this.conversation,
    this.contact,
  });

  final SpectreServices services;
  final Conversation? conversation;
  final Contact? contact;
}

/// Observes route push/pop so screens can refresh when returned to (e.g. the
/// conversation list re-reads nicknames/requests after you pop back from a
/// chat or the contact screen). Subscribe via [RouteAware] in a screen's
/// didChangeDependencies.
final RouteObserver<PageRoute<dynamic>> spectreRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

GoRouter buildSpectreRouter({required SpectreServices services}) {
  final initialExtras = RouteExtras(services: services);

  return GoRouter(
    observers: <NavigatorObserver>[spectreRouteObserver],
    initialLocation: services.hasIdentity ? '/conversations' : '/onboarding',
    initialExtra: initialExtras,
    debugLogDiagnostics: false,
    redirect: (BuildContext ctx, GoRouterState state) {
      final loc = state.uri.path;
      final onboarding = loc == '/onboarding';

      if (!services.hasIdentity && !onboarding) return '/onboarding';
      if (services.hasIdentity && onboarding) return '/conversations';
      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: '/onboarding',
        pageBuilder: (ctx, state) => _fadePage(
          key: state.pageKey,
          child: OnboardingScreen(
            services: _readExtras(state, services).services,
          ),
        ),
      ),
      GoRoute(
        path: '/conversations',
        pageBuilder: (ctx, state) {
          final svc = _readExtras(state, services).services;
          return _fadePage(
            key: state.pageKey,
            child: ConversationListScreen(
              messageService: svc.messageService!,
              database: svc.database,
              currentUserId: svc.currentUserId!,
              // Awaited so the list can reload on return (nickname edits,
              // accepts/blocks) without depending on the RouteObserver
              // delivering didPopNext through the intermediate chat route.
              onOpenConversation: (Conversation c) async {
                await ctx.push(
                  '/chat/${c.id}',
                  extra: RouteExtras(services: svc, conversation: c),
                );
              },
              onOpenSettings: () {
                ctx.push('/settings', extra: RouteExtras(services: svc));
              },
              onWiped: svc.onWiped,
            ),
          );
        },
      ),
      GoRoute(
        path: '/chat/:conversationId',
        pageBuilder: (ctx, state) {
          final extras = _readExtras(state, services);
          final svc = extras.services;
          final conversationId = state.pathParameters['conversationId']!;
          return _fadePage(
            key: state.pageKey,
            child: _ChatRouteResolver(
              services: svc,
              conversationId: conversationId,
              prefetched: extras.conversation,
            ),
          );
        },
      ),
      GoRoute(
        path: '/contact/:userId',
        pageBuilder: (ctx, state) {
          final extras = _readExtras(state, services);
          final userId = state.pathParameters['userId']!;
          return _fadePage(
            key: state.pageKey,
            child: _ContactScreen(
              services: extras.services,
              userId: userId,
              prefetched: extras.contact,
            ),
          );
        },
      ),
      GoRoute(
        path: '/settings',
        pageBuilder: (ctx, state) => _fadePage(
          key: state.pageKey,
          child: SettingsScreen(
            services: _readExtras(state, services).services,
          ),
        ),
      ),
    ],
    errorPageBuilder: (ctx, state) => _fadePage(
      key: state.pageKey,
      child: _RouteErrorScreen(message: 'no route :: ${state.uri.path}'),
    ),
  );
}

RouteExtras _readExtras(GoRouterState state, SpectreServices fallback) {
  final e = state.extra;
  if (e is RouteExtras) return e;
  return RouteExtras(services: fallback);
}

Page<T> _fadePage<T>({required Widget child, LocalKey? key}) {
  return CustomTransitionPage<T>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 160),
    transitionsBuilder: (ctx, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}

class _ChatRouteResolver extends StatefulWidget {
  const _ChatRouteResolver({
    required this.services,
    required this.conversationId,
    required this.prefetched,
  });

  final SpectreServices services;
  final String conversationId;
  final Conversation? prefetched;

  @override
  State<_ChatRouteResolver> createState() => _ChatRouteResolverState();
}

class _ChatRouteResolverState extends State<_ChatRouteResolver> {
  Conversation? _conversation;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.prefetched != null) {
      _conversation = widget.prefetched;
      _loading = false;
    } else {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    try {
      // The listed SecureDatabase API exposes getConversations() as the
      // only read path. We scan client-side — conversation lists are
      // bounded by peer count so this is acceptable.
      final all = await widget.services.database.getConversations();
      Conversation? found;
      for (final c in all) {
        if (c.id == widget.conversationId) {
          found = c;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _conversation = found;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const _RouteLoadingScreen(label: '[ resolving session… ]');
    }
    if (_error != null || _conversation == null) {
      return _RouteErrorScreen(
        message: 'conversation ${widget.conversationId} not found',
      );
    }
    final c = _conversation!;
    final svc = widget.services;
    return ChatScreen(
      conversationId: c.id,
      recipientId: c.recipientId,
      currentUserId: svc.currentUserId!,
      messageService: svc.messageService!,
      database: svc.database,
      prekeyService: svc.prekeyService!,
      sessionManager: svc.sessionManager!,
    );
  }
}

class _RouteLoadingScreen extends StatelessWidget {
  const _RouteLoadingScreen({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SpectreColors.blackDeep,
      body: NoiseBackground(
        child: Center(
          child: Text(
            label,
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              letterSpacing: 3,
            ),
          ),
        ),
      ),
    );
  }
}

class _RouteErrorScreen extends StatelessWidget {
  const _RouteErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SpectreColors.blackDeep,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          'ROUTE FAULT',
          style: SpectreTypography.danger().copyWith(letterSpacing: 4),
        ),
      ),
      body: NoiseBackground(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const DashedDivider(color: SpectreColors.redDanger),
              const SizedBox(height: 16),
              Text(
                message,
                style: SpectreTypography.mono().copyWith(
                  color: SpectreColors.textCold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Resolves the peer's contact row for /contact and hands it to the full
/// ContactScreen (own + peer safety-number comparison — both halves are
/// needed: each device shows its OWN fingerprint so the peer can confirm it).
/// Shows a placeholder until the first message creates the record.
class _ContactScreen extends StatefulWidget {
  const _ContactScreen({
    required this.services,
    required this.userId,
    required this.prefetched,
  });

  final SpectreServices services;
  final String userId;
  final Contact? prefetched;

  @override
  State<_ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<_ContactScreen> {
  Contact? _contact;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.prefetched != null) {
      _contact = widget.prefetched;
      _loading = false;
    } else {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final c = await widget.services.database.getContact(widget.userId);
    if (!mounted) return;
    setState(() {
      _contact = c;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const _RouteLoadingScreen(label: '[ loading peer… ]');
    }
    final c = _contact;
    if (c == null) {
      return Scaffold(
        backgroundColor: SpectreColors.blackDeep,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text('PEER',
              style: SpectreTypography.title().copyWith(letterSpacing: 4)),
        ),
        body: NoiseBackground(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: 40),
                Text('> userId', style: SpectreTypography.caption()),
                const SizedBox(height: 6),
                SelectableText(widget.userId,
                    style: SpectreTypography.mono()
                        .copyWith(color: SpectreColors.textBright)),
                const SizedBox(height: 22),
                const DashedDivider(),
                const SizedBox(height: 22),
                Text('no contact record yet.',
                    style: SpectreTypography.body()),
                const SizedBox(height: 4),
                Text(
                  'a record is created the first time you exchange a message '
                  'with this peer.',
                  style: SpectreTypography.caption().copyWith(height: 1.7),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ContactScreen(services: widget.services, contact: c);
  }
}
