/// A locally-stored contact record.
///
/// Trust model: this row is created from a peer's identity-key bundle
/// the first time a session is established. [isVerified] starts as
/// false ("trust on first use") and only flips to true after the user
/// has compared [fingerprintWords] with the peer out-of-band — by
/// scanning a QR, reading the words aloud in person, or exchanging
/// them on a separately-trusted channel. Programmatic verification is
/// explicitly NOT allowed; the boolean is a record of human attestation.
/// The label to show for a peer: their local nickname if set, otherwise the
/// caller-supplied fallback (typically the truncated user ID). Pure — unit
/// tested. [contact] may be null (no contact row yet → fallback).
String peerLabel(Contact? contact, String fallbackTruncatedId) {
  final name = contact?.displayName;
  return (name != null && name.isNotEmpty) ? name : fallbackTruncatedId;
}

class Contact {
  final String id;

  /// Opaque user ID for the peer (base64url, never a phone number).
  final String userId;

  /// User-supplied nickname for this contact. Optional — many
  /// activist/journalist threat models prefer no nickname at all so
  /// that a seized device doesn't reveal who the user is talking to.
  final String? displayName;

  /// Hex representation of the peer's identity key fingerprint
  /// (typically SHA-256 over the serialized identity public key).
  /// Stored hex (not raw bytes) so it round-trips cleanly through TEXT.
  final String identityKeyFingerprint;

  /// True only after out-of-band confirmation by the user. See class
  /// doc above — never set this programmatically.
  final bool isVerified;

  final DateTime createdAt;

  const Contact({
    required this.id,
    required this.userId,
    required this.identityKeyFingerprint,
    required this.createdAt,
    this.displayName,
    this.isVerified = false,
  });

  /// Human-readable representation of [identityKeyFingerprint] as a
  /// sequence of dictionary words, one per byte of the fingerprint.
  ///
  /// Why words instead of hex digits:
  ///   * Reading 64 hex chars aloud over a phone call is error-prone:
  ///     "B" and "D", "3" and "E", "8" and "B" sound similar. Words
  ///     from a curated, phonetically-distinct list are much more
  ///     robust on a noisy channel.
  ///   * For two people meeting in person, words also chunk the
  ///     fingerprint into memorable units, which reduces the chance
  ///     of skipping or duplicating a segment during comparison.
  ///   * The mapping is deterministic and reversible: an attacker
  ///     cannot mount a "preimage attack on the wordlist" — the words
  ///     ARE the fingerprint, just re-encoded, so they inherit the
  ///     full collision resistance of the underlying hash. The job of
  ///     the wordlist is purely to make human verification accurate.
  ///
  /// Uses the first 256 words of the BIP-39 English wordlist (one word
  /// per byte). BIP-39 was designed to be phonetically distinct and
  /// has no two words sharing a 4-letter prefix, which is exactly the
  /// property we want for spoken verification.
  List<String> get fingerprintWords {
    final cleaned = identityKeyFingerprint
        .replaceAll(RegExp(r'[^0-9a-fA-F]'), '')
        .toLowerCase();
    if (cleaned.length.isOdd) {
      throw FormatException(
        'fingerprint must have an even number of hex digits',
      );
    }
    final out = <String>[];
    for (var i = 0; i < cleaned.length; i += 2) {
      final byte = int.parse(cleaned.substring(i, i + 2), radix: 16);
      out.add(_wordList[byte]);
    }
    return out;
  }

