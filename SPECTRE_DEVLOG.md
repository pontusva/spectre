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
| Platform targets | Android (primary), Linux, iOS, macOS |
| Flutter channel | master 3.45.0 |
| Dart SDK | ^3.13.0-138.0.dev |
| Dev machine | Debian GNU/Linux 12 (bookworm) |
| Android Studio | Panda4 Patch1 |
| Java | OpenJDK 21 (bundled in Android Studio JBR) |

---

## Threat Model

**Primary users:** activists, journalists, whistleblowers  
**Primary adversaries:** state actors, corporate surveillance, forensic device analysis

### Security Principles (in priority order)
1. **Fail closed** — every error defaults to the secure path
2. **No plaintext ever on disk** — schema enforces this at the database level
3. **Minimal metadata** — server learns as little as possible about who talks to whom
4. **Forward secrecy** — past messages safe even if keys are compromised
5. **Panic wipe** — full identity destruction must always be one deliberate action away
6. **OPSEC by default** — safe behaviour is the default, unsafe requires opt-in

---

## Architecture Overview

```
┌─────────────────────────────────────────┐
│              Flutter App                │
│                                         │
│  ui/         screens + theme + router   │
│  services/   message pipeline + relay   │
│  core/       crypto + storage + models  │
└─────────────────┬───────────────────────┘
                  │ WSS (TLS 1.3 only)
                  │ Sealed sender envelopes
┌─────────────────▼───────────────────────┐
│           spectre-relay (Go)            │
│                                         │
│  Pure router — no message persistence  │
│  Challenge-response auth               │
│  Encrypted offline queue (7d TTL)      │
│  No user database                      │
└─────────────────────────────────────────┘
```

---

## Dependencies

```yaml
libsignal_protocol_dart: ^0.4.0   # Signal Protocol E2E encryption
sqflite_sqlcipher: ^2.2.0         # Encrypted local database
flutter_secure_storage: ^9.0.0    # Android Keystore / Linux secret service
web_socket_channel: ^3.0.0        # WebSocket relay connection
pointycastle: ^3.7.3              # Additional crypto primitives
go_router: ^14.0.0                # Navigation
uuid: ^4.5.3                      # Random user IDs (no phone numbers)
```

---

## File Registry

### ✅ Completed

#### `lib/core/crypto/identity_manager.dart`
- Generates `IdentityKeyPair` + `registrationId` on first run
- Stores via `FlutterSecureStorage` (Keystore-backed)
- User ID: 32 bytes from `Random.secure()`, base64url, no padding
- `loadOrCreate()` — treats any partial identity as corrupt, regenerates
- `wipeIdentity()` — deletes three specific keys + drops in-memory refs
- `hasIdentity()` — added post-generation, used by router redirect
- **Note:** Dart string immutability prevents true memory scrubbing — acknowledged in comments

#### `lib/core/crypto/prekey_manager.dart`
- Generates 100 one-time PreKeys + 1 SignedPreKey on first run
- Per-record storage: `spectre.pk.<id>` — avoids rewriting giant blob
- Monotonic IDs — never reused, closes replay attack window
- `consumePreKey()` — deletes record (forward secrecy step), refills if < 20 remaining
- `rotateSignedPreKey()` — promotes current → previous (kept one period for in-flight inits), generates new current
- `isSignedPreKeyStale()` — 7-day check for scheduler
- `wipeAll()` — panic wipe companion

#### `lib/core/crypto/session_manager.dart`
- `InMemorySignalProtocolStore` — **in-memory by design** (forensic resistance)
- `initializeSession()` — `SessionBuilder.processPreKeyBundle()`, fails closed on signature mismatch
- Envelope format: `base64(JSON{ type, body })` — type tag routes PreKey vs Whisper
- `decryptMessage()` — handles both `PreKeySignalMessage` and `SignalMessage`
- **Critical doc block:** Sealed Sender warning — this layer only produces inner ratchet ciphertext. Transport layer MUST wrap with `SealedSessionCipher` or metadata protection is silently lost
- `hasSession`, `deleteSession`, `wipeAllSessions`

