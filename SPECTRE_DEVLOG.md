# SPECTRE — Developer Log

> Secure messaging for activists and journalists  
> Built with Flutter + Signal Protocol + Go relay  
> Aesthetic: $uicideboy$ — cold, dark, underground

---

## Project Identity

| Field            | Value                                                                                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| App name         | Spectre                                                                                                                      |
| Package          | `com.spectre.app`                                                                                                            |
| Tagline          | _"Invisible. Secure. Yours."_                                                                                                |
| Platform targets | Android (primary), Linux, iOS, macOS (skip Windows)                                                                          |
| Flutter channel  | master 3.45.0                                                                                                                |
| Dart SDK         | ^3.13.0-138.0.dev                                                                                                            |
| Dev machine      | Debian GNU/Linux 12 (bookworm)                                                                                               |
| Android Studio   | Panda4 Patch1                                                                                                                |
| Java             | OpenJDK 21 (bundled in Android Studio JBR)                                                                                   |
| Project path     | ~/src/stacks/spectre_stack/spectre                                                                                           |
| Relay path       | ~/src/stacks/spectre_stack/spectre-relay (also cloned at ~/dev/experiments/spectre-relay — edits applied there in Session 3) |
| GitHub           | both repos pushed, public                                                                                                    |

---

## Platform Status

| Platform | Status         | Notes                       |
| -------- | -------------- | --------------------------- |
| Linux    | BOOTS + SENDS  | Primary dev target          |
| Android  | Not tested yet | Primary threat model target |
| iOS      | Next session   | Mac needed, repo ready      |
| macOS    | Later          | Easy once iOS works         |
| Windows  | Skipped        | Different threat model      |

---

## Threat Model

Primary users: activists, journalists, whistleblowers
Primary adversaries: state actors, corporate surveillance, forensic device analysis

### Security Principles (in priority order)

1. Fail closed — every error defaults to the secure path
2. No plaintext at rest in the clear — message plaintext is persisted ONLY in
   the SQLCipher-encrypted DB (key in the OS keystore), never unencrypted.
   (Revised from "no plaintext EVER on disk": history was unreadable after a
   restart because ratchet ciphertext is one-time. Now encrypted-at-rest, the
   Signal posture — see messages.plaintext + the Message model. Panic-wipe
   destroys the key; disappearing-message sweep deletes rows.)
3. Minimal metadata — server learns as little as possible about who talks to whom
4. Forward secrecy — past messages safe even if keys are compromised
5. Panic wipe — full identity destruction must always be one deliberate action away
6. OPSEC by default — safe behaviour is the default, unsafe requires opt-in

---

## Dependencies (current)

