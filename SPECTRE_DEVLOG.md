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
| Project path | ~/src/stacks/spectre_stack/spectre |
| Relay path | ~/src/stacks/spectre_stack/spectre-relay |
| GitHub | both repos pushed, public |

---

## Platform Status

| Platform | Status | Notes |
|----------|--------|-------|
| Linux | BOOTS + SENDS | Primary dev target |
| Android | Not tested yet | Primary threat model target |
| iOS | Next session | Mac needed, repo ready |
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

## Dependencies (current)

```yaml
# Crypto
libsignal_protocol_dart: ^0.4.0   # Signal Protocol E2E encryption
pointycastle: ^3.7.3              # SHA-256 (message_service, contact, onboarding)
cryptography: ^2.7.0              # Ed25519 for relay auth keypair
ed25519_edwards: (transitive)     # via libsignal, used for raw signing

# Database
drift: latest                     # Type-safe ORM, all platforms
drift_flutter: latest             # Flutter integration
sqlite3: latest                   # SQLite with encryption
sqlite3_flutter_libs: latest      # Native SQLite binaries

# Secure storage
flutter_secure_storage: ^9.0.0    # Android Keystore / Linux secret service

# Network
web_socket_channel: ^3.0.0        # WebSocket relay connection

# Navigation
go_router: ^14.0.0

# Utilities
uuid: ^4.5.3
path: latest
path_provider: latest

# Dev
drift_dev: latest
build_runner: latest
```

---

## File Registry

### COMPLETED — Flutter App

#### lib/core/crypto/identity_manager.dart
- Generates IdentityKeyPair + registrationId on first run via KeyHelper
- Stores via FlutterSecureStorage, key: spectre.uid
- User ID: 32 bytes from Random.secure(), base64url, no padding
- loadOrCreate() — treats any partial identity as corrupt, regenerates
- wipeIdentity() — deletes three specific keys + drops in-memory refs
- hasIdentity() — used by router redirect

#### lib/core/crypto/prekey_manager.dart
- 100 one-time PreKeys + 1 SignedPreKey via KeyHelper
- Per-record storage: spectre.pk.<id>
- Monotonic IDs — never reused
- consumePreKey() — refills if < 20 remaining
- rotateSignedPreKey() — keeps previous one period for in-flight inits
- isSignedPreKeyStale() — 7-day check
- lastSignedPreKeyRotation() — for settings display
- getAllPreKeys() — added for prekey bundle upload
- getCurrentSignedPreKey() — added for prekey bundle upload
- wipeAll()

#### lib/core/crypto/session_manager.dart
- InMemorySignalProtocolStore — forensic resistance
- initializeSession(recipientId, PreKeyBundle) — Signal X3DH handshake
- encryptMessage / decryptMessage — ratcheting E2E
- CiphertextMessage.PREKEY_TYPE / WHISPER_TYPE
- CRITICAL doc: transport MUST wrap with SealedSessionCipher
- hasSession, deleteSession, wipeAllSessions

#### lib/core/crypto/relay_auth_manager.dart (NEW — session 2)
- Separate Ed25519 keypair for relay authentication
- Independent from Signal identity keypair
- Uses cryptography package Ed25519()
- Stores 64-byte seed+pub blob under spectre_relay_auth_priv
- Stores 32-byte pub under spectre_relay_auth_pub
- Cross-validates on load — mismatch triggers regeneration
- sign(Uint8List nonce) -> Future<Uint8List> — raw signing, no prehash
- publicKeyBase64() -> String
- wipeRelayAuth() — panic wipe companion
- NOTE: cryptography package prehashes internally — switched to
  ed25519_edwards for raw signing compatible with Go's ed25519.Verify()

#### lib/core/storage/secure_database.dart
- drift ORM, NativeDatabase() same-isolate
- Key: 32 bytes Random.secure(), hex in FlutterSecureStorage
- PRAGMA key = "x'<hex>'" — skips PBKDF2
- Schema: Messages, Conversations, Contacts
- messages.ciphertext BlobColumn — no plaintext on disk
- ON DELETE CASCADE via drift references()
- PRAGMAs: cipher_secure_delete, foreign_keys, temp_store = MEMORY
- open() — SELECT 1 force-init
- deleteExpiredMessages(), deleteConversation(), deleteContact()
- wipeDatabase() — three layers, key destruction is the guarantee
- Settings in FlutterSecureStorage under spectre.dis.def

