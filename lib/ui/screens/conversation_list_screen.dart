import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/contact.dart';
import '../../core/models/conversation.dart';
import '../../core/storage/secure_database.dart';
import '../../services/message_service.dart';
import '../theme/app_theme.dart';
import '../theme/router.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({
    super.key,
    required this.messageService,
    required this.database,
    required this.currentUserId,
    required this.onOpenConversation,
    required this.onOpenSettings,
    this.onWiped,
  });

  final MessageService messageService;
  final SecureDatabase database;
  final String currentUserId;
  final Future<void> Function(Conversation conversation) onOpenConversation;
  final VoidCallback onOpenSettings;
  final VoidCallback? onWiped;

  @override
  State<ConversationListScreen> createState() =>
      _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen>
    with RouteAware {
  final Uuid _uuid = const Uuid();
  List<Conversation> _conversations = <Conversation>[];
  // Pending message-requests (inbound from peers not yet accepted).
  List<Conversation> _requests = <Conversation>[];
  // userId -> Contact, for resolving nicknames in tiles (one batch query).
  Map<String, Contact> _contacts = <String, Contact>{};
  bool _loading = true;
  bool _wiping = false;
  StreamSubscription<DecryptedMessage>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = widget.messageService.decryptedMessages.listen((_) {
      if (mounted) _load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      spectreRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    // Returned to the list (a chat/contact screen popped). Reload so nickname
    // edits, accepts/blocks, and new requests show without waiting for an
    // incoming message.
    _load();
  }

  @override
  void dispose() {
    spectreRouteObserver.unsubscribe(this);
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final convs = await widget.database.getConversations();
    final requests = await widget.database.getRequests();
    final contacts = await widget.database.getAllContacts();
    if (!mounted) return;
    setState(() {
      _conversations = convs;
      _requests = requests;
      _contacts = {for (final c in contacts) c.userId: c};
      _loading = false;
    });
  }

  /// Label for a conversation: the peer's nickname if set, else the truncated
  /// id (Conversation.displayName).
  String _labelFor(Conversation c) =>
      peerLabel(_contacts[c.recipientId], c.displayName);

  /// Open a conversation and reload on return. The reload is what makes a
  /// nickname set on the contact screen (reached via the chat) show up here
  /// the moment you come back — not only after the peer next messages you.
  Future<void> _open(Conversation c) async {
    await widget.onOpenConversation(c);
    if (mounted) await _load();
  }

  Future<void> _confirmAndWipe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.85),
      builder: (ctx) => const _PanicWipeDialog(),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _wiping = true);
    await widget.messageService.panicWipe();
    if (!mounted) return;
    if (widget.onWiped != null) {
      widget.onWiped!();
    } else {
      await SystemNavigator.pop();
    }
  }

  Future<void> _startNewConversation() async {
    final recipientId = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (ctx) => const _NewConversationDialog(),
    );
    if (recipientId == null || recipientId.isEmpty || !mounted) return;

    // State-agnostic lookup so re-adding a pending/blocked peer is found.
    final existing = await widget.database.getConversationByRecipient(recipientId);
    if (existing == null) {
      // New peer: send a connection request now (establishes the session and
      // sends a canned first message that lands in their Requests inbox).
      final status = await widget.messageService.sendInvitation(recipientId);
      if (!mounted) return;
      if (status == MessageStatus.failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'could not send request — peer not reachable or not registered yet'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
    await _load();
    if (!mounted) return;

    // Open the conversation (created by the invitation, or pre-existing). Fall
    // back to a local row if the invite couldn't create one (peer unreachable)
    // so the user still lands in the chat and can retry from there.
    var conversation =
        await widget.database.getConversationByRecipient(recipientId);
    if (conversation == null) {
      conversation = Conversation(
        id: _uuid.v4(),
        recipientId: recipientId,
        recipientPublicKey: '',
        lastMessageAt: null,
      );
      await widget.database.insertConversation(conversation);
    }
    await _open(conversation);
  }

  Future<void> _onLongPress(Conversation c) async {
    final action = await showModalBottomSheet<_TileAction>(
      context: context,
      backgroundColor: SpectreColors.blackLess,
      barrierColor: Colors.black.withOpacity(0.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: SpectreColors.hairline, width: 1),
      ),
      builder: (ctx) =>
          _ConversationActionsSheet(conversation: c, label: _labelFor(c)),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _TileAction.archive:
        // insertConversation uses upsert semantics — flipping isArchived
        // on the existing row.
        await widget.database
            .insertConversation(c.copyWith(isArchived: true));
        break;
      case _TileAction.delete:
        // Cascade deletes the linked messages via the FK ON DELETE
        // CASCADE inside SecureDatabase.
        await widget.database.deleteConversation(c.id);
        break;
    }
    await _load();
  }

  Future<void> _onRequest(Conversation c) async {
    final action = await showModalBottomSheet<_RequestAction>(
      context: context,
      backgroundColor: SpectreColors.blackLess,
      barrierColor: Colors.black.withOpacity(0.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: SpectreColors.hairline, width: 1),
      ),
      builder: (ctx) => _RequestActionsSheet(label: _labelFor(c)),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _RequestAction.accept:
        // Promote to the main Chats list.
        await widget.database
            .updateConversationState(c.id, ConversationRequestState.accepted);
        break;
      case _RequestAction.block:
        // Hide + drop future inbound. Keep the row — it IS the blocklist;
        // deleting it would let the next message recreate a fresh request.
        await widget.database
            .updateConversationState(c.id, ConversationRequestState.blocked);
        break;
    }
    await _load();
  }

  String _formatTimestamp(DateTime? dt) {
    if (dt == null) return '——';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    if (msgDay == today) {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
    final yesterday = today.subtract(const Duration(days: 1));
    if (msgDay == yesterday) return 'yday';
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$mo.$d';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: false,
      backgroundColor: SpectreColors.blackDeep,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('SPECTRE',
                style: SpectreTypography.display().copyWith(fontSize: 16)),
            const SizedBox(width: 10),
            Container(
              width: 6,
              height: 6,
              color: SpectreColors.matrixGreen,
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'settings · your ID',
            onPressed: _wiping ? null : widget.onOpenSettings,
            icon: const Icon(Icons.settings_outlined,
                color: SpectreColors.textCold, size: 22),
          ),
          IconButton(
            tooltip: 'panic wipe',
            onPressed: _wiping ? null : _confirmAndWipe,
            icon: const Icon(Icons.lock_outline,
                color: SpectreColors.redDanger, size: 22),
          ),
          const SizedBox(width: 6),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _wiping ? null : _startNewConversation,
        tooltip: 'new conversation',
        child: const Icon(Icons.add, size: 22),
      ),
      body: NoiseBackground(
        child: SafeArea(
          top: false,
          child: RefreshIndicator(
            color: SpectreColors.purpleBright,
            backgroundColor: SpectreColors.blackLess,
            onRefresh: _load,
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return ListView(
        children: const <Widget>[
          SizedBox(height: 120),
          Center(
            child: Text(
              '[ loading… ]',
              style: TextStyle(
                color: SpectreColors.textDim,
                fontFamily: 'JetBrainsMono',
                letterSpacing: 2,
              ),
            ),
          ),
        ],
      );
    }

    if (_conversations.isEmpty && _requests.isEmpty) {
      return ListView(
        children: <Widget>[
          const SizedBox(height: 80),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '─── no sessions ───',
                  style: SpectreTypography.caption().copyWith(
                    color: SpectreColors.textDim,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'this device is silent.',
                  style: SpectreTypography.body(),
                ),
                const SizedBox(height: 6),
                Text(
                  'tap [+] to begin.',
                  style: SpectreTypography.body().copyWith(
                    color: SpectreColors.textDim,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Assemble: REQUESTS section (if any) above the SESSIONS section.
    final items = <Widget>[];
    if (_requests.isNotEmpty) {
      items.add(_RequestsHeader(count: _requests.length));
      for (final c in _requests) {
        items.add(_ConversationTile(
          conversation: c,
          label: _labelFor(c),
          timestampLabel: _formatTimestamp(c.lastMessageAt),
          // Tap to read the request; long-press to accept / block.
          onTap: () => _open(c),
          onLongPress: () => _onRequest(c),
        ));
      }
    }
    items.add(const _ListHeader());
    for (final c in _conversations) {
      items.add(_ConversationTile(
        conversation: c,
        label: _labelFor(c),
        timestampLabel: _formatTimestamp(c.lastMessageAt),
        onTap: () => _open(c),
        onLongPress: () => _onLongPress(c),
      ));
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (ctx, idx) => const HairlineDivider(),
      itemBuilder: (ctx, idx) => items[idx],
    );
  }
}

class _ListHeader extends StatelessWidget {
  const _ListHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      color: SpectreColors.blackDeep,
      child: Row(
        children: <Widget>[
          Text('SESSIONS',
              style: SpectreTypography.caption().copyWith(
                color: SpectreColors.textDim,
                letterSpacing: 3,
              )),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: SpectreColors.hairline,
            ),
          ),
        ],
      ),
    );
  }
}

/// Header for the message-requests section, with a count badge. Tinted with
/// the accent colour to distinguish it from SESSIONS, and hints the gesture.
class _RequestsHeader extends StatelessWidget {
  const _RequestsHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      color: SpectreColors.blackDeep,
      child: Row(
        children: <Widget>[
          Text('REQUESTS',
              style: SpectreTypography.caption().copyWith(
                color: SpectreColors.purpleBright,
                letterSpacing: 3,
              )),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            color: SpectreColors.purpleDeep,
            child: Text('$count',
                style: SpectreTypography.stamp()
                    .copyWith(color: SpectreColors.textBright)),
          ),
          const SizedBox(width: 10),
          Text('long-press to accept / block',
              style: SpectreTypography.stamp()
                  .copyWith(color: SpectreColors.textFaint)),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: SpectreColors.hairline)),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.label,
    required this.timestampLabel,
    required this.onTap,
    required this.onLongPress,
  });

  final Conversation conversation;
  /// Resolved peer label (nickname if set, else truncated id).
  final String label;
  final String timestampLabel;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final hasUnread = conversation.unreadCount > 0;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      highlightColor: SpectreColors.purpleHair,
      splashColor: SpectreColors.purpleDeep.withOpacity(0.2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        color: Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 3,
              height: 36,
              color: hasUnread
                  ? SpectreColors.purpleBright
                  : SpectreColors.blackHair,
              margin: const EdgeInsets.only(right: 14, top: 2),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          label,
                          style: SpectreTypography.title().copyWith(
                            fontSize: 14,
                            color: hasUnread
                                ? SpectreColors.textBright
                                : SpectreColors.textCold,
                          ),
                        ),
                      ),
                      Text(
                        timestampLabel,
                        style: SpectreTypography.stamp(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Text('::',
                          style: SpectreTypography.caption().copyWith(
                            color: SpectreColors.textFaint,
                            letterSpacing: 1,
                          )),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'encrypted session',
                          style: SpectreTypography.caption(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread) ...<Widget>[
                        const SizedBox(width: 8),
                        _UnreadBadge(count: conversation.unreadCount),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final display = count > 99 ? '99+' : count.toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: const BoxDecoration(
        color: SpectreColors.redBlood,
        border: Border.fromBorderSide(
          BorderSide(color: SpectreColors.redDanger, width: 1),
        ),
      ),
      child: Text(
        display,
        style: SpectreTypography.badge().copyWith(
          color: SpectreColors.textBright,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

enum _TileAction { archive, delete }

enum _RequestAction { accept, block }

class _ConversationActionsSheet extends StatelessWidget {
  const _ConversationActionsSheet({
    required this.conversation,
    required this.label,
  });

  final Conversation conversation;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      color: SpectreColors.blackLess,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(width: 6, height: 6, color: SpectreColors.purpleBright),
              const SizedBox(width: 10),
              Text(
                label.toUpperCase(),
                style: SpectreTypography.title().copyWith(fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('actions',
              style: SpectreTypography.caption().copyWith(letterSpacing: 3)),
          const SizedBox(height: 14),
          const HairlineDivider(),
          _SheetButton(
            label: '[ ARCHIVE ]',
            color: SpectreColors.textBright,
            onTap: () => Navigator.of(context).pop(_TileAction.archive),
          ),
          const HairlineDivider(),
          _SheetButton(
            label: '[ DELETE  ]',
            color: SpectreColors.redDanger,
            onTap: () => Navigator.of(context).pop(_TileAction.delete),
          ),
          const HairlineDivider(),
          const SizedBox(height: 14),
          _SheetButton(
            label: 'cancel',
            color: SpectreColors.textDim,
            small: true,
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _RequestActionsSheet extends StatelessWidget {
  const _RequestActionsSheet({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      color: SpectreColors.blackLess,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(width: 6, height: 6, color: SpectreColors.purpleBright),
              const SizedBox(width: 10),
              Text(
                label.toUpperCase(),
                style: SpectreTypography.title().copyWith(fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('message request',
              style: SpectreTypography.caption().copyWith(letterSpacing: 3)),
          const SizedBox(height: 14),
          const HairlineDivider(),
          _SheetButton(
            label: '[ ACCEPT ]',
            color: SpectreColors.matrixGreen,
            onTap: () => Navigator.of(context).pop(_RequestAction.accept),
          ),
          const HairlineDivider(),
          _SheetButton(
            label: '[ BLOCK  ]',
            color: SpectreColors.redDanger,
            onTap: () => Navigator.of(context).pop(_RequestAction.block),
          ),
          const HairlineDivider(),
          const SizedBox(height: 14),
          _SheetButton(
            label: 'cancel',
            color: SpectreColors.textDim,
            small: true,
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.onTap,
    required this.color,
    this.small = false,
  });

  final String label;
  final VoidCallback onTap;
  final Color color;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      highlightColor: SpectreColors.purpleHair,
      splashColor: SpectreColors.purpleDeep.withOpacity(0.25),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(vertical: small ? 10 : 16),
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: SpectreTypography.action().copyWith(
            color: color,
            fontSize: small ? 11 : 13,
          ),
        ),
      ),
    );
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
      child: Container(
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

class _NewConversationDialog extends StatefulWidget {
  const _NewConversationDialog();

  @override
  State<_NewConversationDialog> createState() => _NewConversationDialogState();
}

class _NewConversationDialogState extends State<_NewConversationDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final id = _controller.text.trim();
    if (id.isEmpty) return;
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: SpectreColors.blackLess,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: SpectreColors.purpleBright, width: 1),
      ),
      child: Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(width: 8, height: 8, color: SpectreColors.purpleBright),
                const SizedBox(width: 10),
                Text('NEW SESSION',
                    style: SpectreTypography.title().copyWith(letterSpacing: 4)),
              ],
            ),
            const SizedBox(height: 14),
            const DashedDivider(color: SpectreColors.purpleBright),
            const SizedBox(height: 18),
            Text('recipient id', style: SpectreTypography.caption()),
            const SizedBox(height: 6),
            TextField(
              controller: _controller,
              autofocus: true,
              style: SpectreTypography.mono().copyWith(
                color: SpectreColors.textBright,
                letterSpacing: 0.6,
              ),
              cursorWidth: 2,
              cursorColor: SpectreColors.matrixGreen,
              decoration: const InputDecoration(
                hintText: 'base64url …',
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                Expanded(
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        border: Border.fromBorderSide(
                          BorderSide(color: SpectreColors.hairline, width: 1),
                        ),
                      ),
                      child: Text('[ CANCEL ]',
                          style: SpectreTypography.action().copyWith(
                            color: SpectreColors.textDim,
                          )),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: _submit,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: SpectreColors.purpleDeep,
                        border: Border.fromBorderSide(
                          BorderSide(color: SpectreColors.purpleBright, width: 1),
                        ),
                      ),
                      child: Text(
                        '[ OPEN ]',
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
