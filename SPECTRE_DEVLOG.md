# SPECTRE — Developer Log
> Secure messaging for activists and journalists  
> Built with Flutter + Signal Protocol + Go relay  
> Aesthetic: $uicideboy$ — cold, dark, underground

---

## Project Identity

| Field | Value |
|-------|-------|
| App name | Spectre |
| Package | `com.spectre.app` |
| Tagline | *"Invisible. Secure. Yours."* |
| Platform targets | Android (primary), Linux, iOS, macOS (skip Windows) |
| Flutter channel | master 3.45.0 |
| Dart SDK | ^3.13.0-138.0.dev |
| Dev machine | Debian GNU/Linux 12 (bookworm) |
| Android Studio | Panda4 Patch1 |
| Java | OpenJDK 21 (bundled in Android Studio JBR) |
| Project path | ~/src/stacks/spectre |
| Relay path | ~/src/stacks/spectre-relay (separate repo) |

---

## Platform Status

| Platform | Status | Notes |
|----------|--------|-------|
| Linux | BOOTS | Primary dev target |
| Android | Not tested yet | Primary threat model target |
| iOS | Later | Needs Mac to build |
| macOS | Later | Easy once iOS works |
| Windows | Skipped | Different threat model |

---

## Threat Model

Primary users: activists, journalists, whistleblowers
Primary adversaries: state actors, corporate surveillance, forensic device analysis

### Security Principles (in priority order)
1. Fail closed — every error defaults to the secure path
2. No plaintext ever on disk — schema enforces this at the database level
3. Minimal metadata — server learns as little as possible about who talks to whom
4. Forward secrecy — past messages safe even if keys are compromised
5. Panic wipe — full identity destruction must always be one deliberate action away
6. OPSEC by default — safe behaviour is the default, unsafe requires opt-in

---

## Dependencies (current — post drift migration)

```yaml
libsignal_protocol_dart: ^0.4.0   # Signal Protocol E2E encryption
pointycastle: ^3.7.3              # Additional crypto primitives
drift: latest                     # Type-safe ORM, all platforms
drift_flutter: latest             # Flutter integration
sqlite3: latest                   # SQLite with encryption
sqlite3_flutter_libs: latest      # Native SQLite binaries
flutter_secure_storage: ^9.0.0    # Android Keystore / Linux secret service
web_socket_channel: ^3.0.0        # WebSocket relay connection
go_router: ^14.0.0                # Navigation
uuid: ^4.5.3                      # Random user IDs (no phone numbers)
path: latest
path_provider: latest
drift_dev: latest                 # dev — code generation
build_runner: latest              # dev — code generation runner
```

### Why we migrated from sqflite_sqlcipher to drift
- sqflite_sqlcipher is Android/iOS only, no Linux support
- drift + sqlite3 works on Android, iOS, Linux, macOS with identical code path
- Type-safe queries, compile-time validation
- sqlcipher_flutter_libs was EOL (0.7.0+eol) — removed entirely
- NativeDatabase.createInBackground() removed — FlutterSecureStorage uses async
  platform channels that cannot cross isolate boundaries
- NativeDatabase() (same-isolate) used instead — performance tradeoff acknowledged

---

## File Registry

### COMPLETED

#### lib/core/crypto/identity_manager.dart
- Generates IdentityKeyPair + registrationId on first run via KeyHelper
- Stores via FlutterSecureStorage (Keystore-backed)
- User ID: 32 bytes from Random.secure(), base64url, no padding
- loadOrCreate() — treats any partial identity as corrupt, regenerates
- wipeIdentity() — deletes three specific keys + drops in-memory refs
- hasIdentity() — added post-generation, used by router redirect
- NOTE: Dart string immutability prevents true memory scrubbing — acknowledged in comments

#### lib/core/crypto/prekey_manager.dart
- Generates 100 one-time PreKeys + 1 SignedPreKey on first run via KeyHelper
- Per-record storage: spectre.pk.<id> — avoids rewriting giant blob
- Monotonic IDs — never reused, closes replay attack window
- consumePreKey() — deletes record (forward secrecy step), refills if < 20 remaining
- rotateSignedPreKey() — promotes current to previous (kept one period for in-flight inits)
- isSignedPreKeyStale() — 7-day check for scheduler
- lastSignedPreKeyRotation() — added for settings screen display
- wipeAll() — panic wipe companion