#### `lib/core/storage/secure_database.dart`
- Key: 32 bytes `Random.secure()`, hex-stored in FlutterSecureStorage
- Passed to SQLCipher as `"x'<hex>'"` — skips PBKDF2 (pointless for 256-bit true random)
- Schema: `messages`, `conversations`, `contacts`
- `messages.ciphertext BLOB NOT NULL` — schema enforces no plaintext on disk
- Partial index on `expires_at WHERE expires_at IS NOT NULL`
- `ON DELETE CASCADE` conversations → messages
- PRAGMAs: `cipher_secure_delete = ON`, `foreign_keys = ON`, `temp_store = MEMORY`
- `deleteExpiredMessages()` — hard delete, no tombstones
- `wipeDatabase()` — three layers: (1) secure_delete + VACUUM, (2) zero-overwrite + unlink (best-effort on flash), (3) key destruction (the real guarantee)

#### `lib/core/models/message.dart`
- `ciphertext: Uint8List` — no plaintext field, ever
- Class doc lists all leak vectors: sqflite cache, isolate snapshots, crash dumps, hot-reload state, ListView caches
- `isMine` — constructed-in, not persisted (device-relative truth)
- `isExpired` getter — UTC comparison
- Suggests `DecryptedMessage` transient type for View layer

#### `lib/core/models/conversation.dart`
- `recipientPublicKey` as base64 String, mediates against BLOB column
- `displayName` — always first 8 chars + `…` (OPSEC: shoulder-surfing, screenshots, lockscreen notifications)
- `unreadCount` — derived, not persisted (avoids counter drift bug class)

#### `lib/core/models/contact.dart`
- `isVerified` defaults to false — **must never be set programmatically**, only by human attestation
- `fingerprintWords` — maps fingerprint bytes to BIP-39 words (first 256), inline wordlist
- Words beat hex for spoken out-of-band verification (collision resistance preserved, just re-encoded)

#### `lib/services/network/relay_service.dart`
- URI injected at construction — no hardcoded endpoints
- Auth: server sends 32-byte challenge → client signs with identity key → no passwords, no tokens on disk
- Outgoing envelope: `SealedEnvelope` omits `sender_id` field entirely (even `null` would be a fingerprint)
- **Critical TCP warning:** Sealed sender is meaningless without Tor — TCP connection itself identifies sender
- Metadata leak doc: relay still sees IP, recipient ID, timing, size, authenticated session
- Reconnect: max 5 attempts, exponential backoff with jitter (prevents thundering herd timing signatures)
- `RelayConnectionState`: `disconnected / connecting / connected / reconnecting / failed`
- `wipeAndDisconnect()` — marks instance unusable, prevents ghost reconnections

#### `lib/services/message_service.dart`
- `sendMessage()`: encrypt → persist ciphertext → deliver or queue. `sealed: true` is default
- `receiveMessage()`: SHA-256 truncated dedup ID — same envelope = same hash = `ConflictAlgorithm.ignore`
- Decrypt before persist — bad ciphertext never touches DB
- `DecryptedMessage` — transient type, no `toMap/fromMap/copyWith`, structurally impossible to persist
- Pending queue: in-memory `Map<String, _PendingSend>` only — cleared on wipe
- `panicWipe()` order: relay → sessions → prekeys → DB → identity. Errors swallowed per-step — identity wipe must always run
- `_log()` chokepoint: no plaintext, no ciphertext, no key material, `e.runtimeType` not `e.toString()`

