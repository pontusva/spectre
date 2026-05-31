import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'core/crypto/identity_manager.dart';
import 'core/crypto/prekey_manager.dart';
import 'core/crypto/relay_auth_manager.dart';
import 'core/crypto/sealed_sender.dart';
import 'core/crypto/session_manager.dart';
import 'core/storage/secure_database.dart';
import 'services/message_service.dart';
import 'services/network/prekey_service.dart';
import 'services/network/relay_service.dart';
import 'services/network/sealed_ca_service.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/router.dart';

// Configurable at build time:
//   flutter run --dart-define=SPECTRE_RELAY_URL=wss://your-relay.example
// Default is a clearly-invalid sentinel so misconfigured builds fail loud
// rather than silently exfiltrating to a default host.
const String _kRelayUrlRaw = String.fromEnvironment(
  'SPECTRE_RELAY_URL',
  defaultValue: 'wss://relay.invalid',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: SpectreColors.blackDeep,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: SpectreColors.blackDeep,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const SpectreApp());
}

class SpectreApp extends StatefulWidget {
  const SpectreApp({super.key});

  @override
  State<SpectreApp> createState() => _SpectreAppState();
}

enum _Phase { booting, ready, errored }

class _SpectreAppState extends State<SpectreApp> with WidgetsBindingObserver {
  _Phase _phase = _Phase.booting;
  Object? _error;
  SpectreServices? _services;
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final db = _services?.database;
    if (db == null) return;
    // Best-effort sweep — never block the foreground transition. Errors
    // are swallowed: the next resume will try again.
    db.deleteExpiredMessages().catchError((_) => 0);
  }

  Future<void> _boot() async {
    setState(() {
      _phase = _Phase.booting;
      _error = null;
    });

    try {
      final identityManager = IdentityManager();
      final database = SecureDatabase();
      await database.open();

      final hasIdentity = await identityManager.hasIdentity();

      if (!hasIdentity) {
        // Defer prekey / session / network bring-up until the user has
        // accepted onboarding. We don't want to mint cryptographic state
        // for a user who hasn't agreed to start a session.
        final services = SpectreServices(
          identityManager: identityManager,
          database: database,
          hasIdentity: false,
          onInitiate: _onInitiate,
          onWiped: _onWiped,
        );
        setState(() {
          _services = services;
          _router = buildSpectreRouter(services: services);
          _phase = _Phase.ready;
        });
        return;
      }

      final identity = await identityManager.loadOrCreate();

      final preKeyManager = PreKeyManager(identityManager: identityManager);
      await preKeyManager.loadOrCreate();

      // Provision the relay-auth keypair before bringing the websocket
      // up. A keystore round-trip during the first frame would cost the
      // auth handshake its 10s timeout budget on cold-storage devices.
      final relayAuthManager = RelayAuthManager();
      await relayAuthManager.loadOrCreate();

      final sessionManager =
          await SessionManager.create(identityManager, preKeyManager);

      final relayUri = Uri.parse(_kRelayUrlRaw);
      // Fail loud on a misconfigured endpoint rather than letting a
      // malformed URL surface later as an opaque "not upgraded to
      // websocket" error. A whitespace in the path almost always means a
      // shell-quoting mistake swallowed the next --dart-define flag into
      // SPECTRE_RELAY_URL (e.g. the value spanned two flags in one quote).
      if (relayUri.scheme != 'ws' && relayUri.scheme != 'wss') {
        throw StateError(
          'SPECTRE_RELAY_URL must use ws:// or wss:// '
          '(got scheme "${relayUri.scheme}")',
        );
      }
      if (!relayUri.hasAuthority ||
          _kRelayUrlRaw.contains(' ') ||
          relayUri.path.contains(' ')) {
        throw StateError(
          'SPECTRE_RELAY_URL is malformed: "$_kRelayUrlRaw". '
          'Check that each --dart-define has its own value and no quote '
          'spans two flags.',
        );
      }

      final relayService = RelayService(
        relayUrl: relayUri,
        identityManager: identityManager,
        relayAuthManager: relayAuthManager,
      );

      // PrekeyService closes the cycle between RelayService (control
      // frames) and PreKeyManager (bundle source). Constructed AFTER
      // relayService so the constructor can take a non-null reference,
      // then attached back to relayService via the late-binding setter
      // so the post-auth hook can fire uploadBundle().
      final prekeyService = PrekeyService(
        relayService: relayService,
        preKeyManager: preKeyManager,
        identityManager: identityManager,
        relayUrl: relayUri,
      );
      relayService.attachPrekeyService(prekeyService);

      // Sealed Sender: fetch + TOFU-pin the relay's CA key, then build a
      // SealedSender bound to it. Boot-resilient: if the CA key can't be
      // obtained (relay unreachable and none pinned) we proceed with a null
      // SealedSender — sealed messaging stays unavailable (send queues, inbound
      // drops) until a restart with the relay reachable, rather than blocking
      // app bring-up. The HTTP fetch is internally bounded by a timeout.
      SealedSender? sealedSender;
      try {
        sealedSender =
            await SealedCaService(relayUrl: relayUri).sealedSender();
      } catch (_) {
        sealedSender = null;
      }

      final messageService = MessageService(
        identityManager: identityManager,
        preKeyManager: preKeyManager,
        sessionManager: sessionManager,
        database: database,
        relayService: relayService,
        relayAuthManager: relayAuthManager,
        prekeyService: prekeyService,
        sealedSender: sealedSender,
      );

      // Kick off relay connection in the background. UI is functional
      // (composer queues to pending) while this is in flight.
      unawaited(relayService.connect().catchError((_) {}));

      final services = SpectreServices(
        identityManager: identityManager,
        database: database,
        hasIdentity: true,
        onInitiate: _onInitiate,
        onWiped: _onWiped,
        currentUserId: identity.userId,
        preKeyManager: preKeyManager,
        sessionManager: sessionManager,
        relayAuthManager: relayAuthManager,
        relayService: relayService,
        prekeyService: prekeyService,
        messageService: messageService,
        relayUrl: relayUri,
      );

      // Foreground sweep on first launch too — not just on resume.
      await database.deleteExpiredMessages().catchError((_) => 0);

      if (!mounted) return;
      setState(() {
        _services = services;
        _router = buildSpectreRouter(services: services);
        _phase = _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _phase = _Phase.errored;
      });
    }
  }

  void _onInitiate() {
    // The user just generated an identity via the onboarding screen.
    // Re-run init so the rest of the cryptographic stack comes up.
    // _boot is idempotent and will detect hasIdentity = true on this pass.
    _boot();
  }

  Future<void> _onWiped() async {
    // After a successful panic wipe the existing services are unusable.
    // Tear down our references and re-boot — _boot will see hasIdentity
    // = false and route the user to /onboarding.
    setState(() {
      _services = null;
      _router = null;
      _phase = _Phase.booting;
    });
    await _boot();
  }

  Future<void> _hardWipeAndExit() async {
    // Best-effort during a failed init. We may not have constructed
    // every component, so each step is independently guarded.
    try {
      final db = SecureDatabase();
      await db.wipeDatabase();
    } catch (_) {/* swallow */}
    try {
      await IdentityManager().wipeIdentity();
    } catch (_) {/* swallow */}
    try {
      await PreKeyManager(identityManager: IdentityManager()).wipeAll();
    } catch (_) {/* swallow */}
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.dark();

    switch (_phase) {
      case _Phase.booting:
        return MaterialApp(
          theme: theme,
          debugShowCheckedModeBanner: false,
          home: const _BootScreen(),
        );
      case _Phase.errored:
        return MaterialApp(
          theme: theme,
          debugShowCheckedModeBanner: false,
          home: _ErrorScreen(
            error: _error,
            onWipe: _hardWipeAndExit,
            onRetry: _boot,
          ),
        );
      case _Phase.ready:
        return MaterialApp.router(
          theme: theme,
          debugShowCheckedModeBanner: false,
          routerConfig: _router!,
        );
    }
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SpectreColors.blackDeep,
      body: NoiseBackground(
        child: SafeArea(
          child: Column(
            children: <Widget>[
              const Spacer(flex: 2),
              const _BootGlitchTitle(),
              const SizedBox(height: 22),
              const _BootSpinner(),
              const SizedBox(height: 18),
              Text(
                '[ initialising secure session… ]',
                style: SpectreTypography.caption().copyWith(
                  color: SpectreColors.textDim,
                  letterSpacing: 3,
                ),
              ),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  children: <Widget>[
                    const DashedDivider(),
                    const SizedBox(height: 8),
                    Text(
                      'nothing phones home.',
                      style: SpectreTypography.caption().copyWith(
                        color: SpectreColors.textFaint,
                        letterSpacing: 2.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }
}

class _BootGlitchTitle extends StatefulWidget {
  const _BootGlitchTitle();

  @override
  State<_BootGlitchTitle> createState() => _BootGlitchTitleState();
}

class _BootGlitchTitleState extends State<_BootGlitchTitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final Random _rng = Random(0xBADC0DE);
  double _redDx = 0;
  double _cyanDx = 0;
  double _alpha = 1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )
      ..addListener(_tick)
      ..repeat();
  }

  void _tick() {
    final t = _controller.value;
    final phase = (t * 8).floor() % 4;
    final glitching = phase == 0 || phase == 2;
    setState(() {
      if (glitching) {
        _redDx = _rng.nextDouble() * 6 - 3;
        _cyanDx = _rng.nextDouble() * 6 - 3;
        _alpha = 0.7;
      } else {
        _redDx = 0;
        _cyanDx = 0;
        _alpha = 0.0;
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = SpectreTypography.display().copyWith(
      fontSize: 36,
      letterSpacing: 10,
    );
    return Center(
      child: SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Transform.translate(
              offset: Offset(_redDx, 0),
              child: Text(
                'SPECTRE',
                style: style.copyWith(
                  color: SpectreColors.redDanger.withOpacity(_alpha),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(_cyanDx, 0),
              child: Text(
                'SPECTRE',
                style: style.copyWith(
                  color: SpectreColors.purpleBright.withOpacity(_alpha),
                ),
              ),
            ),
            Text('SPECTRE', style: style),
          ],
        ),
      ),
    );
  }
}

class _BootSpinner extends StatefulWidget {
  const _BootSpinner();

  @override
  State<_BootSpinner> createState() => _BootSpinnerState();
}

class _BootSpinnerState extends State<_BootSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        return CustomPaint(
          size: const Size(32, 32),
          painter: _BlockSpinnerPainter(progress: _ctrl.value),
        );
      },
    );
  }
}

class _BlockSpinnerPainter extends CustomPainter {
  _BlockSpinnerPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const segments = 8;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2 - 2;
    final activeIndex = (progress * segments).floor() % segments;
    for (var i = 0; i < segments; i++) {
      final angle = -pi / 2 + (i / segments) * pi * 2;
      final x = cx + r * cos(angle);
      final y = cy + r * sin(angle);
      final lead = (i - activeIndex) % segments;
      final fade = (1.0 - (lead / segments)).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = SpectreColors.matrixGreen.withOpacity(fade * 0.9)
        ..style = PaintingStyle.fill;
      canvas.drawRect(
        Rect.fromCenter(center: Offset(x, y), width: 4, height: 4),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BlockSpinnerPainter old) => old.progress != progress;
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({
    required this.error,
    required this.onWipe,
    required this.onRetry,
  });

  final Object? error;
  final Future<void> Function() onWipe;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SpectreColors.blackDeep,
      body: NoiseBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: 60),
                Row(
                  children: <Widget>[
                    Container(
                      width: 10,
                      height: 10,
                      color: SpectreColors.redDanger,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'ANOMALY',
                      style: SpectreTypography.danger().copyWith(
                        fontSize: 22,
                        letterSpacing: 8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const DashedDivider(color: SpectreColors.redDanger),
                const SizedBox(height: 22),
                Text(
                  'the device cannot be brought up in a safe state.',
                  style: SpectreTypography.body().copyWith(
                    color: SpectreColors.textBright,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: SpectreColors.blackLess,
                    border: Border.fromBorderSide(
                      BorderSide(color: SpectreColors.hairline, width: 1),
                    ),
                  ),
                  child: Text(
                    'fault :: ${error?.runtimeType ?? 'unknown'}',
                    style: SpectreTypography.mono().copyWith(
                      color: SpectreColors.redDanger,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'you can retry initialisation or wipe everything and '
                  'start over. wiping is irreversible.',
                  style: SpectreTypography.caption().copyWith(
                    color: SpectreColors.textCold,
                    height: 1.7,
                  ),
                ),
                const Spacer(),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: InkWell(
                        onTap: onRetry,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            border: Border.fromBorderSide(
                              BorderSide(
                                color: SpectreColors.hairline,
                                width: 1,
                              ),
                            ),
                          ),
                          child: Text(
                            '[ RETRY ]',
                            style: SpectreTypography.action(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkWell(
                        onTap: onWipe,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: SpectreColors.redBlood,
                            border: Border.fromBorderSide(
                              BorderSide(
                                color: SpectreColors.redDanger,
                                width: 1,
                              ),
                            ),
                          ),
                          child: Text(
                            '[ WIPE ]',
                            style: SpectreTypography.action().copyWith(
                              color: SpectreColors.textBright,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