#### lib/core/crypto/session_manager.dart
- InMemorySignalProtocolStore — in-memory by design (forensic resistance)
- initializeSession() — SessionBuilder.processPreKeyBundle(), fails closed on mismatch
- Envelope format: base64(JSON{ type, body }) — type tag routes PreKey vs Whisper
- CiphertextMessage.PREKEY_TYPE / WHISPER_TYPE (fixed from incorrect lowercase)
- decryptMessage() — handles both PreKeySignalMessage and SignalMessage
- CRITICAL: Sealed Sender warning in doc block — transport layer MUST wrap with
  SealedSessionCipher or metadata protection is silently lost
- hasSession, deleteSession, wipeAllSessions

#### lib/core/storage/secure_database.dart
- drift ORM with NativeDatabase() (same-isolate)
- Key: 32 bytes Random.secure(), hex-stored in FlutterSecureStorage
- Passed as PRAGMA key = "x'<hex>'" — skips PBKDF2 (pointless for 256-bit true random)
- Schema: Messages, Conversations, Contacts (@DataClassName avoids model type collision)
- messages.ciphertext BlobColumn — schema enforces no plaintext on disk
- ON DELETE CASCADE via drift references()
- PRAGMAs: cipher_secure_delete = ON, foreign_keys = ON, temp_store = MEMORY
- open() — SELECT 1 force-init so encryption errors surface at startup
- deleteExpiredMessages() — hard delete, no tombstones, returns count
- deleteConversation(String id) — added post-generation, cascades messages
- deleteContact(String userId) — added post-generation, cascades conversations + messages
- wipeDatabase() — three layers:
    1. cipher_secure_delete scrub + VACUUM rewrite
    2. zero-overwrite + unlink (best-effort on flash — wear-levelling acknowledged)
    3. key destruction — THE REAL GUARANTEE
- Settings stored in FlutterSecureStorage under spectre.dis.def (not DB table)

#### lib/core/models/message.dart
- ciphertext: Uint8List — no plaintext field, ever
- Class doc lists leak vectors: sqflite cache, isolate snapshots, crash dumps,
  hot-reload state, ListView caches
- isMine — constructed-in, not persisted (device-relative truth)
- isExpired getter — UTC comparison

#### lib/core/models/conversation.dart
- recipientPublicKey as base64 String, mediates against BLOB column
- displayName — always first 8 chars + ellipsis (OPSEC default)
- unreadCount — derived, not persisted (avoids counter drift bug class)

#### lib/core/models/contact.dart
- isVerified defaults to false — must never be set programmatically
- fingerprintWords — BIP-39 words (first 256), inline wordlist
- Words beat hex for spoken out-of-band verification

#### lib/services/network/relay_service.dart
- URI injected at construction — no hardcoded endpoints
- Auth: server sends 32-byte challenge, client signs with identity key
- SealedEnvelope omits sender_id field entirely (even null would be a fingerprint)
- CRITICAL TCP warning: Sealed sender is meaningless without Tor
- Metadata leak doc: relay sees IP, recipient ID, timing, size, session
- Reconnect: max 5 attempts, exponential backoff with jitter
- RelayConnectionState: disconnected / connecting / connected / reconnecting / failed
- wipeAndDisconnect() — marks instance unusable, prevents ghost reconnections

#### lib/services/message_service.dart
- sendMessage(): encrypt -> persist ciphertext -> deliver or queue. sealed: true is default
- receiveMessage(): SHA-256 truncated dedup ID — same envelope = upsert no-op
- _seenMessageIds in-memory set — gates DecryptedMessage emissions for duplicates
- _ensureConversation uses getConversations() + client-side filter
- Decrypt before persist — bad ciphertext never touches DB
- DecryptedMessage — transient type, no toMap/fromMap/copyWith
- Pending queue: in-memory Map only — cleared on wipe
- panicWipe() order: relay -> sessions -> prekeys -> DB -> identity
  Errors swallowed per-step — identity wipe must always run
- _log() chokepoint: no plaintext, no ciphertext, e.runtimeType not e.toString()