#### lib/core/models/message.dart
- ciphertext: Uint8List — no plaintext field ever
- isMine — constructed-in, not persisted
- isExpired getter — UTC

#### lib/core/models/conversation.dart
- displayName — first 8 chars + ellipsis (OPSEC)
- unreadCount — derived, not persisted

#### lib/core/models/contact.dart
- isVerified — never set programmatically
- fingerprintWords — BIP-39 words (first 256)

#### lib/services/network/relay_service.dart
- URI injected at construction
- Auth: Ed25519 challenge-response using RelayAuthManager
- user_id from IdentityManager (relay-addressable handle)
- SealedEnvelope omits sender_id entirely
- sendControlFrame() — used for prekey bundle upload
- Reconnect: max 5 attempts, exponential backoff with jitter
- RelayConnectionState: disconnected/connecting/connected/reconnecting/failed
- wipeAndDisconnect()
- attachPrekeyService() — wires PrekeyService post-construction
- STATE BUG FIXED: _state = connected set BEFORE uploadBundle() fires

#### lib/services/network/prekey_service.dart (NEW — session 2)
- uploadBundle() — sends prekey bundle over authenticated WebSocket
  * Strips 33-byte DJB type tag to 32 bytes for wire format
  * type: register_prekeys over existing WS connection
  * Called after auth via unawaited() — self-healing on reconnect
- fetchBundle(recipientId) -> PreKeyBundle?
  * HTTP GET relay/prekeys/{recipientId} — unauthenticated, public keys are public
  * Returns null on 404 — peer not registered
  * Prepends DJB type tag (0x05) back to decoded keys for libsignal
  * Falls back gracefully if no one-time prekey (Signal allows this)
- _stripDjbTypeTag / _prependDjbTypeTag — wire format helpers

#### lib/services/message_service.dart
- sendMessage(): encrypt -> persist -> deliver or queue
- sealed: true is default
- receiveMessage(): SHA-256 dedup, decrypt before persist
- _seenMessageIds in-memory dedup set
- DecryptedMessage — transient, no serialization methods
- panicWipe() order: relay -> sessions -> prekeys -> relayAuth -> DB -> identity
- _log() chokepoint: e.runtimeType not e.toString()

#### lib/ui/theme/app_theme.dart
- SpectreColors, SpectreTypography, AppTheme.dark()
- NoisePainter + ScanlinePainter
- NoiseBackground, DashedDivider, HairlineDivider

#### lib/ui/screens/onboarding_screen.dart
- PopScope(canPop: false) + NeverScrollableScrollPhysics
- 2-second floor on key generation
- Terminal-style _GeneratingReadout
- Three steps: INITIATE / PROTOCOL / FINGERPRINT
- Scroll gate + PostFrameCallback fallback

#### lib/ui/screens/conversation_list_screen.dart
- getConversations(), archive, delete
- _PanicWipeDialog
- FAB -> _NewConversationDialog

#### lib/ui/screens/chat_screen.dart
- getMessages() for history
- fetchBundle() + initializeSession() before first message
- [ peer not found on relay ] if 404
- _DecayBar, _GlitchTitle, _StatusGlyph, _ComposerBar
- No read receipts

#### lib/ui/screens/contact_screen.dart
- Two-column fingerprint comparison
- Scroll gate on [ MARK AS VERIFIED ]
- easeOutBack stamp animation
- [ RE-VERIFY ] flow
- Delete with accurate counts

#### lib/ui/screens/settings_screen.dart
- IDENTITY: truncated ID, [ COPY ID ], [ ROTATE SIGNED PREKEY ]
- MESSAGES: disappearing timer in FlutterSecureStorage
- SECURITY: duress PIN placeholder, Tor toggle (UI only)
- ABOUT: spectre collects nothing.
- NOTE: no navigation to settings from conversations yet!
  Need to add gear icon to conversation_list AppBar

#### lib/ui/theme/router.dart
- SpectreServices container + RouteExtras
- Redirect logic, fade transitions
- Routes: /onboarding, /conversations, /chat/:id, /contact/:userId, /settings

#### lib/main.dart
- Init: IdentityManager -> SecureDatabase -> hasIdentity probe
- Full: PreKeyManager -> RelayAuthManager -> SessionManager ->
        RelayService -> PrekeyService -> MessageService
- Consent-gated: no crypto before onboarding
- Relay URL via --dart-define=SPECTRE_RELAY_URL
- WidgetsBindingObserver: deleteExpiredMessages() on resume

### COMPLETED — Go Relay (spectre-relay/)