```yaml
# Crypto
libsignal_protocol_dart: ^0.4.0 # Signal Protocol E2E encryption
pointycastle: ^3.7.3 # SHA-256 (message_service, contact, onboarding)
cryptography: ^2.7.0 # Ed25519 for relay auth keypair
ed25519_edwards: (transitive) # via libsignal, used for raw signing

# Database
drift: latest # Type-safe ORM, all platforms
drift_flutter: latest # Flutter integration
sqlite3: latest # SQLite with encryption
sqlite3_flutter_libs: latest # Native SQLite binaries

# Secure storage
flutter_secure_storage: ^9.0.0 # Android Keystore / Linux secret service

# Network
web_socket_channel: ^3.0.0 # WebSocket relay connection

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
- hasSession, deleteSession, wipeAllSessions
- (Session 3) SealedSessionCipher does NOT exist in libsignal_protocol_dart —
  sealed sender is built in-house (see sealed_sender.dart). Added
  remoteIdentityKey() (pinned peer key, no OTPK burn) and
  assertFirstContactIdentity() (C2 binding, constant-time, parse-only).

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
- STATE BUG FIXED: \_state = connected set BEFORE uploadBundle() fires

#### lib/services/network/prekey_service.dart (NEW — session 2)

- uploadBundle() — sends prekey bundle over authenticated WebSocket
  - Strips 33-byte DJB type tag to 32 bytes for wire format
  - type: register_prekeys over existing WS connection
  - Called after auth via unawaited() — self-healing on reconnect
- fetchBundle(recipientId) -> PreKeyBundle?
  - HTTP GET relay/prekeys/{recipientId} — unauthenticated, public keys are public
  - Returns null on 404 — peer not registered
  - Prepends DJB type tag (0x05) back to decoded keys for libsignal
  - Falls back gracefully if no one-time prekey (Signal allows this)
- \_stripDjbTypeTag / \_prependDjbTypeTag — wire format helpers

#### lib/services/message_service.dart

- sendMessage(): encrypt -> persist -> deliver or queue
- sealed: true is default
- receiveMessage(): SHA-256 dedup, decrypt before persist
- \_seenMessageIds in-memory dedup set
- DecryptedMessage — transient, no serialization methods
- panicWipe() order: relay -> sessions -> prekeys -> relayAuth -> DB -> identity
- \_log() chokepoint: e.runtimeType not e.toString()

#### lib/ui/theme/app_theme.dart

- SpectreColors, SpectreTypography, AppTheme.dark()
- NoisePainter + ScanlinePainter
- NoiseBackground, DashedDivider, HairlineDivider

#### lib/ui/screens/onboarding_screen.dart

- PopScope(canPop: false) + NeverScrollableScrollPhysics
- 2-second floor on key generation
- Terminal-style \_GeneratingReadout
- Three steps: INITIATE / PROTOCOL / FINGERPRINT
- Scroll gate + PostFrameCallback fallback

#### lib/ui/screens/conversation_list_screen.dart

- getConversations(), archive, delete
- \_PanicWipeDialog
- FAB -> \_NewConversationDialog

#### lib/ui/screens/chat_screen.dart

- getMessages() for history
- fetchBundle() + initializeSession() before first message
- [ peer not found on relay ] if 404
- \_DecayBar, \_GlitchTitle, \_StatusGlyph, \_ComposerBar
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
- FIX (session 3): signed_prekey_id now round-trips. PrekeyBundle/
  PrekeyResponse had no field for it, so json.Unmarshal dropped the
  client's uploaded id and getBundle could not echo it; recipients
  decoded 0 and threw InvalidKeyIdException("No such signedprekeyrecord! 0").
  Added the field to both structs, copy it through getBundle, and reject
  a zero id at register time (ids are 1-based). Existing registrations
  self-heal on reconnect via idempotent uploadBundle.

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

### Session 3 — Sealed Sender, verification, readable history

NEW files:
- lib/core/crypto/sealed_sender.dart — in-house sealed-sender cipher
  (ephemeral X25519 → HKDF-SHA256 → ChaCha20-Poly1305, recipient-id AAD,
  signed-cert verify). The construction; needs external review.
- lib/services/network/sealed_ca_service.dart — fetch + TOFU-pin the relay
  CA pubkey (GET /sealed-ca); mismatch fails closed.
- spectre-relay/server/sealed_ca.go — relay CA signing key + IssueCert.
- spectre-relay/server/ratelimit.go — per-user sliding-window limiter (certs).
- test/identity_pin_test.dart, spectre-relay/server/sealed_ca_test.go,
  spectre-relay/server/sealed_cert_test.go.

CHANGED (registry above predates these):
- message_service.dart — sends seal via _sealForWire; receive opens + C2
  binding (assertFirstContactIdentity); identity-key TOFU pin + change banner
  flag (NEW-HIGH-1); persistent replay dedup via messageExists (H2); plaintext
  now persisted (see below); RAM plaintext cache; the DEV cleartext shim was
  REMOVED — sealed sender is the only wire path.
- relay_service.dart — wire form reconciled to the Go SealedEnvelope
  (timestamp_ms); ensureSenderCert + sender_cert frame + cert cache/refresh +
  warm-on-connect; debug prints removed.
- secure_database.dart — schema v2: messages.plaintext (encrypted at rest,
  readable history); updateConversationKey (key pin); messageExists (replay).
- message.dart — plaintext field (posture change, see Principle #2).
- Go relay (server.go/auth.go) — /sealed-ca, request_sender_cert issuance
  (uid/ik bound to authed user's registered bundle), cert rate limit; DEV
  uid logs removed.
- UI: chat_screen verification bar + key-changed banner + readable history;
  conversation_list settings gear; /settings + /contact routed to the full
  standalone screens (inline duplicates removed).

### Session 4 — nicknames + one-sided message requests

- Nicknames: Contact.displayName now settable (updateContactDisplayName) + shown
  via peerLabel() in chat AppBar, conversation list, sheets. Edit on the contact
  screen ([ EDIT ] row). No schema change.
- Message requests (one-sided/Signal-style): conversations.requestState
  (schema v3) {accepted,pending,blocked}; getRequests/getConversationByRecipient/
  updateConversationState; _ensureConversation(incoming:) + auto-accept; receive
  block-gate; REQUESTS section + Accept/Block sheet. CANARY: key-pin lookups
  switched off getConversations() (now accepted-only) to getConversationByRecipient.
- Contacts are now created/pinned on the SEND path too (not just receive), so an
  outbound-only conversation has a fingerprint to verify and a contact to
  nickname. (Was: nicknames/verification only worked after receiving.)
- Adding a peer (＋ new conversation) now SENDS a connection request:
  MessageService.sendInvitation establishes the session + sends a canned
  "wants to connect" first message, so it reaches the peer's Requests inbox
  without the user typing. (Was: adding only opened a local chat; nothing went
  out until you wrote.)
- Tests: contacts_requests_test (peerLabel, nextStateOnOutbound, shouldDropInbound,
  Conversation round-trip). 24 client tests green.

### Session 5 — own display name (shared E2E) + UI fixes

- Own display name: set at onboarding (optional field) + editable in Settings.
  Stored locally (IdentityManager displayName/setDisplayName, key spectre.dn);
  transmitted INSIDE the E2E message payload (wrap {v:1,n,t}; legacy raw text
  still decodes) — relay never sees it. On receive stored in Contact.peerName
  (schema v4). peerLabel priority: local nickname (displayName) > peerName >
  truncated id. Invitation carries the name too.
- Fix: conversation list now refreshes on return (RouteObserver/RouteAware) —
  nickname/accept/block changes show without waiting for an incoming message.
- Fix: contrast pass in app_theme (text tiers + purpleBright/redDanger/hairline)
  for readable helper text on the near-black UI.

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
SPECTRE_SEALED_CA_PATH="./data/sealed_ca.key" \
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

- [ ] \_reconstructPendingQueue() on startup — not implemented
- [ ] Session mutex — concurrent ratchet advances can corrupt state
- [ ] No message ordering guarantee — need sequence numbers or vector clock
- [x] Sealed Sender transport enforcement — DONE in-house (no SealedSessionCipher
  in libsignal_protocol_dart). See sealed_sender.dart + SEALED_SENDER_REVIEW.md.
  Remaining: external cryptographer sign-off; H3/H4 construction hardening.

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

- [ ] \_DecayBar Timer disposal — cancel in dispose()
- [ ] Panic wipe SystemNavigator.pop() — test on Android
- [ ] [ ciphertext — restart cleared cache ] — tapping must not decrypt
- [ ] BIP-39 wordlist — externalise to asset file
- [ ] \_PanicWipeDialog — extract to shared widget
- [ ] Settings navigation — add gear icon to conversation list AppBar

### Relay

- [ ] Document --dart-define=SPECTRE_RELAY_URL for self-hosters
- [ ] Tor onion service setup guide
- [ ] Size padding at transport layer
- [ ] Prekey low-supply notification to client
- [ ] data/ gitignored — keys regenerated after accidental commit

---

## Security Decisions Log

| Decision                                  | Rationale                                                                                                                                                                |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| No phone number                           | Phone numbers are identity                                                                                                                                               |
| Random.secure() for all IDs               | math.Random() not cryptographically secure                                                                                                                               |
| PBKDF2 skipped                            | 256-bit true random needs no stretching                                                                                                                                  |
| temp_store = MEMORY                       | SQLite spills to unencrypted disk without this                                                                                                                           |
| Decrypt before persist                    | Bad ciphertext never touches DB                                                                                                                                          |
| sealed: true as default                   | Secure path = path of least resistance                                                                                                                                   |
| Per-step error swallowing in wipe         | Half-wiped is worse than skipping one step                                                                                                                               |
| e.runtimeType not e.toString()            | Exception messages embed triggering input                                                                                                                                |
| In-memory sessions                        | Force-close = session state evaporates                                                                                                                                   |
| isVerified never set programmatically     | Verification is a human act                                                                                                                                              |
| Messages never migrate                    | Migrating device may be compromised                                                                                                                                      |
| Jitter in reconnect backoff               | Prevents thundering herd timing signatures                                                                                                                               |
| Empty sender_id vs null                   | Even null field is a fingerprint                                                                                                                                         |
| NativeDatabase() not createInBackground() | FlutterSecureStorage cant cross isolate boundaries                                                                                                                       |
| Settings in FlutterSecureStorage          | No schema migration, Keystore-backed                                                                                                                                     |
| Skip Windows                              | Attack surface, wrong threat model                                                                                                                                       |
| Separate relay repo                       | Independent audit, community hosting                                                                                                                                     |
| Separate Ed25519 relay auth keypair       | Curve25519 Signal key incompatible with Go ed25519.Verify()                                                                                                              |
| /prekeys unauthenticated HTTP             | Public keys are public — no auth needed                                                                                                                                  |
| Bundle bound to WS userID not payload     | Only authenticated session is authority for ownership                                                                                                                    |
| SealedEnvelope type has no SenderID field | Compile-time metadata enforcement, not runtime check                                                                                                                     |
| Atomic tempfile+rename for queue          | Crash-safe — never torn file on disk                                                                                                                                     |
| Key file separate from queue file         | Backup queue without exposing key                                                                                                                                        |
| data/ removed from git history            | Keys accidentally committed — scrubbed with filter-branch                                                                                                                |
| Rejected OpenEnvelope-on-first-contact    | sender_id on the wire leaks the social-graph edge at first contact — the exact metadata the threat model protects; session init does not require it                      |
| Sealed sender built in-house              | libsignal_protocol_dart 0.4.1 has no SealedSessionCipher; construction layered on Curve ECDH + cryptography HKDF/AEAD + ed25519 cert (see Sealed Sender design section)  |
| Sender cert ik bound to registered bundle | Relay only knows the relay-auth key at auth time, not the Signal identity key; binding cert.ik to the authed user's published bundle keeps the userID the sole authority |

---

## Sealed Sender — Design (Session 3 — wired; awaiting external review)

### Why this section exists

The codebase talks about Sealed Sender as if `SealedSessionCipher` will
wrap outgoing ciphertext at the transport layer (see session_manager.dart
header + the flagged item "Sealed Sender transport enforcement"). **That
primitive does not exist in `libsignal_protocol_dart` 0.4.1** — there is
no `SealedSessionCipher`, `SenderCertificate`, or `ServerCertificate` in
the package. So sealed sender has to be built on the primitives the
package _does_ expose (`Curve` X25519 ECDH) plus `package:cryptography`
(HKDF, ChaCha20-Poly1305) and `package:ed25519_edwards` (cert verify,
matching the Go relay's `ed25519.Verify`).

### Root-cause bug being fixed

The **send** path is already metadata-safe (`sendMessage(sealed: true)`
omits sender_id on the wire). The **receive** path is broken: it _requires_
`envelope['sender_id']` and drops anything without it — so a sealed chat
message can never be received. The tempting "fix" (put sender_id back on
the wire as an OpenEnvelope for first contact) was REJECTED: it leaks the
exact (sender→recipient) social-graph edge to the relay at first contact,
which is precisely the metadata Principle #3 and the journalist/source
threat model exist to protect. First contact is the worst place to leak.
Session establishment (PreKeySignalMessage) does NOT require an open
envelope — the two layers are orthogonal.

### Upgrade evaluated and rejected as a shortcut

Checked whether bumping `libsignal_protocol_dart` would supply the missing
primitive: pulled and inspected **0.8.0** (latest). It has NO sealed sender
either — no `Sealed*`, `SenderCertificate`, `ServerCertificate`, or
`unidentified` anywhere in its `lib/`. The whole 0.x line of this Dart port
lacks it. 0.8.0 is also a breaking migration (snake_case file renames,
pointycastle 4.0, protobuf 6.0, ed25519_edwards 0.3.1). Conclusion: the
in-house construction below is required regardless of version; upgrading is
a separate maintenance decision with no sealed-sender payoff.

### Construction (sealed-sender-v1)

**Server CA.** Relay holds a long-term Ed25519 "sealed-sender CA" key
(`SPECTRE_SEALED_CA_PATH`, generated if absent). `GET /sealed-ca` returns
its public key (public by definition). Clients pin on first fetch (TOFU)
and cache.

**Sender certificate.** Over the authed WS the client sends
`{type:"request_sender_cert"}`. Relay replies
`{type:"sender_cert", cert:<b64 canonical-json>, signature:<b64>}` where
`cert = {uid, ik, exp}`:

- `uid` = the AUTHENTICATED userID (never client-supplied — same
  authority rule as prekey bundles).
- `ik` = the userID's Signal identity public key, taken from its
  REGISTERED prekey bundle on the relay (authoritative). Reject issuance
  if no bundle registered.
- `exp` = now + 24h. `signature` = Ed25519(CA_priv, canonical(cert)).

**Outer envelope (sender builds, recipient identity key `IK_R` known from
R's already-fetched prekey bundle):**

1. `E = Curve.generateKeyPair()` (ephemeral X25519).
2. `dh = Curve.calculateAgreement(IK_R_pub, E.priv)`.
3. `key = HKDF-SHA256(ikm=dh, salt=e_pub_raw||IK_R_raw,
info="spectre-sealed-sender-v1", L=32)` — binds ephemeral + recipient
   identity into the KDF (anti key-reuse / identity-misbinding).
4. `inner = canonical({cert, cert_sig, ct})`, `ct` = existing
   `encryptMessage` output (type+body envelope).
5. `aead = ChaCha20-Poly1305(key, nonce(12B random), aad=recipient_id,
inner)`.
6. `blob = e_pub_raw(32) || nonce(12) || aead_ct||tag`.
7. Wire `SealedEnvelope = {recipient_id, ciphertext:blob,
timestamp_ms, id:sha256hex(blob)}`.

**Receive:** split blob → ECDH with own identity priv → HKDF → AEAD-decrypt
(aad = own id; failure = drop, fail closed — this is the auth gate) →
parse inner → verify `cert_sig` against pinned CA pubkey + check `exp` →
extract authenticated `sender_id = cert.uid`. For a PreKey (type 3) inner
message, enforce `PreKeySignalMessage.getIdentityKey() == cert.ik` BEFORE
processing (binds the certified identity to the actual ratchet message, so
a hostile relay can't pair a valid cert with someone else's ciphertext).
Then run the existing decrypt flow with address = `sender_id`.

### Wire-format reconciliation (pre-existing bug, fix alongside)

Dart currently emits `{type, recipient_id, ciphertext:<string>, sealed,
timestamp}`; the Go `SealedEnvelope` wants `{recipient_id,
ciphertext:<[]byte b64>, timestamp_ms, id}`. Align Dart to the Go struct;
drop `type`/`sealed` from the sealed wire form (relay routes by shape).

### Residual leak (honest scope)

Uploading even a sealed blob over the AUTHENTICATED WS lets the relay
correlate sender at the TCP/session layer (already documented in
relay_service.dart). True fix = separate unauthenticated upload channel.
The cert design does NOT require an authenticated upload, so an anon
channel drops in later without protocol changes. Documented, not yet built.

### Review findings (Session 3 — author + independent agent pass)

A first adversarial review (self + independent reviewer) was done on the
core before wiring. Headline: the construction is a sound libsodium-style
sealed box for metadata hiding, but **the certificate is NOT sender
authentication against the relay**, because the untrusted relay IS the CA.

Findings, by severity:

- **C1 (design honesty) — FIXED in docs.** Relay-as-CA can forge attribution
  and MITM first contact (mints cert{uid:victim, ik:attacker} and satisfies
  the cert.ik==PreKey-identity binding itself). The ONLY defense is
  out-of-band fingerprint verification (Spectre already has it). Corrected
  the overstated comments in `sealed_sender.dart` and `sealed_ca.go`; the
  cert is metadata-hiding + honest-relay integrity, never auth-vs-relay.
  `senderId` is a CLAIM until the identity key is fingerprint-verified.
- **C2 (MUST build in integration) — WIRED (Session 3).** The `cert.ik ==
PreKeySignalMessage.getIdentityKey()` binding is now enforced:
  `SessionManager.assertFirstContactIdentity` parses the PreKey message
  (no ratchet advance / no OTPK burn — libsignal 0.4.1's `PreKeySignalMessage`
  exposes `getIdentityKey()`), strips the 0x05 tag, constant-time compares to
  the cert's raw ik, and throws `IdentityBindingException` on mismatch.
  `MessageService.receiveMessage` calls it after `open()` and BEFORE
  decrypt/session-init. Tested in `test/c2_binding_test.dart`
  (match / mismatch / WHISPER no-op against a real X3DH PreKey message).
- **H1 (MUST fix) — OPEN.** Cert is a 24h bearer token not bound to the
  envelope; combined with C2 a leaked/observed cert is re-stapleable.
  Bind it: include a digest of (eph_pub || recipient_id || inner-ct) in the
  AEAD-protected inner structure and verify on open; and/or shorten TTL.
- **H2 (MUST fix) — OPEN.** Expiry trusts a caller-supplied clock and there
  is no replay cache; a relay can redeliver a sealed PreKey blob to force
  repeated session resets / prekey consumption. Use a trusted clock, reject
  skew, add a short replay cache keyed on (eph_pub, nonce).
- **M1 (fail-closed contract) — FIXED.** ECDH / point-decode in open() and
  seal() now convert ArgumentError/InvalidKeyException to
  SealedSenderException (added a malformed-blob test).
- **M2/M3/L1/L2/L3 — DOCUMENTED.** Parse only over verified bytes (never
  re-canonicalize); recipient_id bound as AAD only (ok under 1:1 id↔key);
  CA key is HIGH-sensitivity (HSM + rotation-with-overlap, not "same as AES
  keys"); ed25519 sigs are malleable so never use cert_sig as a dedup key;
  never propagate SealedSenderException.reason outward (decryption oracle).

Second pass (3 parallel independent agents — sender-auth / primitives /
code-interop) — full consolidated table in SEALED_SENDER_REVIEW.md §5b:

- Primitive layer judged SOUND as written (no exploitable break).
- FIXED in core: M-NEW-2 (cert base64 fail-closed), M-NEW-4 (accept num exp
  for Dart-web), L-NEW-1 (double-unmarshal), H-NEW-1 (added Go→Dart Ed25519
  golden vector + more fail-closed tests; now 11 Dart + 2 Go tests green).
- NEW-HIGH-1 (PARTIAL): identity-key TOFU pinning + change detection now
  implemented (message_service.\_checkAndPinIdentity / decideIdentityPin,
  SecureDatabase.updateConversationKey, DecryptedMessage.senderKeyChanged;
  unit-tested). Pins the peer's session identity key on first contact, flags
  - marks-unverified on a later change. STILL OPEN: UI must surface
    senderKeyChanged; first-contact trust still needs the out-of-band
    fingerprint check (detection catches changes, not a first-contact MITM).
- H3/H4 (reviewer decision, OPEN): move pubkeys into HKDF IKM (match
  crypto_box_seal); add in-AEAD transcript commitment (also fixes H1).
  Deliberately NOT applied unilaterally — these are construction changes.

NOTE: this internal+agent review reduces but does NOT replace an EXTERNAL
cryptographer review. C2/H1/H2/NEW-HIGH-1 are blocking for production.

### Wiring landed (Session 3) — Sealed Sender connected end-to-end (client)

The previously-dead `SealedSender` core is now wired into the message path; the
relay no longer needs the DEV cleartext wrapper to attribute messages. Branch
`feat/sealed-sender-wiring-c2` in the spectre repo.

- **CA pinning (TOFU)** — new `lib/services/network/sealed_ca_service.dart`:
  fetches `GET /sealed-ca`, pins `public_key` under `spectre.sealed_ca_pub`,
  **fails closed on key change**, tolerant of fetch failure once pinned, then
  builds the `SealedSender`.
- **Sender certificate** — `relay_service.dart`: `request_sender_cert` send +
  `sender_cert` inbound case; in-memory cert cache (re-requested each cold
  start) with a 1h refresh margin and request coalescing.
- **Send** — `message_service.dart`: routes through fail-closed
  `_deliver`/`_sealForWire` — seals with the recipient IK (read from the
  established session store via `SessionManager.remoteIdentityKey`, so no
  per-message bundle refetch / OTPK burn) + the cached cert; if IK or cert
  isn't ready, the send is QUEUED, never sent unsealed.
- **Receive** — `message_service.dart`: replaced the plaintext-`sender_id`
  branch with `open()` → C2 (above) → existing decrypt flow. No `sender_id`
  fallback; an unopenable frame is dropped (fail closed).
- **Wiring** — `main.dart` constructs/injects `SealedSender` (skipped for
  `kDevSenderAttribution` builds; boot-resilient if the CA key is unreachable).
- **Dev wrapper** — `kDevSenderAttribution` + `_devWrap`/`_devUnwrap` left in
  place (off by default) as the known-good fallback until e2e-verified;
  removal is a later cleanup.
- **Manual e2e**: see `SEALED_SENDER_TEST.md`. Relay dev launcher:
  `spectre-relay/run-dev.sh`.

Still OPEN and blocking for production: H1 (in-AEAD transcript commitment),
H2 (trusted clock + replay cache — receive currently uses the device clock),
NEW-HIGH-1 (pin `isVerified` to identity-key bytes; until then `senderId` is a
CLAIM), and external cryptographer review.

### Crypto-review checklist (MUST pass before production — do not ship unreviewed)

- [x] HKDF context binding (ephemeral + recipient identity in salt/info)
- [x] AEAD aad = recipient_id; decrypt failure is the auth gate, fail closed (M1 fixed: ECDH/decode also fail closed)
- [x] cert signature + expiry verified before trusting sender_id (sig over exact bytes, then parse)
- [x] PreKey inner identityKey == cert.ik binding enforced <-- C2 WIRED (Session 3): SessionManager.assertFirstContactIdentity, called in receiveMessage before decrypt; tested
- [x] ephemeral key from CSPRNG (Curve.generateKeyPair), unique key per message; nonce random
- [x] failure paths silent-drop + log e.runtimeType only (no envelope bytes) <-- receive wiring drops on open()/C2 failure logging e.runtimeType only; SealedSenderException.reason never surfaced (L3)
- [~] independent review — internal author+agent pass DONE (see findings); EXTERNAL cryptographer review still required
- [ ] cert bound to envelope (H1) + replay cache & trusted clock (H2) <-- blocking
- [ ] cross-language test vector: Go-signed cert verified by Dart ed25519_edwards

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
- [x] Two real devices connected (send + receive working — via DEV sender-attribution wrapper, NOT sealed sender; relay can read `from`)
- [ ] First message between Linux and iPhone
- [ ] Relay deployed to VPS with real TLS
- [ ] Android tested
- [ ] Debug logs removed before production

---

Last updated: Session 3 (2026-05-30) — signed_prekey_id round-trip fixed; Sealed Sender wired into send/receive with C2 enforced (branch feat/sealed-sender-wiring-c2; unit-tested, e2e pending — see SEALED_SENDER_TEST.md)
Next session: run the two-device e2e (SEALED_SENDER_TEST.md), then close H1/H2/NEW-HIGH-1 and remove the DEV wrapper before any production use; external cryptographer review still required

5FOE5IP-U_PjwonZM1e_eQa1rtDXb4fLYZsobNxRfmM

zqvLRy1vS3ZiVVQmt6JQDpZEqc2CowGjMQkUJ3Vl8zE