#### `lib/ui/theme/app_theme.dart`
- `SpectreColors`: blacks (`0xFF080808/0xFF0D0D0D`), purples (`0xFF2D0A3E/0xFF6B00A8`), blood reds (`0xFF8B0000/0xFFCC0000`), cold greys, matrix green (`0xFF00FF41`)
- `SpectreTypography`: JetBrains Mono primary + Courier fallback chain
- `AppTheme.dark()`: sharp corners everywhere (`borderRadius: zero`), elevation 0, hairline borders, fade-only page transitions
- `NoisePainter` + `ScanlinePainter` — deterministic sparse pixels, 3px scanline spacing
- `NoiseBackground`, `DashedDivider`, `HairlineDivider`, `SpectreSpacing`, `SpectreIcon`

#### `lib/ui/screens/conversation_list_screen.dart`
- Unread count via raw SQL join (`is_read = 0 AND sender_id != currentUserId`)
- Purple accent stripe on tiles (brightens when unread)
- `_PanicWipeDialog` — lists what will be destroyed, `[ABORT] / [WIPE]`
- Long-press → `_ConversationActionsSheet`: `[ARCHIVE] / [DELETE]`
- FAB → `_NewConversationDialog`

#### `lib/ui/screens/chat_screen.dart`
- Historical messages without live plaintext show `[ ciphertext — restart cleared cache ]`
- Live decryptions merged from `messageService.decryptedMessages` stream
- `_DecayBar` — `Timer.periodic(200ms)`, 2px shrinking bar for disappearing messages
- `_GlitchTitle` — red/purple/grey stacked layers, ±2px random shift over 1200ms, then settles
- `_StatusGlyph` — matrix green `●` sent/delivered, dim `○` queued, red `!` failed. No read receipts
- `_ComposerBar` — matrix green liveness dot, green cursor, `[ SEND ]`

#### `lib/ui/theme/router.dart`
- `SpectreServices` container — identity + database + optional full-stack + callbacks
- `RouteExtras` — services + optional `Conversation` or `Contact`
- Redirect: forces `/onboarding` when no identity, forces away once identity exists
- Fade transitions only — `CustomTransitionPage` with `FadeTransition`
- Routes: `/onboarding`, `/conversations`, `/chat/:conversationId`, `/contact/:userId`, `/settings`

#### `lib/main.dart`
- Init order: `IdentityManager` → `SecureDatabase.open()` → `hasIdentity` probe
- If no identity: partial `SpectreServices`, route to `/onboarding` (no crypto minted without consent)
- If identity: `PreKeyManager` → `SessionManager` → `RelayService` → `MessageService`
- Relay URL via `--dart-define=SPECTRE_RELAY_URL`, default `wss://relay.invalid` (fails loudly)
- `WidgetsBindingObserver` — `deleteExpiredMessages()` on every foreground resume
- `_BootScreen` — glitching SPECTRE, `_BlockSpinnerPainter`, "nothing phones home"
- `_ErrorScreen` — `e.runtimeType` not `e.toString()`, `[RETRY] / [WIPE]`
- Zero analytics / Firebase / crash reporting

### 🔲 In Progress
- `lib/ui/screens/onboarding_screen.dart` — prompt running now

### 🔲 Pending
- `lib/ui/screens/contact_screen.dart`
- `lib/ui/screens/settings_screen.dart`
- `lib/core/models/decrypted_message.dart` (transient type, explicit file)
- `lib/ui/screens/qr_code_screen.dart`
- `lib/ui/screens/migration_screen.dart`
- `lib/core/migration/migration_manager.dart`
- `spectre-relay/` — Go relay server (full project)

---

## Relay Server Plan (Go)

**Why Go:** single static binary, goroutine concurrency, strong stdlib crypto, tiny Docker image, auditable

### Architecture
```
spectre-relay/
├── main.go
├── config/config.go       ← env-var based, no config files on disk
├── model/envelope.go      ← SealedEnvelope + OpenEnvelope (separate types)
├── server/
│   ├── server.go          ← net/http + WebSocket, TLS 1.3 minimum
│   ├── auth.go            ← challenge-response, 5 attempts/min per IP
│   ├── router.go          ← message routing + rate limiting
│   └── store.go           ← in-memory registry + encrypted offline queue
├── Dockerfile
└── docker-compose.yml
```

