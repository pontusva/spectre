import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../../core/crypto/identity_manager.dart';
import '../../core/models/contact.dart';
import '../../core/models/conversation.dart';
import '../../core/models/message.dart';
import '../theme/app_theme.dart';
import '../theme/router.dart';

class ContactScreen extends StatefulWidget {
  const ContactScreen({
    super.key,
    required this.services,
    required this.contact,
  });

  final SpectreServices services;
  final Contact contact;

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  final ScrollController _scroll = ScrollController();

  late Contact _contact;
  List<String>? _ownWords;
  bool _canVerify = false;
  bool _justVerified = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _contact = widget.contact;
    _scroll.addListener(_onScroll);
    _loadOwnFingerprint();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybeUnlockShortPages());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadOwnFingerprint() async {
    try {
      final identity = await widget.services.identityManager.loadOrCreate();
      final pubBytes = identity.identityKeyPair.getPublicKey().serialize();
      final hash = SHA256Digest().process(pubBytes);
      final hex =
          hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final temp = Contact(
        id: '_self',
        userId: identity.userId,
        identityKeyFingerprint: hex,
        createdAt: DateTime.now(),
      );
      if (!mounted) return;
      setState(() => _ownWords = temp.fingerprintWords);
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybeUnlockShortPages());
    } catch (_) {
      // Fingerprint compute failure leaves _ownWords null; the UI shows
      // a "[ deriving… ]" placeholder. Verification remains locked
      // because comparison is impossible without our half of the words.
    }
  }

  void _onScroll() {
    if (_canVerify) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 4) {
      setState(() => _canVerify = true);
    }
  }

  void _maybeUnlockShortPages() {
    if (_canVerify) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent <= 0) {
      setState(() => _canVerify = true);
    }
  }

  Future<void> _markVerified() async {
    if (_busy || !_canVerify) return;
    setState(() => _busy = true);
    await widget.services.database
        .updateContactVerified(_contact.userId, true);
    if (!mounted) return;
    setState(() {
      _contact = _contact.copyWith(isVerified: true);
      _justVerified = true;
      _busy = false;
    });
  }

  Future<void> _editNickname() async {
    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (ctx) => _NicknameDialog(initial: _contact.displayName ?? ''),
    );
    if (result == null || !mounted) return; // cancelled
    final trimmed = result.trim();
    await widget.services.database
        .updateContactDisplayName(_contact.userId, trimmed.isEmpty ? null : trimmed);
    // Re-fetch rather than copyWith: Contact.copyWith uses `?? this.displayName`
    // and so cannot clear the nickname back to null.
    final fresh = await widget.services.database.getContact(_contact.userId);
    if (!mounted || fresh == null) return;
    setState(() => _contact = fresh);
  }

  Future<void> _reVerify() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.services.database
        .updateContactVerified(_contact.userId, false);
    if (!mounted) return;
    setState(() {
      _contact = _contact.copyWith(isVerified: false);
      _justVerified = false;
      _canVerify = false;
      _busy = false;
    });
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _confirmAndDelete() async {
    // Count cascades client-side via the listed API — getConversations()
    // then getMessages() for the ones tied to this peer. Conversation
    // lists are bounded by the number of peers a user actually talks
    // to so the scan is acceptable.
    final allConvs = await widget.services.database.getConversations();
    final matching =
        allConvs.where((Conversation c) => c.recipientId == _contact.userId).toList();
    int messageCount = 0;
    for (final c in matching) {
      final msgs = await widget.services.database.getMessages(c.id);
      messageCount += msgs.length;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.78),
      builder: (ctx) => _DeleteConfirmDialog(
        contactLabel: _truncate(_contact.userId, 8),
        conversationCount: matching.length,
        messageCount: messageCount,
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    // deleteContact wipes contact + cascade-removes all conversations
    // and their messages atomically inside SecureDatabase.
    await widget.services.database.deleteContact(_contact.userId);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  String _dateString(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString();
    final mo = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y.$mo.$d · $hh:$mm';
  }

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
          'PEER BRIEFING',
          style: SpectreTypography.title().copyWith(letterSpacing: 4),
        ),
      ),
      body: NoiseBackground(
        child: Column(
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (_contact.isVerified)
                      _VerifiedHeader(
                        verifiedAt: _contact.createdAt,
                        justVerified: _justVerified,
                        dateString: _dateString(_contact.createdAt),
                      )
                    else
                      _UnverifiedHeader(contact: _contact),
                    const SizedBox(height: 16),
                    _NicknameRow(
                      displayName: _contact.displayName,
                      onEdit: _busy ? null : _editNickname,
                    ),
                    const SizedBox(height: 20),
                    const DashedDivider(),
                    const SizedBox(height: 22),
                    Text(
                      'READ ALOUD. COMPARE. TRUST NOTHING ELSE.',
                      style: SpectreTypography.title().copyWith(
                        color: SpectreColors.textBright,
                        fontSize: 12.5,
                        letterSpacing: 3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'these words are derived from the long-term identity '
                      'key. they cannot be forged without breaking sha-256.',
                      style: SpectreTypography.caption().copyWith(
                        color: SpectreColors.textDim,
                        height: 1.7,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _WordsComparison(
                      ownWords: _ownWords,
                      theirWords: _contact.fingerprintWords,
                    ),
                    const SizedBox(height: 22),
                    const _VerificationProtocolBox(),
                    const SizedBox(height: 26),
                    if (_contact.isVerified)
                      _ActionButton(
                        label: '[ RE-VERIFY ]',
                        color: SpectreColors.purpleHair,
                        borderColor: SpectreColors.purpleDeep,
                        textColor: SpectreColors.textCold,
                        enabled: !_busy,
                        onTap: _reVerify,
                      )
                    else
                      _ActionButton(
                        label: _canVerify
                            ? '[ MARK AS VERIFIED ]'
                            : '[ SCROLL TO CONFIRM ]',
                        color: _canVerify
                            ? SpectreColors.purpleDeep
                            : SpectreColors.blackHair,
                        borderColor: _canVerify
                            ? SpectreColors.matrixGreen
                            : SpectreColors.hairline,
                        textColor: _canVerify
                            ? SpectreColors.textBright
                            : SpectreColors.textDim,
                        enabled: _canVerify && !_busy,
                        onTap: _markVerified,
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            if (!_contact.isVerified) const _UnverifiedWarningBanner(),
            _DeleteFooter(
              onTap: _busy ? null : _confirmAndDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _UnverifiedHeader extends StatelessWidget {
  const _UnverifiedHeader({required this.contact});

  final Contact contact;

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(width: 10, height: 10, color: SpectreColors.redDanger),
            const SizedBox(width: 12),
            Text(
              'UNVERIFIED PEER',
              style: SpectreTypography.danger().copyWith(letterSpacing: 4),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'spectre id',
          style: SpectreTypography.caption().copyWith(
            color: SpectreColors.textDim,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: const BoxDecoration(
            color: SpectreColors.blackLess,
            border: Border.fromBorderSide(
              BorderSide(color: SpectreColors.textCold, width: 1),
            ),
          ),
          child: SelectableText(
            _truncate(contact.userId, 8),
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.textBright,
              fontSize: 16,
              letterSpacing: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'partial id only.',
          style: SpectreTypography.caption().copyWith(
            color: SpectreColors.textDim,
            letterSpacing: 1.2,
            height: 1.6,
          ),
        ),
        Text(
          'never display full id in notifications or previews.',
          style: SpectreTypography.caption().copyWith(
            color: SpectreColors.textDim,
            letterSpacing: 1.2,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}

class _VerifiedHeader extends StatelessWidget {
  const _VerifiedHeader({
    required this.verifiedAt,
    required this.justVerified,
    required this.dateString,
  });

  final DateTime verifiedAt;
  final bool justVerified;
  final String dateString;

  @override
  Widget build(BuildContext context) {
    final stamp = _VerifiedStamp(animated: justVerified);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        stamp,
        const SizedBox(height: 10),
        Text(
          'verified out-of-band since $dateString',
          style: SpectreTypography.caption().copyWith(
            color: SpectreColors.textDim,
            letterSpacing: 1.4,
          ),
        ),
      ],
    );
  }
}

class _VerifiedStamp extends StatelessWidget {
  const _VerifiedStamp({required this.animated});

  final bool animated;

  @override
  Widget build(BuildContext context) {
    final core = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: SpectreColors.blackLess,
        border: Border.all(color: SpectreColors.matrixGreen, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(width: 8, height: 8, color: SpectreColors.matrixGreen),
          const SizedBox(width: 10),
          Text(
            'VERIFIED ✓',
            style: SpectreTypography.title().copyWith(
              color: SpectreColors.matrixGreen,
              fontSize: 14,
              letterSpacing: 4,
            ),
          ),
        ],
      ),
    );

    if (!animated) return core;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutBack,
      builder: (ctx, t, child) {
        final clamped = t.clamp(0.0, 1.0);
        return Opacity(
          opacity: clamped,
          child: Transform.scale(
            scale: 0.7 + 0.3 * clamped,
            child: child,
          ),
        );
      },
      child: core,
    );
  }
}

class _WordsComparison extends StatelessWidget {
  const _WordsComparison({required this.ownWords, required this.theirWords});

  final List<String>? ownWords;
  final List<String> theirWords;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: SpectreColors.blackLess,
        border: Border.fromBorderSide(
          BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: _WordColumn(
                label: 'YOUR WORDS',
                accent: SpectreColors.matrixDim,
                words: ownWords,
              ),
            ),
            Container(width: 1, color: SpectreColors.hairline),
            Expanded(
              child: _WordColumn(
                label: 'THEIR WORDS',
                accent: SpectreColors.purpleBright,
                words: theirWords,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WordColumn extends StatelessWidget {
  const _WordColumn({
    required this.label,
    required this.accent,
    required this.words,
  });

  final String label;
  final Color accent;
  final List<String>? words;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(width: 6, height: 6, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: SpectreTypography.title().copyWith(
                    color: SpectreColors.textBright,
                    fontSize: 11.5,
                    letterSpacing: 3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: SpectreColors.hairline),
          const SizedBox(height: 10),
          if (words == null)
            Text(
              '[ deriving… ]',
              style: SpectreTypography.caption().copyWith(
                color: SpectreColors.textFaint,
                letterSpacing: 2,
              ),
            )
          else
            ..._buildRows(words!),
        ],
      ),
    );
  }

  List<Widget> _buildRows(List<String> words) {
    final rows = <Widget>[];
    for (var i = 0; i < words.length; i++) {
      rows.add(_row(i + 1, words[i],
          dim: (i % 4) == 3 && i != words.length - 1));
    }
    return rows;
  }

  Widget _row(int number, String word, {required bool dim}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: dim ? SpectreColors.hairline : Colors.transparent,
            width: 1,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          SizedBox(
            width: 22,
            child: Text(
              number.toString().padLeft(2, '0'),
              style: SpectreTypography.stamp().copyWith(
                color: SpectreColors.textFaint,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: Text(
              word,
              style: SpectreTypography.mono().copyWith(
                color: SpectreColors.textCold,
                fontSize: 12.5,
                letterSpacing: 0.4,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _VerificationProtocolBox extends StatelessWidget {
  const _VerificationProtocolBox();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: const BoxDecoration(
        color: Color(0xFF1A0606),
        border: Border.fromBorderSide(
          BorderSide(color: SpectreColors.redDecay, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(width: 6, height: 6, color: SpectreColors.redDanger),
              const SizedBox(width: 8),
              Text(
                'PROTOCOL',
                style: SpectreTypography.danger().copyWith(
                  fontSize: 11,
                  letterSpacing: 3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'call them on a line you trust.',
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.redDecay,
              height: 1.7,
              fontSize: 12.5,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            'read your words.',
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.redDecay,
              height: 1.7,
              fontSize: 12.5,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            'have them read theirs.',
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.redDecay,
              height: 1.7,
              fontSize: 12.5,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            'if they match: verified.',
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.matrixGreen,
              height: 1.7,
              fontSize: 12.5,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            'if they don\'t: assume compromise.',
            style: SpectreTypography.mono().copyWith(
              color: SpectreColors.redDanger,
              height: 1.7,
              fontSize: 12.5,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _UnverifiedWarningBanner extends StatelessWidget {
  const _UnverifiedWarningBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: SpectreColors.redBlood,
        border: Border(
          top: BorderSide(color: SpectreColors.redDanger, width: 1),
          bottom: BorderSide(color: SpectreColors.redDanger, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(width: 8, height: 8, color: SpectreColors.textBright),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'UNVERIFIED — ENCRYPTED BUT IDENTITY UNCONFIRMED',
              style: SpectreTypography.action().copyWith(
                color: SpectreColors.textBright,
                fontSize: 11,
                letterSpacing: 2,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeleteFooter extends StatelessWidget {
  const _DeleteFooter({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: SpectreColors.blackDeep,
        border: Border(
          top: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            alignment: Alignment.center,
            child: Text(
              '[ DELETE CONTACT ]',
              style: SpectreTypography.action().copyWith(
                color: onTap == null
                    ? SpectreColors.textFaint
                    : SpectreColors.redDecay,
                letterSpacing: 3,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeleteConfirmDialog extends StatelessWidget {
  const _DeleteConfirmDialog({
    required this.contactLabel,
    required this.conversationCount,
    required this.messageCount,
  });

  final String contactLabel;
  final int conversationCount;
  final int messageCount;

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
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  color: SpectreColors.redDanger,
                ),
                const SizedBox(width: 10),
                Text(
                  'DELETE CONTACT',
                  style: SpectreTypography.danger().copyWith(letterSpacing: 4),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const DashedDivider(color: SpectreColors.redDanger),
            const SizedBox(height: 16),
            Text(
              'peer :: $contactLabel…',
              style: SpectreTypography.mono().copyWith(
                color: SpectreColors.textBright,
                fontSize: 13,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'this will destroy:',
              style: SpectreTypography.body(),
            ),
            const SizedBox(height: 8),
            Text(
              '· the contact record\n'
              '· $conversationCount conversation${conversationCount == 1 ? '' : 's'}\n'
              '· $messageCount message${messageCount == 1 ? '' : 's'} (ciphertext)',
              style: SpectreTypography.mono().copyWith(
                color: SpectreColors.textCold,
                fontSize: 12.5,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'session keys for this peer will not be re-derivable from '
              'local state.',
              style: SpectreTypography.caption().copyWith(
                color: SpectreColors.textDim,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 22),
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
                        '[ DESTROY ]',
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

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.color,
    required this.borderColor,
    required this.textColor,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color borderColor;
  final Color textColor;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? color : SpectreColors.blackHair,
          border: Border.all(
            color: enabled ? borderColor : SpectreColors.hairline,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: SpectreTypography.action().copyWith(
            color: enabled ? textColor : SpectreColors.textDim,
          ),
        ),
      ),
    );
  }
}

/// Read-only row showing the contact's local nickname (or "— none —") with an
/// [ EDIT ] affordance. Nickname is local-only; see updateContactDisplayName.
class _NicknameRow extends StatelessWidget {
  const _NicknameRow({required this.displayName, required this.onEdit});

  final String? displayName;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final has = displayName != null && displayName!.isNotEmpty;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'nickname (local only)',
                style: SpectreTypography.caption().copyWith(
                  color: SpectreColors.textDim,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                has ? displayName! : '— none —',
                style: SpectreTypography.mono().copyWith(
                  color: has ? SpectreColors.textBright : SpectreColors.textFaint,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        InkWell(
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '[ EDIT ]',
              style: SpectreTypography.action().copyWith(
                color: SpectreColors.purpleBright,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Prefilled nickname editor. Pops the new value (empty string = clear) on
/// SAVE, or null on CANCEL.
class _NicknameDialog extends StatefulWidget {
  const _NicknameDialog({required this.initial});

  final String initial;

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
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
              'SET NICKNAME',
              style: SpectreTypography.title()
                  .copyWith(letterSpacing: 3, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'local label, stored only on this device. leave empty to clear.',
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
              decoration: const InputDecoration(hintText: 'nickname'),
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
