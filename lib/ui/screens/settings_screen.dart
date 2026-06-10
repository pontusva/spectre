import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../theme/app_theme.dart';
import '../theme/router.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.services});

  final SpectreServices services;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _Disappearing {
  off(0, 'OFF'),
  hour(3600, '1 HOUR'),
  day(86400, '24 HOURS'),
  week(604800, '7 DAYS');

  const _Disappearing(this.seconds, this.label);
  final int seconds;
  final String label;

  static _Disappearing fromSeconds(int? s) {
    for (final v in _Disappearing.values) {
      if (v.seconds == s) return v;
    }
    return _Disappearing.off;
  }
}

class _SettingsScreenState extends State<SettingsScreen> {
  // The disappearing-default setting is a single integer with no
  // sensitive content. The new SecureDatabase API does not expose a
  // settings table, so we persist it in FlutterSecureStorage alongside
  // other Keystore-backed values. The key namespace is kept short and
  // opaque to match the pattern used by IdentityManager / PreKeyManager.
  static const String _kDisappearingKey = 'spectre.dis.def';

  final FlutterSecureStorage _settingsStore = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  bool _loading = true;

  DateTime? _lastRotation;
  bool _rotating = false;
  bool _justRotated = false;
  Object? _rotateError;
  Timer? _rotatedTimer;

  bool _copied = false;
  Timer? _copiedTimer;

  String? _displayName;

  bool _torOn = false;
  bool _torStub = false;
  Timer? _torStubTimer;

  bool _duressStub = false;
  Timer? _duressStubTimer;

  _Disappearing _disappearing = _Disappearing.off;
  bool _wiping = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rotatedTimer?.cancel();
    _copiedTimer?.cancel();
    _torStubTimer?.cancel();
    _duressStubTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final raw = await _settingsStore.read(key: _kDisappearingKey);
    final seconds = raw == null ? null : int.tryParse(raw);

    DateTime? lastRotation;
    final pk = widget.services.preKeyManager;
    if (pk != null) {
      lastRotation = await pk.lastSignedPreKeyRotation();
    }
    final displayName = await widget.services.identityManager.displayName();