### Offline Message Persistence (Option B — chosen)
- Encrypted on-disk storage with relay-local key
- 7-day TTL, deleted immediately on delivery
- Capped at 500 messages per recipient
- Background ticker purges expired messages
- Relay restart: messages survive
- Relay breach: ciphertext only, relay has no decryption key

### What relay sees (unavoidable metadata)
- IP address of sender
- Recipient ID
- Message timing
- Message size
- Authenticated session identity
- **Mitigations:** Tor (hides IP), padding (hides size), cover traffic (hides timing) — these are higher-layer, out of scope for relay itself

---

## Contact Adding Methods

| Method | How | MITM Risk | Verification |
|--------|-----|-----------|--------------|
| QR Code | Scan in person | None (physical presence) | Optional, already safe |
| Spectre ID | Share via any channel | Yes | Required — verify fingerprint words out of band |
| Invite link | `spectre://invite/<base64>` | Yes | Required — verify fingerprint words out of band |

**Golden rule:** Always verify fingerprint words out of band regardless of add method.

---

## Identity / Migration Model

| Event | Identity | Contacts | Messages | Re-verify? |
|-------|----------|----------|----------|------------|
| Normal migration | ✅ Preserved | ✅ Preserved | ❌ Stays on old device | ❌ No |
| Panic wipe | ❌ Burned | ❌ Gone | ❌ Gone | ✅ Yes, everyone |
| Contact key change | — | ⚠️ Warning | — | ✅ Yes, that contact |

**Messages never migrate** — by design and non-negotiable.

---

## Remember Later — Flagged Issues

### Crypto
- [ ] `_reconstructPendingQueue()` on startup — comment in `message_service.dart` says it's possible but not implemented
- [ ] Session mutex — concurrent ratchet advances can corrupt session state, needs mutex in service layer
- [ ] No message ordering guarantee — WebSocket can reorder, need sequence numbers or vector clock
- [ ] Sealed Sender transport enforcement — someone writing the transport layer must actually wrap with `SealedSessionCipher`

### Storage
- [ ] `VACUUM` during wipe runs on main thread — move to background isolate for large databases
- [ ] `ON DELETE CASCADE` direction — verify it's conversations → messages not reverse
- [ ] Key never logged — add lint/comment warning, especially for debug builds
- [ ] `expiresAt` UTC consistency — ensure DB stores all timestamps in UTC

### Network
- [ ] Message padding — variable message size leaks content information, need fixed-size buckets
- [ ] Malformed frame counter — silent drop is correct but relay sending 1000 bad frames = DoS, need detection + disconnect
- [ ] Cover traffic — dummy messages to obscure timing patterns (post-MVP)

### UI
- [ ] `_DecayBar` Timer disposal — must cancel in `dispose()` to prevent memory leak
- [ ] Panic wipe `SystemNavigator.pop()` — test on Android, some launchers restore state
- [ ] `[ ciphertext — restart cleared cache ]` — ensure tapping does not attempt decryption
- [ ] BIP-39 wordlist — currently inline (~3KB), externalise to asset file later
- [ ] Unverified contact UX — UI needs to handle gaps gracefully when sealed sender has no resolved sender

### Relay (Go)
- [ ] `--dart-define=SPECTRE_RELAY_URL` must be documented for self-hosters
- [ ] Tor onion service setup guide needed
- [ ] Size padding at transport layer

---

## Security Decisions Log