#### lib/ui/theme/app_theme.dart
- SpectreColors: blacks, purples, blood reds, cold greys, matrix green (0xFF00FF41)
- SpectreTypography: JetBrains Mono primary + Courier fallback
- AppTheme.dark(): sharp corners everywhere, elevation 0, fade-only transitions
- NoisePainter + ScanlinePainter, NoiseBackground, DashedDivider, HairlineDivider

#### lib/ui/screens/onboarding_screen.dart
- PopScope(canPop: false) + NeverScrollableScrollPhysics — no escape routes
- 2-second floor on key generation — deliberate, prevents timing fingerprinting
- _GeneratingReadout — terminal-style, 6 lines fading in at 340ms intervals
- Step 1 INITIATE: identity generation with animated reveal
- Step 2 PROTOCOL: three stark // prefixed blocks, pure typography
- Step 3 FINGERPRINT: SHA-256 of public key -> BIP-39 words, scroll gate
- PostFrameCallback fallback — handles small screens
- [ I HAVE VERIFIED ] locked until scrolled

#### lib/ui/screens/conversation_list_screen.dart
- getConversations(), archive via upsert, delete via deleteConversation()
- _PanicWipeDialog — lists what will be destroyed
- Long-press -> _ConversationActionsSheet: [ARCHIVE] / [DELETE]
- FAB -> _NewConversationDialog

#### lib/ui/screens/chat_screen.dart
- getMessages(conversationId) for history
- [ ciphertext — restart cleared cache ] for historical messages without live plaintext
- _DecayBar — Timer.periodic(200ms), 2px shrinking bar
- _GlitchTitle — red/purple/grey stacked layers, settles after 1200ms
- _StatusGlyph — matrix green sent, dim queued, red failed. No read receipts
- _ComposerBar — matrix green liveness dot, [ SEND ]

#### lib/ui/screens/contact_screen.dart
- Two-column fingerprint: YOUR WORDS vs THEIR WORDS
- Hairline divider every 4th word — chunks verification ritual
- _VerificationProtocolBox — protocol steps color-graded
- Scroll gate on [ MARK AS VERIFIED ] — PostFrameCallback fallback
- easeOutBack stamp animation on verification
- [ RE-VERIFY ] resets verified = 0, requires full scroll-gate again
- Delete dialog shows actual conversation + message counts
- updateContactVerified(userId, bool) — explicit tap only

#### lib/ui/screens/settings_screen.dart
- Section IDENTITY: truncated ID, [ COPY ID ], [ ROTATE SIGNED PREKEY ]
- Section MESSAGES: _Disappearing enum stored in FlutterSecureStorage
- Section SECURITY: duress PIN placeholder, _SharpToggle for Tor (UI complete, not wired)
- Section ABOUT: spectre collects nothing. in matrix green, no links
- NOTE: _PanicWipeDialog duplicated here and in conversation list — needs extraction

#### lib/ui/theme/router.dart
- SpectreServices container, RouteExtras
- Redirect: forces /onboarding when no identity
- Fade transitions only
- Routes: /onboarding, /conversations, /chat/:id, /contact/:userId, /settings

#### lib/main.dart
- Init order: IdentityManager -> SecureDatabase.open() -> hasIdentity probe
- Consent-gated crypto: no crypto minted before onboarding
- Relay URL via --dart-define=SPECTRE_RELAY_URL, default wss://relay.invalid
- WidgetsBindingObserver: deleteExpiredMessages() on foreground resume
- _BootScreen — glitching SPECTRE, nothing phones home
- _ErrorScreen — e.runtimeType not e.toString(), [RETRY] / [WIPE]
- Zero analytics / Firebase / crash reporting

### PENDING (next sessions)
- lib/ui/screens/qr_code_screen.dart
- lib/ui/screens/migration_screen.dart
- lib/core/migration/migration_manager.dart
- lib/ui/widgets/panic_wipe_dialog.dart (extract shared widget)
- spectre-relay/ — Go relay server (NEXT SESSION)

---

## Relay Server Plan (Go)

```
spectre-relay/
├── main.go
├── config/config.go
├── model/envelope.go
├── server/
│   ├── server.go
│   ├── auth.go
│   ├── router.go
│   └── store.go
├── Dockerfile
└── docker-compose.yml
```