    if (!mounted) return;
    setState(() {
      _disappearing = _Disappearing.fromSeconds(seconds);
      _lastRotation = lastRotation;
      _displayName = displayName;
      _loading = false;
    });
  }

  Future<void> _editDisplayName() async {
    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (ctx) => _DisplayNameDialog(initial: _displayName ?? ''),
    );
    if (result == null || !mounted) return; // cancelled
    await widget.services.identityManager.setDisplayName(result);
    final fresh = await widget.services.identityManager.displayName();
    if (!mounted) return;
    setState(() => _displayName = fresh);
  }

  Future<void> _setDisappearing(_Disappearing value) async {
    setState(() => _disappearing = value);
    await _settingsStore.write(
      key: _kDisappearingKey,
      value: value.seconds.toString(),
    );
  }

  Future<void> _copyId() async {
    final id = widget.services.currentUserId;
    if (id == null) return;
    await Clipboard.setData(ClipboardData(text: id));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _rotatePreKey() async {
    final pk = widget.services.preKeyManager;
    if (pk == null || _rotating) return;
    setState(() {
      _rotating = true;
      _rotateError = null;
      _justRotated = false;
    });
    try {
      await pk.rotateSignedPreKey();
      final now = await pk.lastSignedPreKeyRotation();
      if (!mounted) return;
      setState(() {
        _rotating = false;
        _justRotated = true;
        _lastRotation = now ?? DateTime.now().toUtc();
      });
      _rotatedTimer?.cancel();
      _rotatedTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _justRotated = false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rotating = false;
        _rotateError = e;
      });
    }
  }

  void _toggleTor() {
    setState(() {
      _torOn = !_torOn;
      _torStub = true;
    });
    _torStubTimer?.cancel();
    _torStubTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _torStub = false);
    });
  }

  void _duressTap() {
    setState(() => _duressStub = true);
    _duressStubTimer?.cancel();
    _duressStubTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _duressStub = false);
    });
  }

  Future<void> _panicWipe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (_) => const _PanicWipeDialog(),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _wiping = true);
    final svc = widget.services.messageService;
    if (svc != null) {
      await svc.panicWipe();
    }
    if (!mounted) return;
    widget.services.onWiped();
  }

  String _formatRotation(DateTime? dt) {
    if (dt == null) return 'no rotation yet — tap to mint';
    final local = dt.toLocal();
    final y = local.year.toString();
    final mo = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ageDays = DateTime.now().toUtc().difference(dt).inDays;
    return 'last rotated $y.$mo.$d · $hh:$mm  ($ageDays d ago)';
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

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
          '< SETTINGS',
          style: SpectreTypography.title().copyWith(
            color: SpectreColors.textCold,
            letterSpacing: 4,
            fontSize: 13,
          ),
        ),
      ),
      body: NoiseBackground(
        child: _loading
            ? Center(
                child: Text(
                  '[ loading… ]',
                  style: SpectreTypography.caption().copyWith(
                    color: SpectreColors.textDim,
                    letterSpacing: 3,
                  ),
                ),
              )
            : SafeArea(
                top: false,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    _SectionHeader(label: 'IDENTITY'),
                    _identitySection(),
                    const HairlineDivider(),
                    _SectionHeader(label: 'MESSAGES'),
                    _messagesSection(),
                    const HairlineDivider(),
                    _SectionHeader(label: 'SECURITY'),
                    _securitySection(),
                    const HairlineDivider(),
                    _SectionHeader(label: 'ABOUT'),
                    _aboutSection(),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _identitySection() {
    final id = widget.services.currentUserId ?? '——';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'display name',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              letterSpacing: 2.4,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: const BoxDecoration(
              color: SpectreColors.blackLess,
              border: Border.fromBorderSide(
                BorderSide(color: SpectreColors.hairline, width: 1),
              ),
            ),
            child: Text(
              (_displayName != null && _displayName!.isNotEmpty)
                  ? _displayName!
                  : '— not set —',
              style: SpectreTypography.mono().copyWith(
                color: (_displayName != null && _displayName!.isNotEmpty)
                    ? SpectreColors.textBright
                    : SpectreColors.textFaint,
                fontSize: 14.5,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _InlineButton(
                label: '[ EDIT NAME ]',
                color: SpectreColors.textBright,
                borderColor: SpectreColors.hairline,
                onTap: _editDisplayName,
              ),
            ],
          ),
          const SizedBox(height: 26),
          Container(height: 1, color: SpectreColors.hairline),
          const SizedBox(height: 18),
          Text(
            'spectre id',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              letterSpacing: 2.4,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            decoration: const BoxDecoration(
              color: SpectreColors.blackLess,
              border: Border.fromBorderSide(
                BorderSide(color: SpectreColors.textCold, width: 1),
              ),
            ),
            child: Text(
              _truncate(id, 12),
              style: SpectreTypography.mono().copyWith(
                color: SpectreColors.textBright,
                fontSize: 14.5,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _InlineButton(
                label: _copied ? '[ COPIED ]' : '[ COPY ID ]',
                color: _copied
                    ? SpectreColors.matrixGreen
                    : SpectreColors.textBright,
                borderColor: _copied
                    ? SpectreColors.matrixGreen
                    : SpectreColors.hairline,
                onTap: _copied ? null : _copyId,
              ),
            ],
          ),
          const SizedBox(height: 26),
          Container(height: 1, color: SpectreColors.hairline),
          const SizedBox(height: 18),
          Text(
            'signed prekey rotation',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              letterSpacing: 2.4,
            ),
          ),
          const SizedBox(height: 10),
          _InlineButton(
            label: _rotating
                ? '[ ROTATING… ]'
                : _justRotated
                    ? '[ ROTATED ✓ ]'
                    : '[ ROTATE SIGNED PREKEY ]',
            color: _justRotated
                ? SpectreColors.matrixGreen
                : SpectreColors.textCold,
            background: _justRotated
                ? SpectreColors.blackLess
                : SpectreColors.purpleHair,
            borderColor: _justRotated
                ? SpectreColors.matrixGreen
                : SpectreColors.purpleDeep,
            onTap: _rotating || _justRotated ? null : _rotatePreKey,
          ),
          const SizedBox(height: 8),
          Text(
            _formatRotation(_lastRotation),
            style: SpectreTypography.stamp().copyWith(
              color: SpectreColors.textFaint,
              letterSpacing: 1.2,
            ),
          ),
          if (_rotateError != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '[ fault :: ${_rotateError.runtimeType} ]',
              style: SpectreTypography.danger().copyWith(fontSize: 11),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'rotation bounds the medium-term forward-secrecy window. '
            'a peer who compromises a 7-day-old signed prekey can only '
            'open session inits from that window — not yesterday\'s, '
            'not tomorrow\'s. rotate weekly.',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              height: 1.7,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _messagesSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'disappearing default',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              letterSpacing: 2.4,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              for (final v in _Disappearing.values) ...<Widget>[
                Expanded(
                  child: _TimerChip(
                    label: v.label,
                    active: _disappearing == v,
                    onTap: () => _setDisappearing(v),
                  ),
                ),
                if (v != _Disappearing.values.last)
                  const SizedBox(width: 6),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'applied to new outgoing messages. existing messages are '
            'not retroactively expired.',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _securitySection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _InlineButton(
            label: '[ CHANGE DURESS PIN ]',
            color: SpectreColors.textCold,
            borderColor: SpectreColors.hairline,
            background: SpectreColors.blackLess,
            onTap: _duressTap,
          ),
          if (_duressStub) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '[ COMING IN NEXT BUILD ]',
              style: SpectreTypography.caption().copyWith(
                color: SpectreColors.textDim,
                letterSpacing: 2,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            'a duress pin triggers an instant fake-wipe if compelled '
            'to unlock under coercion.',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 22),
          Container(height: 1, color: SpectreColors.hairline),
          const SizedBox(height: 18),
          _TorRow(on: _torOn, onTap: _toggleTor),
          if (_torStub) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '[ COMING IN NEXT BUILD ]',
              style: SpectreTypography.caption().copyWith(
                color: SpectreColors.textDim,
                letterSpacing: 2,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            'routes relay traffic over the tor network. hides client '
            'ip from the relay operator.',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 22),
          Container(height: 1, color: SpectreColors.hairline),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Container(width: 8, height: 8, color: SpectreColors.redDanger),
              const SizedBox(width: 10),
              Text(
                'DANGER',
                style: SpectreTypography.danger().copyWith(letterSpacing: 4),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const DashedDivider(color: SpectreColors.redDanger),
          const SizedBox(height: 14),
          _InlineButton(
            label: _wiping ? '[ WIPING… ]' : '[ PANIC WIPE ]',
            color: SpectreColors.textBright,
            background: SpectreColors.redBlood,
            borderColor: SpectreColors.redDanger,
            fullWidth: true,
            onTap: _wiping ? null : _panicWipe,
          ),
        ],
      ),
    );
  }

  Widget _aboutSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'SPECTRE',
            style: SpectreTypography.display().copyWith(
              color: SpectreColors.textCold,
              fontSize: 32,
              letterSpacing: 8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '0.1.0-alpha',
            style: SpectreTypography.stamp().copyWith(
              color: SpectreColors.textFaint,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'spectre collects nothing.',
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.matrixGreen,
              fontSize: 13,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'signal protocol. open source crypto.',
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.textFaint,
              fontSize: 11.5,
              height: 1.7,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            'built for those who need it.',
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.textFaint,
              fontSize: 11.5,
              height: 1.7,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      color: SpectreColors.blackDeep,
      child: Row(
        children: <Widget>[
          Container(width: 6, height: 6, color: SpectreColors.purpleBright),
          const SizedBox(width: 10),
          Text(
            label,
            style: SpectreTypography.title().copyWith(
              color: SpectreColors.textCold,
              fontSize: 11,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(height: 1, color: SpectreColors.hairline),
          ),
        ],
      ),
    );
  }
}

class _TimerChip extends StatelessWidget {
  const _TimerChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? SpectreColors.blackLess : SpectreColors.blackDeep,
          border: Border.all(
            color: active ? SpectreColors.matrixGreen : SpectreColors.textFaint,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: SpectreTypography.action().copyWith(
            color: active ? SpectreColors.matrixGreen : SpectreColors.textDim,
            fontSize: 10.5,
            letterSpacing: 1.6,
          ),
        ),
      ),
    );
  }
}

