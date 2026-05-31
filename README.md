# Spectre

> *Invisible. Secure. Yours.*

Spectre is an end-to-end-encrypted messenger built for people for whom
**metadata is the threat** — activists, journalists, and their sources. It
pairs the Signal Protocol (Double Ratchet, X3DH) with an in-house **Sealed
Sender** layer so a relay operator learns only *who is receiving* and *how many
bytes*, never *who sent what to whom* — including on first contact.

- **Client:** Flutter (Linux/macOS/iOS/Android), Dart.
- **Relay:** a deliberately dumb Go store-and-forward (`../spectre-relay`).

---

## ⚠️ Security status — read this first

**Spectre is not ready to protect real people yet. Do not deploy it for
at-risk users.**

The Sealed Sender layer is a **bespoke cryptographic construction** (the Dart
Signal port ships no sealed-sender primitive, so it was built in-house on
X25519 / HKDF / ChaCha20-Poly1305 / Ed25519). It has had an internal +
multi-agent review and is unit-tested, but it **has not yet been reviewed by an
independent cryptographer** — which is a hard requirement before anyone relies
on it. The full review package, threat model, and open questions are in
[`SEALED_SENDER_REVIEW.md`](SEALED_SENDER_REVIEW.md).

The most important caveat: **the relay is also the certificate authority** for
sender certificates, so a malicious relay could forge sender attribution. The
only defense against that is **out-of-band safety-number verification** — so
*always verify the safety number* (see below). Treat an unverified contact's
identity as unconfirmed.

---

## Threat model (short version)

- **Adversary:** state actors, corporate surveillance, forensic device seizure.
- **The relay is untrusted.** It must not read content, learn the sender of a
  chat message, or be able to crash clients.
- **What the relay can still see** (by construction, documented honestly):
  recipient ID, message size + timing, client IP (use Tor/onion transport to
  mitigate — out of scope here), and — because uploads currently share the
  authenticated socket — the sender at the TCP layer (a separate anonymous
  upload channel is the real fix; not yet built).

### Security principles
1. **Fail closed** — every error defaults to the secure path.
2. **No plaintext at rest in the clear** — message text is persisted only in
   the SQLCipher-encrypted DB (key in the OS keystore).
3. **Minimal metadata** — the server learns as little as possible.
4. **Forward secrecy** — past messages stay safe if keys later leak.
5. **Panic wipe** — total identity destruction is always one action away.
6. **OPSEC by default** — the safe behaviour is the default.

---

## Features

- Signal Protocol E2E (X3DH + Double Ratchet) via `libsignal_protocol_dart`.
- **Sealed Sender** — sender identity hidden from the relay, carried in a
  recipient-encrypted, relay-signed certificate; bound to the ratchet message
  (C2) so a cert can't be re-stapled onto someone else's message.
- **Safety-number verification** — BIP-39-word fingerprints, two-column
  out-of-band comparison; identity keys are TOFU-pinned and a **key change is
  surfaced as a sticky warning**.
- **Message requests** — inbound from a peer you haven't accepted lands in a
  Requests inbox (long-press → **Accept** / **Block**); one-sided, no mutual
  add, auto-accepts if you both reach out. Block is silent + persistent.
- **Nicknames** — optional local label per contact, shown instead of the random
  ID (the ID stays on the peer screen). Local-only, never sent.
- No phone numbers — random base64url user IDs, never PII.
- Encrypted-at-rest history (SQLCipher), disappearing-message timers.
- Panic wipe — destroys identity, sessions, prekeys, DB key, and CA pin.
- No analytics, no read receipts, no plaintext logs.

---

## Repo layout

```
spectre/                      # this repo — the Flutter app
  lib/core/crypto/            # identity, prekeys, sessions, sealed_sender, relay-auth
  lib/core/storage/           # SQLCipher (drift) encrypted DB
  lib/services/               # message service + relay/prekey/CA network services
  lib/ui/                     # screens + theme
  SPECTRE_DEVLOG.md           # design log, decisions, file registry
  SEALED_SENDER_REVIEW.md     # external-review package for the bespoke crypto
  SEALED_SENDER_TEST.md       # manual two-device test checklist
spectre-relay/                # the Go relay (separate repo)
```

---

## Build & run (local two-device dev)

Requires the Flutter SDK and (for the relay) Go.

```bash
# 1) Relay — prints the LAN URL + the exact client commands
cd ../spectre-relay && ./run-dev.sh

# 2) Client on the relay host
cd spectre && ./run-linux.sh

# 3) Client on a second device (point at the relay's LAN IP)
RELAY_HOST=192.168.1.14 ./run-macos.sh
```

First run / after a schema change:
```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

Then: **⚙ → copy your ID** on each device, paste it into **＋ new
conversation** on the other. Adding a peer **sends them a connection request**
(a "wants to connect" message that lands in their **REQUESTS** inbox) — they
**long-press → Accept**, and you're chatting. Then **verify the safety number**
before trusting the contact. Full step-by-step:
[`SEALED_SENDER_TEST.md`](SEALED_SENDER_TEST.md).

In a chat, tap the **verification bar at the top** to open the peer screen —
that's where you **verify the safety number** and **set a nickname** (the
"nickname (local only)" row → **[ EDIT ]**). Incoming requests appear under
**REQUESTS**; **long-press** to Accept or Block.

`--dart-define=SPECTRE_RELAY_URL=ws://<host>:8080/ws` configures the relay
endpoint; there is no hardcoded server.

---

## Tests

```bash
flutter test                           # client (sealed-sender crypto, identity pinning, …)
cd ../spectre-relay && go test ./...   # relay (CA, cert issuance/binding, rate limit)
```

---

## Status

Functional end-to-end on Linux/macOS desktop with sealed sender, verification,
replay protection, and persistent history. **Before any real-world use:** the
external cryptographer review, the H3/H4 construction-hardening decisions, and
an anonymous upload channel (see `SEALED_SENDER_REVIEW.md` / `SPECTRE_DEVLOG.md`).

*Not affiliated with Signal / Open Whisper Systems. Uses the Signal Protocol.*