#### config/config.go
- Env-var only, no config files
- SPECTRE_DEV=true for dev mode (no TLS required)
- Fails hard without TLS in production
- SafeSummary() omits cert paths

#### model/envelope.go
- SealedEnvelope — no SenderID field at TYPE level (compile-time enforcement)
- OpenEnvelope — has SenderID
- Challenge, AuthRequest, AuthResponse
- omitempty absent on Success — client must see explicit boolean

#### server/auth.go
- Ed25519 challenge-response
- 32-byte nonce, 10-second handshake timeout
- Per-IP rate limit: 5 attempts/minute sliding window
- ErrAuthFailed — only error returned, no detail
- ExtractIP — IP used ONLY for rate limiting, never logged after auth
- DEV logging added (TODO: remove before production — see below)

#### server/store.go
- Thread-safe client registry + offline queue
- AES-256-GCM encrypted persistence
- Separate key file from queue file
- Atomic write via tempfile + rename
- Silent drop on queue full (presence oracle protection)
- purgeLoop — every 5 minutes
- 500 message cap per recipient
- 7-day TTL

#### server/prekey_store.go (NEW — session 2)
- PrekeyStore — AES-256-GCM encrypted, same pattern as Store
- registerBundle(userID, bundle) — bound to authenticated WS userID
- getBundle(userID) — consumes one OTP key atomically
- consumeOneTimePrekey — atomic removal
- validatePrekeyBundle — key size validation
- Falls back to signed prekey only if OTP exhausted

#### server/router.go
- Per-userID rate limiting (NAT-aware)
- Sealed preferred, tried first
- Silent drop on unknown recipient (presence oracle)
- Re-enqueue on failed flush, preserving order

#### server/server.go
- nhooyr.io/websocket, TLS 1.3 only (Min AND Max pinned)
- Compression disabled (CRIME-style attack)
- /ws WebSocket endpoint
- /health returns "." only
- /prekeys/{userId} — public HTTP GET, consumes one OTP key
- /prekeys POST — prekey bundle registration via WS frame
- handleAuthedFrame() — routes register_prekeys vs envelope
- Panic recovery logs err_type only
- 30-second graceful drain on SIGTERM

#### main.go
- JSON structured logs to stdout only
- Banner to stderr
- signal.NotifyContext for graceful shutdown

#### Dockerfile
- Multi-stage: golang:1.21-alpine builder + scratch runtime
- -trimpath -ldflags="-s -w"
- USER 65532:65532 non-root
- EXPOSE 443

#### docker-compose.yml
- ./certs:/certs:ro
- ./data:/data
- cap_drop: ALL
- no-new-privileges: true
- read_only: true
- /tmp as tmpfs

### PENDING
- lib/ui/screens/qr_code_screen.dart
- lib/ui/screens/migration_screen.dart
- lib/core/migration/migration_manager.dart
- lib/ui/widgets/panic_wipe_dialog.dart (extract shared widget)
- Settings navigation (gear icon in conversation list AppBar)
- iOS build + test on iPhone
- VPS deployment with real TLS

---

## TODO Before Production — Debug Code to Remove

### server/auth.go
- [ ] Remove DEV auth success log (uid_prefix)
- [ ] Remove all AUTH_FAIL print statements from debug session

### server/server.go
- [ ] Remove DEV prekey registered log (uid_prefix)
- [ ] Change prekey bundle registered back to Debug level

### lib/services/network/relay_service.dart
- [ ] Remove AUTH ERROR prints
- [ ] Remove WS READ prints
- [ ] Remove CHALLENGE RECEIVED prints
- [ ] Remove AUTH REQUEST BUILT/SENT prints

---

## Running the Full Stack (Dev)

### Relay
```bash
cd ~/src/stacks/spectre_stack/spectre-relay
SPECTRE_DEV=true \
SPECTRE_LISTEN_ADDR=":8080" \
SPECTRE_QUEUE_PATH="./data/offline_queue.enc" \
SPECTRE_PREKEY_PATH="./data/prekeys.enc" \
go run .
```

### Flutter App (Linux)
```bash
cd ~/src/stacks/spectre_stack/spectre
flutter run -d linux --dart-define=SPECTRE_RELAY_URL=ws://localhost:8080/ws
```

### Flutter App (iPhone — same network as relay)
```bash
# On Mac, relay must be accessible on local network
flutter run -d iphone --dart-define=SPECTRE_RELAY_URL=ws://<linux-ip>:8080/ws
```