class _TorRow extends StatelessWidget {
  const _TorRow({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'tor routing',
                style: SpectreTypography.title().copyWith(
                  color: on ? SpectreColors.matrixGreen : SpectreColors.textCold,
                  fontSize: 13,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                on ? 'ENABLED' : 'DISABLED',
                style: SpectreTypography.stamp().copyWith(
                  color: on
                      ? SpectreColors.matrixGreen
                      : SpectreColors.textDim,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
        _SharpToggle(value: on, onTap: onTap),
      ],
    );
  }
}

class _SharpToggle extends StatelessWidget {
  const _SharpToggle({required this.value, required this.onTap});

  final bool value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 56,
        height: 26,
        decoration: BoxDecoration(
          color: value ? SpectreColors.blackLess : SpectreColors.blackDeep,
          border: Border.all(
            color: value ? SpectreColors.matrixGreen : SpectreColors.textFaint,
            width: 1,
          ),
        ),
        child: Stack(
          children: <Widget>[
            AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              alignment:
                  value ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Container(
                  width: 16,
                  height: 18,
                  color: value
                      ? SpectreColors.matrixGreen
                      : SpectreColors.textFaint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineButton extends StatelessWidget {
  const _InlineButton({
    required this.label,
    required this.color,
    required this.borderColor,
    required this.onTap,
    this.background,
    this.fullWidth = false,
  });

  final String label;
  final Color color;
  final Color borderColor;
  final Color? background;
  final VoidCallback? onTap;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final inner = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? Colors.transparent,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Text(
        label,
        style: SpectreTypography.action().copyWith(
          color: onTap == null ? color.withValues(alpha: 0.6) : color,
          fontSize: 11.5,
        ),
      ),
    );
    final tappable = InkWell(onTap: onTap, child: inner);
    if (fullWidth) {
      return SizedBox(width: double.infinity, child: tappable);
    }
    return tappable;
  }
}

class _PanicWipeDialog extends StatelessWidget {
  const _PanicWipeDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: SpectreColors.blackLess,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: SpectreColors.redDanger, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(width: 8, height: 8, color: SpectreColors.redDanger),
                const SizedBox(width: 10),
                Text(
                  'PANIC WIPE',
                  style: SpectreTypography.danger().copyWith(letterSpacing: 4),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const DashedDivider(color: SpectreColors.redDanger),
            const SizedBox(height: 18),
            Text(
              'this will destroy:',
              style: SpectreTypography.body(),
            ),
            const SizedBox(height: 10),
            Text(
              '· identity key\n'
              '· every session\n'
              '· every prekey\n'
              '· the encrypted database\n'
              '· the relay connection',
              style: SpectreTypography.body().copyWith(
                color: SpectreColors.textDim,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'this cannot be undone.',
              style: SpectreTypography.body().copyWith(
                color: SpectreColors.redDanger,
              ),
            ),
            const SizedBox(height: 22),
            const HairlineDivider(),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        border: Border.fromBorderSide(
                          BorderSide(color: SpectreColors.hairline, width: 1),
                        ),
                      ),
                      child: Text(
                        '[ ABORT ]',
                        style: SpectreTypography.action(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: SpectreColors.redBlood,
                        border: Border.fromBorderSide(
                          BorderSide(color: SpectreColors.redDanger, width: 1),
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
          ],
        ),
      ),
    );
  }
}

/// Prefilled editor for the user's own display name. Pops the new value
/// (empty = clear) on SAVE, or null on CANCEL. Mirrors the contact nickname
/// editor; the name is shared with peers (E2E), never the relay.
class _DisplayNameDialog extends StatefulWidget {
  const _DisplayNameDialog({required this.initial});

  final String initial;

  @override
  State<_DisplayNameDialog> createState() => _DisplayNameDialogState();
}

class _DisplayNameDialogState extends State<_DisplayNameDialog> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: SpectreColors.blackLess,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: SpectreColors.purpleBright, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'DISPLAY NAME',
              style: SpectreTypography.title()
                  .copyWith(letterSpacing: 3, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'how contacts see you. shared end-to-end with people you message, '
              'never with the relay. leave empty to clear.',
              style: SpectreTypography.caption()
                  .copyWith(color: SpectreColors.textDim, height: 1.6),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _c,
              autofocus: true,
              maxLength: 40,
              cursorColor: SpectreColors.matrixGreen,
              style: SpectreTypography.mono()
                  .copyWith(color: SpectreColors.textBright),
              decoration: const InputDecoration(
                counterText: '',
                hintText: 'name',
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'CANCEL',
                    style: SpectreTypography.action()
                        .copyWith(color: SpectreColors.textDim),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_c.text),
                  child: Text(
                    'SAVE',
                    style: SpectreTypography.action()
                        .copyWith(color: SpectreColors.matrixGreen),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
