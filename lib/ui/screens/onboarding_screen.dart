import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../../core/crypto/identity_manager.dart';
import '../../core/models/contact.dart';
import '../theme/app_theme.dart';
import '../theme/router.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.services});

  final SpectreServices services;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  final ScrollController _fingerprintScroll = ScrollController();
  final TextEditingController _nameController = TextEditingController();

  int _step = 0;
  SpectreIdentity? _identity;
  List<String>? _words;
  bool _generating = true;
  Object? _error;
  bool _verifiedScrolled = false;
  bool _completing = false;

  static const Duration _stepTransition = Duration(milliseconds: 360);

  @override
  void initState() {
    super.initState();
    _fingerprintScroll.addListener(_onFingerprintScroll);
    _generate();
  }

  @override
  void dispose() {
    _fingerprintScroll.removeListener(_onFingerprintScroll);
    _fingerprintScroll.dispose();
    _pageController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    // Run the real key generation in parallel with the scripted reveal
    // animation so the UI always shows a deliberate sequence, even on
    // devices fast enough to mint a key in microseconds.
    final start = DateTime.now();
    try {
      final identity = await widget.services.identityManager.loadOrCreate();
      final pubBytes =
          identity.identityKeyPair.getPublicKey().serialize();
      final hash = SHA256Digest().process(pubBytes);
      final hex =
          hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final words = Contact(
        id: '_self',
        userId: identity.userId,
        identityKeyFingerprint: hex,
        createdAt: DateTime.now(),
      ).fingerprintWords;

      final elapsed = DateTime.now().difference(start);
      const floor = Duration(milliseconds: 2000);
      if (elapsed < floor) {
        await Future<void>.delayed(floor - elapsed);
      }

      if (!mounted) return;
      setState(() {
        _identity = identity;
        _words = words;
        _generating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _generating = false;
      });
    }
  }

  void _onFingerprintScroll() {
    if (_verifiedScrolled) return;
    if (!_fingerprintScroll.hasClients) return;
    final pos = _fingerprintScroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 4) {
      setState(() => _verifiedScrolled = true);
    }
  }

  Future<void> _advance() async {
    if (_step >= 2) return;
    await _pageController.nextPage(
      duration: _stepTransition,
      curve: Curves.easeInOut,
    );
    setState(() => _step += 1);
    if (_step == 2) _checkFingerprintFits();
  }

  void _checkFingerprintFits() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_fingerprintScroll.hasClients) return;
      final pos = _fingerprintScroll.position;
      if (pos.maxScrollExtent <= 0 && !_verifiedScrolled) {
        setState(() => _verifiedScrolled = true);
      }
    });
  }

  Future<void> _complete() async {
    if (_completing) return;
    setState(() => _completing = true);
    // Persist the chosen display name (optional; setDisplayName trims + treats
    // empty as "unset"). Local at rest; shared only inside E2E messages.
    await widget.services.identityManager.setDisplayName(_nameController.text);
    // Hand control back to the app shell; it rebuilds the router with
    // hasIdentity=true and the redirect carries us to /conversations.
    widget.services.onInitiate();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: SpectreColors.blackDeep,
        body: NoiseBackground(
          child: SafeArea(
            child: Column(
              children: <Widget>[
                _ProgressDashes(step: _step),
                const SizedBox(height: 8),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: <Widget>[
                      _InitiateStep(
                        generating: _generating,
                        identity: _identity,
                        error: _error,
                        nameController: _nameController,
                        onContinue: _advance,
                        onRetry: () {
                          setState(() {
                            _generating = true;
                            _error = null;
                          });
                          _generate();
                        },
                      ),
                      _ProtocolStep(onContinue: _advance),
                      _FingerprintStep(
                        words: _words,
                        scrollController: _fingerprintScroll,
                        canVerify: _verifiedScrolled,
                        completing: _completing,
                        onVerified: _complete,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressDashes extends StatelessWidget {
  const _ProgressDashes({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Row(
        children: List<Widget>.generate(3, (i) {
          final active = i == step;
          final past = i < step;
          final Color color;
          if (active) {
            color = SpectreColors.matrixGreen;
          } else if (past) {
            color = SpectreColors.matrixDim;
          } else {
            color = SpectreColors.textFaint;
          }
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                height: 2,
                color: color,
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _InitiateStep extends StatelessWidget {
  const _InitiateStep({
    required this.generating,
    required this.identity,
    required this.error,
    required this.nameController,
    required this.onContinue,
    required this.onRetry,
  });

  final bool generating;
  final SpectreIdentity? identity;
  final Object? error;
  final TextEditingController nameController;
  final VoidCallback onContinue;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 28),
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                color: error != null
                    ? SpectreColors.redDanger
                    : (identity != null
                        ? SpectreColors.matrixGreen
                        : SpectreColors.purpleBright),
              ),
              const SizedBox(width: 12),
              Text(
                'STEP 01 :: INITIATE',
                style: SpectreTypography.title().copyWith(letterSpacing: 4),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const DashedDivider(),
          const SizedBox(height: 28),
          Expanded(
            child: error != null
                ? _GenerationFailure(error: error!, onRetry: onRetry)
                : (generating || identity == null
                    ? const _GeneratingReadout()
                    : _IdentityReadout(identity: identity!)),
          ),
          if (identity != null && error == null) ...<Widget>[
            Text(
              'DISPLAY NAME (OPTIONAL)',
              style: SpectreTypography.caption().copyWith(
                color: SpectreColors.textDim,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              decoration: const BoxDecoration(
                color: SpectreColors.blackDeep,
                border: Border.fromBorderSide(
                  BorderSide(color: SpectreColors.hairline, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: TextField(
                controller: nameController,
                maxLength: 40,
                cursorColor: SpectreColors.matrixGreen,
                style: SpectreTypography.mono()
                    .copyWith(color: SpectreColors.textBright),
                decoration: InputDecoration(
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: InputBorder.none,
                  counterText: '',
                  hintText: 'how contacts see you',
                  hintStyle: SpectreTypography.mono()
                      .copyWith(color: SpectreColors.textFaint),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'shared only with people you message (end-to-end) — never the '
              'relay. you can change or clear it later in settings.',
              style: SpectreTypography.caption().copyWith(
                color: SpectreColors.textFaint,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 16),
          _ActionButton(
            label: '[ CONTINUE ]',
            enabled: identity != null && error == null,
            onTap: onContinue,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _GeneratingReadout extends StatefulWidget {
  const _GeneratingReadout();

  @override
  State<_GeneratingReadout> createState() => _GeneratingReadoutState();
}

class _GeneratingReadoutState extends State<_GeneratingReadout>
    with SingleTickerProviderStateMixin {
  static const List<String> _lines = <String>[
    '> probing entropy source',
    '> seeding csprng',
    '> generating ed25519 identity',
    '> minting registration id',
    '> committing to keystore',
    '> ready',
  ];

  final List<int> _revealed = <int>[];
  Timer? _timer;
  late final AnimationController _cursor;

  @override
  void initState() {
    super.initState();
    _cursor = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _scheduleNext();
  }

  void _scheduleNext() {
    if (_revealed.length >= _lines.length) return;
    _timer = Timer(const Duration(milliseconds: 340), () {
      if (!mounted) return;
      setState(() => _revealed.add(_revealed.length));
      _scheduleNext();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cursor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showCursorOn = _revealed.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'generating identity',
          style: SpectreTypography.caption().copyWith(
            color: SpectreColors.textDim,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(
            color: SpectreColors.blackLess,
            border: Border.fromBorderSide(
              BorderSide(color: SpectreColors.hairline, width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = 0; i < _lines.length; i++)
                _ConsoleLine(
                  text: _lines[i],
                  visible: _revealed.contains(i),
                  active: i == _lines.length - 1 &&
                      _revealed.contains(i),
                ),
              const SizedBox(height: 4),
              if (showCursorOn < _lines.length)
                AnimatedBuilder(
                  animation: _cursor,
                  builder: (ctx, _) {
                    return Text(
                      _cursor.value > 0.5 ? '█' : ' ',
                      style: SpectreTypography.mono().copyWith(
                        color: SpectreColors.matrixGreen,
                        fontSize: 13,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConsoleLine extends StatelessWidget {
  const _ConsoleLine({
    required this.text,
    required this.visible,
    required this.active,
  });

  final String text;
  final bool visible;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          text,
          style: SpectreTypography.mono().copyWith(
            color: active
                ? SpectreColors.matrixGreen
                : SpectreColors.textCold,
            fontSize: 12,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class _IdentityReadout extends StatelessWidget {
  const _IdentityReadout({required this.identity});

  final SpectreIdentity identity;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'identity',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              color: SpectreColors.blackLess,
              border: Border.fromBorderSide(
                BorderSide(color: SpectreColors.textCold, width: 1),
              ),
            ),
            child: SelectableText(
              identity.userId,
              style: SpectreTypography.mono().copyWith(
                color: SpectreColors.textBright,
                fontSize: 13.5,
                height: 1.5,
                letterSpacing: 0.6,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'THIS IS YOU.',
            style: SpectreTypography.title().copyWith(
              color: SpectreColors.textBright,
              letterSpacing: 5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'NO NAME. NO NUMBER. NO TRACE.',
            style: SpectreTypography.title().copyWith(
              color: SpectreColors.textCold,
              fontSize: 13,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 18),
          const DashedDivider(),
          const SizedBox(height: 14),
          Text(
            'store this nowhere. remember nothing.',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              height: 1.7,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'your keys are your identity.',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              height: 1.7,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _GenerationFailure extends StatelessWidget {
  const _GenerationFailure({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '[ fault :: ${error.runtimeType} ]',
          style: SpectreTypography.danger().copyWith(fontSize: 12),
        ),
        const SizedBox(height: 12),
        Text(
          'identity generation failed. without an identity, '
          'no session can be established.',
          style: SpectreTypography.caption().copyWith(
            color: SpectreColors.textCold,
            height: 1.7,
          ),
        ),
        const SizedBox(height: 18),
        _ActionButton(
          label: '[ RETRY ]',
          enabled: true,
          onTap: onRetry,
          color: SpectreColors.redBlood,
          borderColor: SpectreColors.redDanger,
        ),
      ],
    );
  }
}

class _ProtocolStep extends StatelessWidget {
  const _ProtocolStep({required this.onContinue});

  final VoidCallback onContinue;

  static const List<_ProtocolBlock> _blocks = <_ProtocolBlock>[
    _ProtocolBlock(
      headline: 'end-to-end encrypted. the relay sees nothing.',
      body:
          'every message is sealed with the signal protocol on this device. '
          'the relay only stores opaque ciphertext routed by recipient id.',
    ),
    _ProtocolBlock(
      headline: 'messages vanish. no history survives a wipe.',
      body:
          'expired messages are hard-deleted. a panic wipe destroys '
          'every key, every session, and the database itself.',
    ),
    _ProtocolBlock(
      headline: 'no accounts. no servers. no records.',
      body:
          'there is no signup, no recovery email, no central directory. '
          'authentication is by signature, not by password or token.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 28),
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                color: SpectreColors.purpleBright,
              ),
              const SizedBox(width: 12),
              Text(
                'STEP 02 :: PROTOCOL',
                style: SpectreTypography.title().copyWith(letterSpacing: 4),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const DashedDivider(),
          const SizedBox(height: 28),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _blocks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 22),
              itemBuilder: (ctx, i) =>
                  _ProtocolBlockView(block: _blocks[i]),
            ),
          ),
          const SizedBox(height: 16),
          _ActionButton(
            label: '[ CONTINUE ]',
            enabled: true,
            onTap: onContinue,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ProtocolBlock {
  const _ProtocolBlock({required this.headline, required this.body});

  final String headline;
  final String body;
}

class _ProtocolBlockView extends StatelessWidget {
  const _ProtocolBlockView({required this.block});

  final _ProtocolBlock block;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        RichText(
          text: TextSpan(
            children: <InlineSpan>[
              TextSpan(
                text: '// ',
                style: SpectreTypography.mono().copyWith(
                  color: SpectreColors.matrixGreen,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              TextSpan(
                text: block.headline,
                style: SpectreTypography.mono().copyWith(
                  color: SpectreColors.textBright,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Text(
            block.body,
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textCold,
              height: 1.7,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _FingerprintStep extends StatelessWidget {
  const _FingerprintStep({
    required this.words,
    required this.scrollController,
    required this.canVerify,
    required this.completing,
    required this.onVerified,
  });

  final List<String>? words;
  final ScrollController scrollController;
  final bool canVerify;
  final bool completing;
  final VoidCallback onVerified;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 28),
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                color: SpectreColors.redDanger,
              ),
              const SizedBox(width: 12),
              Text(
                'STEP 03 :: FINGERPRINT',
                style: SpectreTypography.title().copyWith(letterSpacing: 4),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const DashedDivider(color: SpectreColors.redDanger),
          const SizedBox(height: 22),
          Text(
            'VERIFY THIS. OUT OF BAND. EVERY TIME.',
            style: SpectreTypography.title().copyWith(
              color: SpectreColors.redDanger,
              fontSize: 13,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: words == null
                ? Center(
                    child: Text(
                      '[ deriving fingerprint… ]',
                      style: SpectreTypography.caption().copyWith(
                        color: SpectreColors.textDim,
                        letterSpacing: 3,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    controller: scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _WordGrid(words: words!),
                        const SizedBox(height: 22),
                        const DashedDivider(),
                        const SizedBox(height: 18),
                        Text(
                          'spoken word verification defeats a man-in-the-middle.',
                          style: SpectreTypography.mono().copyWith(
                            color: SpectreColors.textBright,
                            fontSize: 13,
                            height: 1.55,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'an attacker can substitute keys on the wire. they '
                          'cannot substitute your voice. read the words to '
                          'your peer on a separately-trusted channel — in '
                          'person, by signed audio, by qr scanned offline. '
                          'if the words match on both ends, the session is '
                          'authentic. if any word differs, abandon this '
                          'session and start over. do not rationalise a '
                          'mismatch. one bad word means the channel is '
                          'compromised.',
                          style: SpectreTypography.caption().copyWith(
                            color: SpectreColors.textCold,
                            height: 1.8,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 26),
                        if (!canVerify)
                          Text(
                            '— scroll to bottom to continue —',
                            style: SpectreTypography.caption().copyWith(
                              color: SpectreColors.textFaint,
                              letterSpacing: 2,
                            ),
                          ),
                        const SizedBox(height: 14),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          _ActionButton(
            label: completing
                ? '[ ENTERING SESSION… ]'
                : (canVerify
                    ? '[ I HAVE VERIFIED ]'
                    : '[ LOCKED ]'),
            enabled: canVerify && !completing,
            onTap: onVerified,
            color: canVerify
                ? SpectreColors.purpleDeep
                : SpectreColors.blackHair,
            borderColor: canVerify
                ? SpectreColors.matrixGreen
                : SpectreColors.hairline,
            textColor: canVerify
                ? SpectreColors.textBright
                : SpectreColors.textDim,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _WordGrid extends StatelessWidget {
  const _WordGrid({required this.words});

  final List<String> words;

  @override
  Widget build(BuildContext context) {
    const columns = 4;
    final rows = (words.length / columns).ceil();
    return Container(
      decoration: const BoxDecoration(
        color: SpectreColors.blackLess,
        border: Border.fromBorderSide(
          BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      child: Column(
        children: <Widget>[
          for (var r = 0; r < rows; r++)
            _GridRow(
              cells: List<_GridCell?>.generate(columns, (c) {
                final idx = r * columns + c;
                if (idx >= words.length) return null;
                return _GridCell(
                  number: idx + 1,
                  word: words[idx],
                );
              }),
              isLast: r == rows - 1,
            ),
        ],
      ),
    );
  }
}

class _GridRow extends StatelessWidget {
  const _GridRow({required this.cells, required this.isLast});

  final List<_GridCell?> cells;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isLast ? Colors.transparent : SpectreColors.hairline,
            width: 1,
          ),
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < cells.length; i++) ...<Widget>[
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: i == cells.length - 1
                            ? Colors.transparent
                            : SpectreColors.hairline,
                        width: 1,
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 12,
                  ),
                  child: cells[i] ?? const SizedBox.shrink(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GridCell extends StatelessWidget {
  const _GridCell({required this.number, required this.word});

  final int number;
  final String word;

  @override
  Widget build(BuildContext context) {
    final num = number.toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          num,
          style: SpectreTypography.stamp().copyWith(
            color: SpectreColors.textFaint,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          word,
          style: SpectreTypography.mono().copyWith(
            color: SpectreColors.textBright,
            fontSize: 12.5,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.color,
    this.borderColor,
    this.textColor,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color? color;
  final Color? borderColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final bg = enabled
        ? (color ?? SpectreColors.purpleDeep)
        : SpectreColors.blackHair;
    final border = enabled
        ? (borderColor ?? SpectreColors.purpleBright)
        : SpectreColors.hairline;
    final text = enabled
        ? (textColor ?? SpectreColors.textBright)
        : SpectreColors.textDim;
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: 1),
        ),
        child: Text(
          label,
          style: SpectreTypography.action().copyWith(color: text),
        ),
      ),
    );
  }
}