Offline persistence: encrypted on-disk, 7-day TTL, deleted on delivery, 500 msg cap per recipient.

VPS recommendations for activist threat model:
- Njalla — anonymous payment, no KYC
- 1984 Hosting — Iceland, activist-friendly
- Mullvad — privacy-first
- Hetzner — EU privacy, cheap
- AVOID US-based VPS

---

## Remember Later — Flagged Issues

### Crypto
- [ ] _reconstructPendingQueue() on startup — not implemented
- [ ] Session mutex — concurrent ratchet advances can corrupt session state
- [ ] No message ordering guarantee — need sequence numbers or vector clock
- [ ] Sealed Sender transport enforcement — MUST wrap with SealedSessionCipher

### Storage
- [ ] VACUUM during wipe on main thread — move to background isolate
- [ ] ON DELETE CASCADE direction — verify conversations -> messages not reverse
- [ ] Key never logged — add lint/comment warning for debug builds
- [ ] expiresAt UTC consistency — ensure DB stores all timestamps in UTC
- [ ] verifiedAt field missing from contacts — currently using createdAt as proxy
- [ ] Background isolate for DB — revisit with top-level setup function

### Network
- [ ] Message padding — variable size leaks content info
- [ ] Malformed frame counter — 1000 bad frames = DoS
- [ ] Cover traffic — post-MVP

### UI
- [ ] _DecayBar Timer disposal — must cancel in dispose()
- [ ] Panic wipe SystemNavigator.pop() — test on Android
- [ ] [ ciphertext — restart cleared cache ] — ensure tapping does not decrypt
- [ ] BIP-39 wordlist — externalise to asset file
- [ ] _PanicWipeDialog — extract to shared widget

### Relay
- [ ] Document --dart-define=SPECTRE_RELAY_URL for self-hosters
- [ ] Tor onion service setup guide
- [ ] Size padding at transport layer

---

## Security Decisions Log

| Decision | Rationale |
|----------|-----------|
| No phone number | Phone numbers are identity |
| Random.secure() for all IDs | math.Random() not cryptographically secure |
| PBKDF2 skipped | 256-bit true random needs no stretching |
| temp_store = MEMORY | SQLite spills to unencrypted disk without this |
| Decrypt before persist | Bad ciphertext never touches DB |
| sealed: true as default | Secure path = path of least resistance |
| Per-step error swallowing in wipe | Half-wiped is worse than skipping one step |
| e.runtimeType not e.toString() | Exception messages embed triggering input |
| In-memory sessions | Force-close = session state evaporates |
| isVerified never set programmatically | Verification is a human act |
| Messages never migrate | Migrating device may be compromised |
| Jitter in reconnect backoff | Prevents thundering herd timing signatures |
| Empty sender_id vs null | Even null field is a fingerprint |
| NativeDatabase() not createInBackground() | FlutterSecureStorage cant cross isolate boundaries |
| Settings in FlutterSecureStorage | No schema migration, Keystore-backed |
| Skip Windows | Attack surface, wrong threat model |
| Separate relay repo | Independent audit, community hosting |

---

## Build & Run

```bash
# Dependencies
flutter pub get

# Generate drift code (required after schema changes)
dart run build_runner build --delete-conflicting-outputs

# Run Linux
flutter run -d linux

# Run Android
flutter run -d android

# Build APK
flutter build apk --dart-define=SPECTRE_RELAY_URL=wss://your-relay.example.com
```

### Linux system deps
```bash
sudo apt-get install libsecret-1-dev libjsoncpp-dev clang ninja-build libgtk-3-dev
```

### linux/CMakeLists.txt (add before find_package)
```cmake
set(OPENSSL_USE_STATIC_LIBS OFF)
```

---

## Milestones

- [x] Flutter project scaffolded
- [x] Signal Protocol integrated
- [x] Encrypted database (drift + SQLCipher)
- [x] All core crypto files
- [x] All UI screens
- [x] First boot on Linux
- [x] Onboarding completes, identity generated
- [x] Conversations screen renders
- [ ] Go relay built
- [ ] Relay deployed to VPS
- [ ] Two devices connected
- [ ] First encrypted message sent

---

Last updated: Session 1 complete — Flutter app boots on Linux
Next session: spectre-relay in Go (~/src/stacks/spectre-relay)