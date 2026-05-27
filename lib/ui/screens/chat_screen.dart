import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/models/message.dart';
import '../../core/storage/secure_database.dart';
import '../../services/message_service.dart';
import '../theme/app_theme.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.recipientId,
    required this.currentUserId,
    required this.messageService,
    required this.database,
  });

  final String conversationId;
  final String recipientId;
  final String currentUserId;
  final MessageService messageService;
  final SecureDatabase database;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  final List<_ChatItem> _items = <_ChatItem>[];
  final Set<String> _knownIds = <String>{};
  StreamSubscription<DecryptedMessage>? _sub;
  bool _sending = false;
  bool _loading = true;

  String get _truncatedRecipient {
    final r = widget.recipientId;
    if (r.length <= 12) return r;
    return '${r.substring(0, 12)}…';
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _sub = widget.messageService.decryptedMessages.listen(_onIncoming);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await widget.database.getMessages(widget.conversationId);
    if (!mounted) return;
    setState(() {
      for (final msg in history) {
        if (_knownIds.add(msg.id)) {
          _items.add(_ChatItem(
            id: msg.id,
            isMine: msg.senderId == widget.currentUserId,
            senderId: msg.senderId,
            timestamp: msg.timestamp,
            expiresAt: msg.expiresAt,
            plaintext: null,
            status: msg.senderId == widget.currentUserId ? _Status.sent : null,
          ));
        }
      }
      _loading = false;
    });
    _scrollToBottom();
  }

  void _onIncoming(DecryptedMessage dm) {
    if (dm.conversationId != widget.conversationId) return;
    if (!mounted) return;
    setState(() {
      if (_knownIds.add(dm.id)) {
        _items.add(_ChatItem(
          id: dm.id,
          isMine: false,
          senderId: dm.senderId,
          timestamp: dm.timestamp,
          expiresAt: null,
          plaintext: dm.plaintext,
        ));
      } else {
        for (var i = 0; i < _items.length; i++) {
          if (_items[i].id == dm.id) {
            _items[i] = _items[i].copyWith(plaintext: dm.plaintext);
            break;
          }
        }
      }
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    final localId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final timestamp = DateTime.now().toUtc();
    setState(() {
      _sending = true;
      _items.add(_ChatItem(
        id: localId,
        isMine: true,
        senderId: widget.currentUserId,
        timestamp: timestamp,
        expiresAt: null,
        plaintext: text,
        status: _Status.sending,
      ));
    });
    _scrollToBottom();

    MessageStatus result;
    try {
      result = await widget.messageService
          .sendMessage(widget.recipientId, text);
    } catch (_) {
      result = MessageStatus.failed;
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      for (var i = 0; i < _items.length; i++) {
        if (_items[i].id == localId) {
          _items[i] = _items[i].copyWith(status: result.toUi());
          break;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SpectreColors.blackDeep,
      appBar: AppBar(
        title: _GlitchTitle(text: 'SPECTRE'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text(
                _truncatedRecipient,
                style: SpectreTypography.caption().copyWith(
                  color: SpectreColors.textCold,
                  letterSpacing: 1.6,
                ),
              ),
            ),
          ),
        ],
      ),
      body: NoiseBackground(
        child: SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              const _SessionMetaBar(),
              Expanded(child: _buildList()),
              _ComposerBar(
                controller: _input,
                focusNode: _inputFocus,
                onSend: _send,
                sending: _sending,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return Center(
        child: Text(
          '[ syncing… ]',
          style: SpectreTypography.caption().copyWith(letterSpacing: 3),
        ),
      );
    }
    if (_items.isEmpty) {
      return _EmptyChatState(recipientId: widget.recipientId);
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
      itemCount: _items.length,
      itemBuilder: (ctx, i) {
        final item = _items[i];
        final previous = i > 0 ? _items[i - 1] : null;
        final showDateGutter = previous == null ||
            !_sameDay(previous.timestamp, item.timestamp);
        return Column(
          children: <Widget>[
            if (showDateGutter) _DateGutter(timestamp: item.timestamp),
            _MessageBubble(item: item),
          ],
        );
      },
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _SessionMetaBar extends StatelessWidget {
  const _SessionMetaBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: const BoxDecoration(
        color: SpectreColors.blackLess,
        border: Border(
          bottom: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(width: 6, height: 6, color: SpectreColors.matrixGreen),
          const SizedBox(width: 8),
          Text(
            'session :: sealed sender · e2ee · ratchet',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textDim,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _DateGutter extends StatelessWidget {
  const _DateGutter({required this.timestamp});

  final DateTime timestamp;

  String _label() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final t = DateTime(timestamp.year, timestamp.month, timestamp.day);
    if (t == today) return 'today';
    if (today.difference(t).inDays == 1) return 'yesterday';
    final mo = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '${t.year}.$mo.$d';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: <Widget>[
          Expanded(child: Container(height: 1, color: SpectreColors.hairline)),
          const SizedBox(width: 10),
          Text(
            _label(),
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textFaint,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: SpectreColors.hairline)),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.item});

  final _ChatItem item;

  String _formatTime(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final isMine = item.isMine;
    final bubbleColor =
        isMine ? SpectreColors.purpleDeep : SpectreColors.blackHair;
    final borderColor =
        isMine ? SpectreColors.purpleBright : SpectreColors.hairline;
    final textColor =
        isMine ? SpectreColors.textBright : SpectreColors.textCold;

    final body = item.plaintext ?? '[ ciphertext — restart cleared cache ]';
    final isCipherFallback = item.plaintext == null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!isMine)
            Container(
              width: 2,
              height: 36,
              color: SpectreColors.purpleBright,
              margin: const EdgeInsets.only(right: 8, top: 4),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            child: Column(
              crossAxisAlignment:
                  isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    border: Border.all(color: borderColor, width: 1),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: SelectableText(
                    body,
                    style: SpectreTypography.mono().copyWith(
                      color: isCipherFallback
                          ? SpectreColors.textFaint
                          : textColor,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
                if (item.expiresAt != null) ...<Widget>[
                  const SizedBox(height: 4),
                  _DecayBar(
                    startedAt: item.timestamp,
                    expiresAt: item.expiresAt!,
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      _formatTime(item.timestamp.toLocal()),
                      style: SpectreTypography.stamp(),
                    ),
                    if (isMine) ...<Widget>[
                      const SizedBox(width: 8),
                      _StatusGlyph(status: item.status ?? _Status.sent),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.status});

  final _Status status;

  @override
  Widget build(BuildContext context) {
    late final String glyph;
    late final Color color;
    late final String label;
    switch (status) {
      case _Status.sending:
        glyph = SpectreIcons.dotEmpty;
        color = SpectreColors.textDim;
        label = 'sending';
        break;
      case _Status.sent:
        glyph = SpectreIcons.dotFilled;
        color = SpectreColors.matrixGreen;
        label = 'sent';
        break;
      case _Status.delivered:
        glyph = SpectreIcons.dotFilled;
        color = SpectreColors.matrixGreen;
        label = 'delivered';
        break;
      case _Status.pending:
        glyph = SpectreIcons.dotEmpty;
        color = SpectreColors.textDim;
        label = 'queued';
        break;
      case _Status.failed:
        glyph = SpectreIcons.warning;
        color = SpectreColors.redDanger;
        label = 'failed';
        break;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(glyph,
            style: SpectreTypography.stamp().copyWith(color: color, fontSize: 11)),
        const SizedBox(width: 4),
        Text(label,
            style: SpectreTypography.stamp().copyWith(color: color)),
      ],
    );
  }
}

class _DecayBar extends StatefulWidget {
  const _DecayBar({required this.startedAt, required this.expiresAt});

  final DateTime startedAt;
  final DateTime expiresAt;

  @override
  State<_DecayBar> createState() => _DecayBarState();
}

class _DecayBarState extends State<_DecayBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalMs =
        widget.expiresAt.difference(widget.startedAt).inMilliseconds;
    if (totalMs <= 0) {
      return const SizedBox(height: 2);
    }
    final elapsedMs = DateTime.now()
        .toUtc()
        .difference(widget.startedAt.toUtc())
        .inMilliseconds;
    final remaining = (1.0 - (elapsedMs / totalMs)).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final maxWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 180.0;
        return SizedBox(
          height: 2,
          width: maxWidth,
          child: Stack(
            children: <Widget>[
              Container(color: SpectreColors.blackHair),
              Container(
                width: maxWidth * remaining,
                color: SpectreColors.redDecay,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.sending,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: SpectreColors.blackLess,
        border: Border(
          top: BorderSide(color: SpectreColors.hairline, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              color: sending ? SpectreColors.textDim : SpectreColors.matrixGreen,
              margin: const EdgeInsets.only(bottom: 16, right: 10),
            ),
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  color: SpectreColors.blackDeep,
                  border: Border.fromBorderSide(
                    BorderSide(color: SpectreColors.hairline, width: 1),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 6,
                  cursorColor: SpectreColors.matrixGreen,
                  cursorWidth: 2,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  style: SpectreTypography.mono().copyWith(
                    color: SpectreColors.textBright,
                  ),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    hintText: 'transmit…',
                    hintStyle: SpectreTypography.mono().copyWith(
                      color: SpectreColors.textFaint,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            InkWell(
              onTap: sending ? null : onSend,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: sending
                      ? SpectreColors.blackHair
                      : SpectreColors.purpleDeep,
                  border: Border.all(
                    color: sending
                        ? SpectreColors.hairline
                        : SpectreColors.purpleBright,
                    width: 1,
                  ),
                ),
                child: Text(
                  '[ SEND ]',
                  style: SpectreTypography.action().copyWith(
                    color: sending
                        ? SpectreColors.textDim
                        : SpectreColors.textBright,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChatState extends StatelessWidget {
  const _EmptyChatState({required this.recipientId});

  final String recipientId;

  String get _truncated {
    if (recipientId.length <= 16) return recipientId;
    return '${recipientId.substring(0, 16)}…';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 60),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            '> peer',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textFaint,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 10),
          SelectableText(
            _truncated,
            style: SpectreTypography.mono().copyWith(
              fontSize: 18,
              color: SpectreColors.textBright,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 26),
          const DashedDivider(),
          const SizedBox(height: 22),
          Text(
            'session not yet established',
            style: SpectreTypography.body().copyWith(
              color: SpectreColors.textCold,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'compose a message below to negotiate a session.',
            style: SpectreTypography.caption().copyWith(
              color: SpectreColors.textFaint,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlitchTitle extends StatefulWidget {
  const _GlitchTitle({required this.text});

  final String text;

  @override
  State<_GlitchTitle> createState() => _GlitchTitleState();
}

class _GlitchTitleState extends State<_GlitchTitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final Random _rng = Random(0xC0FFEE);

  double _redDx = 0;
  double _cyanDx = 0;
  double _glitchAlpha = 1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )
      ..addListener(_tick)
      ..forward();
  }

  void _tick() {
    final t = _controller.value;
    final remaining = (1.0 - t).clamp(0.0, 1.0);
    setState(() {
      if (t < 0.85) {
        _redDx = (_rng.nextDouble() * 4 - 2) * remaining;
        _cyanDx = (_rng.nextDouble() * 4 - 2) * remaining;
        _glitchAlpha = remaining;
      } else {
        _redDx = 0;
        _cyanDx = 0;
        _glitchAlpha = 0;
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
    final style = SpectreTypography.display().copyWith(fontSize: 16);
    return SizedBox(
      height: 26,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: <Widget>[
          Transform.translate(
            offset: Offset(_redDx, 0),
            child: Text(
              widget.text,
              style: style.copyWith(
                color: SpectreColors.redDanger.withOpacity(_glitchAlpha * 0.8),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(_cyanDx, 0),
            child: Text(
              widget.text,
              style: style.copyWith(
                color: SpectreColors.purpleBright
                    .withOpacity(_glitchAlpha * 0.75),
              ),
            ),
          ),
          Text(widget.text, style: style),
        ],
      ),
    );
  }
}

enum _Status { sending, sent, delivered, pending, failed }

extension _MessageStatusToUi on MessageStatus {
  _Status toUi() {
    switch (this) {
      case MessageStatus.sent:
        return _Status.sent;
      case MessageStatus.pending:
        return _Status.pending;
      case MessageStatus.failed:
        return _Status.failed;
    }
  }
}

class _ChatItem {
  final String id;
  final bool isMine;
  final String senderId;
  final DateTime timestamp;
  final DateTime? expiresAt;
  final String? plaintext;
  final _Status? status;

  const _ChatItem({
    required this.id,
    required this.isMine,
    required this.senderId,
    required this.timestamp,
    required this.expiresAt,
    required this.plaintext,
    this.status,
  });

  _ChatItem copyWith({String? plaintext, _Status? status}) {
    return _ChatItem(
      id: id,
      isMine: isMine,
      senderId: senderId,
      timestamp: timestamp,
      expiresAt: expiresAt,
      plaintext: plaintext ?? this.plaintext,
      status: status ?? this.status,
    );
  }
}