| Decision | Rationale |
|----------|-----------|
| No phone number registration | Phone numbers are identity — linkable to real person |
| `Random.secure()` for all IDs | `math.Random()` is not cryptographically secure |
| PBKDF2 skipped for DB key | 256-bit true random needs no stretching |
| `temp_store = MEMORY` pragma | Without this, SQLite spills to unencrypted disk files |
| Decrypt before persist | Bad ciphertext never touches DB, no dangling rows |
| `sealed: true` as default | Secure path = path of least resistance |
| Per-step error swallowing in wipeAll | A wipe that stops halfway is worse than one that skips a step |
| `e.runtimeType` not `e.toString()` | Exception messages often embed the triggering input |
| In-memory sessions | Forensic resistance — force-close = session state evaporates |
| `isVerified` never set programmatically | Verification is a human act, not a code path |
| Messages never migrate | Migrating device may already be compromised |
| Jitter in reconnect backoff | Prevents fleet-wide thundering herd timing signatures |
| Empty `sender_id` field vs omitted | Even `null` field is a fingerprint — omit entirely |

---

## Prompt History

All prompts used to generate files are tracked here for regeneration.

### Prompt — identity_manager.dart
```
You are a senior Dart/Flutter security engineer building "Spectre"...
[generate identity_manager.dart with FlutterSecureStorage, Random.secure() userId,
loadOrCreate(), wipeIdentity()]
```

### Prompt — prekey_manager.dart
```
[generate prekey_manager.dart with 100 prekeys, per-record storage,
monotonic IDs, consumePreKey(), rotateSignedPreKey(), wipeAll()]
```

### Prompt — session_manager.dart
```
[generate session_manager.dart with InMemorySignalProtocolStore,
initializeSession(), encryptMessage(), decryptMessage(), sealed sender doc block]
```

### Prompt — secure_database.dart
```
[generate secure_database.dart with SQLCipher, Random.secure() key,
messages/conversations/contacts schema, deleteExpiredMessages(), wipeDatabase()]
```

### Prompt — models (message, conversation, contact)
```
[generate message.dart (no plaintext field), conversation.dart (OPSEC displayName),
contact.dart (BIP-39 fingerprintWords, isVerified human-only)]
```

### Prompt — relay_service.dart
```
[generate relay_service.dart with challenge-response auth, sealed envelopes,
exponential backoff with jitter, metadata leak documentation]
```

### Prompt — message_service.dart
```
[generate message_service.dart orchestrating SessionManager + SecureDatabase +
RelayService, SHA-256 dedup, DecryptedMessage transient type, panicWipe() order,
_log() chokepoint]
```

### Prompt — app_theme.dart + conversation_list + chat_screen
```
[generate $uicideboy$ aesthetic theme: blacks, purples, blood reds, matrix green,
JetBrains Mono, NoisePainter, ScanlinePainter, GlitchTitle, DecayBar]
```

### Prompt — router.dart + main.dart
```
[generate SpectreServices container, RouteExtras, buildSpectreRouter() with
fade transitions, init pipeline with consent-gated crypto, BootScreen, ErrorScreen]
```

### Prompt — onboarding_screen.dart
```
[RUNNING NOW — three steps: INITIATE / PROTOCOL / FINGERPRINT,
PageView locked, ScrollController gate on step 3, $uicideboy$ aesthetic]
```

---

## Build & Run

```bash
# Install dependencies
flutter pub get

# Run on Linux
flutter run -d linux

# Run on Android (device connected)
flutter run -d android

# Build Android APK
flutter build apk --dart-define=SPECTRE_RELAY_URL=wss://your-relay.example.com

# Build Android App Bundle
flutter build appbundle --dart-define=SPECTRE_RELAY_URL=wss://your-relay.example.com
```

---

## Relay Deployment (coming soon)

```bash
# Build relay binary
cd spectre-relay
go build -o spectre-relay .

# Run with TLS
SPECTRE_RELAY_ADDR=:443 \
SPECTRE_TLS_CERT=/etc/ssl/spectre.crt \
SPECTRE_TLS_KEY=/etc/ssl/spectre.key \
./spectre-relay

# Docker
docker-compose up -d
```

---

*Last updated: session ongoing*  
*Next: onboarding_screen.dart → contact_screen.dart → settings_screen.dart → Go relay*