  factory Contact.fromMap(Map<String, Object?> map) {
    return Contact(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      displayName: map['display_name'] as String?,
      identityKeyFingerprint: map['identity_key_fingerprint'] as String,
      isVerified: (map['verified'] as int) != 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['created_at'] as int,
        isUtc: true,
      ),
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'user_id': userId,
      'display_name': displayName,
      'identity_key_fingerprint': identityKeyFingerprint,
      'verified': isVerified ? 1 : 0,
      'created_at': createdAt.toUtc().millisecondsSinceEpoch,
    };
  }

  Contact copyWith({
    String? displayName,
    bool? isVerified,
  }) {
    return Contact(
      id: id,
      userId: userId,
      identityKeyFingerprint: identityKeyFingerprint,
      createdAt: createdAt,
      displayName: displayName ?? this.displayName,
      isVerified: isVerified ?? this.isVerified,
    );
  }

  // First 256 words of the BIP-39 English wordlist. Indexed 0..255 so
  // that wordlist[byte] is a direct byte→word mapping. BIP-39 is a
  // well-known, phonetically-distinct list under the public-domain
  // license; we use the first 256 entries because each byte we need
  // to encode is in the range [0, 255].
  static const List<String> _wordList = <String>[
    'abandon', 'ability', 'able', 'about', 'above', 'absent', 'absorb',
    'abstract', 'absurd', 'abuse', 'access', 'accident', 'account',
    'accuse', 'achieve', 'acid', 'acoustic', 'acquire', 'across', 'act',
    'action', 'actor', 'actress', 'actual', 'adapt', 'add', 'addict',
    'address', 'adjust', 'admit', 'adult', 'advance', 'advice', 'aerobic',
    'affair', 'afford', 'afraid', 'again', 'age', 'agent', 'agree',
    'ahead', 'aim', 'air', 'airport', 'aisle', 'alarm', 'album', 'alcohol',
    'alert', 'alien', 'all', 'alley', 'allow', 'almost', 'alone', 'alpha',
    'already', 'also', 'alter', 'always', 'amateur', 'amazing', 'among',
    'amount', 'amused', 'analyst', 'anchor', 'ancient', 'anger', 'angle',
    'angry', 'animal', 'ankle', 'announce', 'annual', 'another', 'answer',
    'antenna', 'antique', 'anxiety', 'any', 'apart', 'apology', 'appear',
    'apple', 'approve', 'april', 'arch', 'arctic', 'area', 'arena',
    'argue', 'arm', 'armed', 'armor', 'army', 'around', 'arrange',
    'arrest', 'arrive', 'arrow', 'art', 'artefact', 'artist', 'artwork',
    'ask', 'aspect', 'assault', 'asset', 'assist', 'assume', 'asthma',
    'athlete', 'atom', 'attack', 'attend', 'attitude', 'attract',
    'auction', 'audit', 'august', 'aunt', 'author', 'auto', 'autumn',
    'average', 'avocado', 'avoid', 'awake', 'aware', 'away', 'awesome',
    'awful', 'awkward', 'axis', 'baby', 'bachelor', 'bacon', 'badge',
    'bag', 'balance', 'balcony', 'ball', 'bamboo', 'banana', 'banner',
    'bar', 'barely', 'bargain', 'barrel', 'base', 'basic', 'basket',
    'battle', 'beach', 'bean', 'beauty', 'because', 'become', 'beef',
    'before', 'begin', 'behave', 'behind', 'believe', 'below', 'belt',
    'bench', 'benefit', 'best', 'betray', 'better', 'between', 'beyond',
    'bicycle', 'bid', 'bike', 'bind', 'biology', 'bird', 'birth',
    'bitter', 'black', 'blade', 'blame', 'blanket', 'blast', 'bleak',
    'bless', 'blind', 'blood', 'blossom', 'blouse', 'blue', 'blur',
    'blush', 'board', 'boat', 'body', 'boil', 'bomb', 'bone', 'bonus',
    'book', 'boost', 'border', 'boring', 'borrow', 'boss', 'bottom',
    'bounce', 'box', 'boy', 'bracket', 'brain', 'brand', 'brass', 'brave',
    'bread', 'breeze', 'brick', 'bridge', 'brief', 'bright', 'bring',
    'brisk', 'broccoli', 'broken', 'bronze', 'broom', 'brother', 'brown',
    'brush', 'bubble', 'buddy', 'budget', 'buffalo', 'build', 'bulb',
    'bulk', 'bullet', 'bundle', 'bunker', 'burden', 'burger', 'burst',
    'bus', 'business', 'busy', 'butter', 'buyer', 'buzz', 'cabbage',
    'cabin', 'cable',
  ];
}