### Build & Dependencies
```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

### Linux system deps
```bash
sudo apt-get install libsecret-1-dev libjsoncpp-dev clang ninja-build libgtk-3-dev libsecret-tools
```

### linux/CMakeLists.txt (add before find_package)
```cmake
set(OPENSSL_USE_STATIC_LIBS OFF)
```

---

## Relay Deployment (Production VPS)

```bash
# Build static binary
go build -trimpath -ldflags="-s -w" -o spectre-relay .

# Run with TLS
SPECTRE_LISTEN_ADDR=":443" \
SPECTRE_TLS_CERT="/etc/ssl/spectre.crt" \
SPECTRE_TLS_KEY="/etc/ssl/spectre.key" \
SPECTRE_QUEUE_PATH="/data/offline_queue.enc" \
SPECTRE_PREKEY_PATH="/data/prekeys.enc" \
./spectre-relay

# Or Docker
docker-compose up -d
```

### VPS Recommendations (activist threat model)
- Njalla — anonymous payment, no KYC
- 1984 Hosting — Iceland, activist-friendly
- Mullvad — privacy-first
- Hetzner — EU privacy, cheap
- AVOID US-based VPS

---

## Mac / iPhone Setup

```bash
# Install Flutter on Mac
brew install flutter

# Clone repo
git clone https://github.com/YOURUSERNAME/spectre.git
cd spectre
flutter pub get
dart run build_runner build --delete-conflicting-outputs

# Connect iPhone via USB, trust computer on iPhone
flutter devices
flutter run -d iphone --dart-define=SPECTRE_RELAY_URL=ws://<linux-local-ip>:8080/ws
```

Requirements:
- Xcode installed
- Free Apple Developer account
- iPhone trusted on Mac

---

## Remember Later — Flagged Issues

### Crypto
- [ ] _reconstructPendingQueue() on startup — not implemented
- [ ] Session mutex — concurrent ratchet advances can corrupt state
- [ ] No message ordering guarantee — need sequence numbers or vector clock
- [ ] Sealed Sender transport enforcement — MUST wrap with SealedSessionCipher

### Storage
- [ ] VACUUM during wipe on main thread — move to background isolate
- [ ] ON DELETE CASCADE direction — verify conversations -> messages
- [ ] Key never logged — lint/comment warning for debug builds
- [ ] expiresAt UTC consistency
- [ ] verifiedAt missing from contacts — using createdAt as proxy
- [ ] Background isolate for DB — revisit with top-level setup function

### Network
- [ ] Message padding — variable size leaks content info
- [ ] Malformed frame counter — 1000 bad frames = DoS
- [ ] Cover traffic — post-MVP
- [ ] Prekey replenishment — relay should notify client when OTPs running low

### UI
- [ ] _DecayBar Timer disposal — cancel in dispose()
- [ ] Panic wipe SystemNavigator.pop() — test on Android
- [ ] [ ciphertext — restart cleared cache ] — tapping must not decrypt
- [ ] BIP-39 wordlist — externalise to asset file
- [ ] _PanicWipeDialog — extract to shared widget
- [ ] Settings navigation — add gear icon to conversation list AppBar

### Relay
- [ ] Document --dart-define=SPECTRE_RELAY_URL for self-hosters
- [ ] Tor onion service setup guide
- [ ] Size padding at transport layer
- [ ] Prekey low-supply notification to client
- [ ] data/ gitignored — keys regenerated after accidental commit

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
| Separate Ed25519 relay auth keypair | Curve25519 Signal key incompatible with Go ed25519.Verify() |
| /prekeys unauthenticated HTTP | Public keys are public — no auth needed |
| Bundle bound to WS userID not payload | Only authenticated session is authority for ownership |
| SealedEnvelope type has no SenderID field | Compile-time metadata enforcement, not runtime check |
| Atomic tempfile+rename for queue | Crash-safe — never torn file on disk |
| Key file separate from queue file | Backup queue without exposing key |
| data/ removed from git history | Keys accidentally committed — scrubbed with filter-branch |

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
- [x] Go relay built and running
- [x] Ed25519 auth working
- [x] Prekey bundle registered on relay
- [x] First encrypted message sent (loopback)
- [ ] Two real devices connected
- [ ] First message between Linux and iPhone
- [ ] Relay deployed to VPS with real TLS
- [ ] Android tested
- [ ] Debug logs removed before production

---

Last updated: Session 2 complete
Next session: iPhone setup on Mac + first real two-device message