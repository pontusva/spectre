# Sealed Sender (sealed-sender-v1) — External Review Package

**Status: AWAITING EXTERNAL CRYPTOGRAPHER REVIEW. Do not wire into the app
or ship until C2/H1/H2 (below) are resolved and this construction is signed
off by a reviewer independent of its author.**

This document is the entry point for an external review of Spectre's
in-house Sealed Sender construction. It is self-contained but points to the
exact source artifacts for detail.

---

## 1. Why this exists

Spectre is a Signal-Protocol messenger for activists/journalists. The
desired property: the relay sees only `(recipient_id, opaque_blob,
timestamp)` for every chat message — never the sender — **including on first
contact**. `libsignal_protocol_dart` 0.4.1 (and 0.8.0, verified) ships **no**
`SealedSessionCipher`/`SenderCertificate`, so the metadata layer was built
in-house on: libsignal `Curve` (X25519 ECDH), `package:cryptography`
(HKDF-SHA256, ChaCha20-Poly1305), and `package:ed25519_edwards` (cert
verification, byte-compatible with the Go relay's `crypto/ed25519`).

## 2. Threat model (the crux)

- Adversary: state actors / corporate surveillance / forensic device seizure.
- **The relay is UNTRUSTED** — explicitly a dumb store-and-forward; a hostile
  relay must not be able to read content or crash clients.
- **TENSION TO SCRUTINIZE: the relay is also the certificate authority.** It
  holds the sealed-sender CA private key and issues the sender certificates.
  This is the single most important thing to review (see Finding C1). The
  design's position is that the cert provides metadata-hiding +
  honest-relay/third-party integrity, and that **sender-identity trust rests
  entirely on out-of-band fingerprint verification** (which Spectre has). We
  need an expert to confirm that framing is correct and sufficiently
  defended, or to reject it.

## 3. The construction

**Certificate** (relay-signed, `{uid, ik, exp}`):
- `uid` = authenticated relay handle of the sender.
- `ik` = sender's Signal identity public key, taken by the relay from the
  sender's *own registered prekey bundle* (not from the request).
- `exp` = issuance + 24h. Signature = Ed25519(CA_priv, exact-json-bytes).
- Client verifies the signature over the exact received bytes (no
  re-canonicalization), then parses, then checks expiry.

**Outer envelope** (sender → recipient `R`, whose identity public key `IK_R`
is known from R's prekey bundle):
1. ephemeral X25519 `E = Curve.generateKeyPair()`.
2. `dh = X25519(IK_R_pub, e_priv)`.
3. `key = HKDF-SHA256(ikm=dh, salt=e_pub_raw‖IK_R_raw, info="spectre-sealed-sender-v1", L=32)`.
4. `inner = json{cert, cert_sig, ct}`, where `ct` = the inner libsignal
   Double-Ratchet ciphertext (type+body).
5. `aead = ChaCha20-Poly1305(key, nonce=random12, aad=recipient_id, inner)`.
6. `blob = e_pub(32) ‖ nonce(12) ‖ ciphertext ‖ mac(16)`.

This is an anonymous sealed box (cf. libsodium `crypto_box_seal`) with an
inner relay-signed cert added for sender labeling.

**Receive:** split blob → `dh = X25519(e_pub, IK_self_priv)` → same HKDF →
AEAD-decrypt (AAD = own id; failure = fail closed, this is the auth gate) →
verify cert sig + expiry → `senderId = cert.uid`. Intended (but NOT YET
WIRED — see C2): for a PreKey inner message, require
`PreKeySignalMessage.getIdentityKey() == cert.ik` before establishing the
session.

## 4. Artifacts to review

| Artifact | Path |
|----------|------|
| Client seal/open + cert verify | `lib/core/crypto/sealed_sender.dart` |
| Relay CA key + cert issuance | `spectre-relay/server/sealed_ca.go` |
| Relay cert-request handling + `/sealed-ca` | `spectre-relay/server/server.go` (`issueSenderCert`, `handleSealedCA`, `handleAuthedFrame`) |
| Inner Signal layer + threat-model notes | `lib/core/crypto/session_manager.dart` |
| Full design + decisions + review findings | `SPECTRE_DEVLOG.md` → "Sealed Sender — Design" |
| Tests | `test/sealed_sender_test.dart` (6), `spectre-relay/server/sealed_ca_test.go` (2) |

## 5. Findings from the internal (author + agent) pass

| ID | Severity | Status | Summary |
|----|----------|--------|---------|
| C1 | CRITICAL | docs fixed | Relay-as-CA can forge attribution & MITM first contact; cert is NOT auth-vs-relay. Defense = out-of-band fingerprint verification. **Confirm this framing.** |
| C2 | CRITICAL | **OPEN/unbuilt** | `cert.ik == PreKey identity` binding has no caller yet; must be implemented + mismatch-tested in the receive path. |
| H1 | HIGH | **OPEN** | Cert is a 24h bearer token not bound to the envelope → re-stapleable. Bind a digest of `eph_pub‖recipient_id‖inner-ct` inside the AEAD, and/or shorten TTL. |
| H2 | HIGH | **OPEN** | Expiry trusts caller clock; no replay cache → replayed PreKey blob forces session resets / prekey burn. Trusted clock + skew bound + replay cache. |
| M1 | MEDIUM | fixed | ECDH/point-decode now fail closed as `SealedSenderException` (was raw `ArgumentError`). |
| M2 | MEDIUM | documented | Parse only over verified bytes; never re-canonicalize cert/inner JSON. |
| M3 | MEDIUM | documented | `recipient_id` bound as AAD only (ok under 1:1 id↔key; revisit if handles rebind). |
| L1 | LOW | documented | CA key is HIGH sensitivity → HSM + rotation-with-overlap + pin-change alerting (TOFU re-pin alone is exploitable by the relay). |
| L2 | LOW | documented | Ed25519 sigs are malleable — never use `cert_sig` as a dedup/identity key. |
| L3 | LOW | documented | `SealedSenderException.reason` must never be surfaced to UI/relay/logs (decryption oracle). |

## 5b. Second pass — three parallel independent agents (sender-auth / primitives / code-interop)

A second review used three independent reviewers with distinct lenses. The
primitive layer was judged **sound as written** (no exploitable break in the
seal/open math). New items below; "fixed" ones were applied to the core
(they are fail-closed/correctness hardening, NOT construction changes).

| ID | Sev | Status | Summary |
|----|-----|--------|---------|
| NEW-HIGH-1 | HIGH | **PARTIAL** | Identity-key TOFU pinning + change detection now implemented: on a successful decrypt the receive path pins the peer's *session* identity key into `Conversation.recipientPublicKey` (`message_service._checkAndPinIdentity`, pure decision in `decideIdentityPin`, persisted via `SecureDatabase.updateConversationKey`); a later mismatch logs a SECURITY event, marks the contact unverified, and flags `DecryptedMessage.senderKeyChanged`. Additive/non-fatal (never blocks delivery); unit-tested (`test/identity_pin_test.dart`). STILL OPEN: (a) the UI must actually surface `senderKeyChanged` and block/warn; (b) **first-contact** trust still depends on the human comparing fingerprints out of band (the app now detects *changes*, but cannot distinguish a legitimate reinstall from a relay-as-CA MITM on the very first message — only the existing contact_screen fingerprint check can). So C1 is mitigated for *key changes*, not yet for first contact. Minor: pin lookup uses `getConversations()` (skips archived) and scans per message. |
| NEW-HIGH-2 | HIGH | OPEN (integration) | UKS/misattribution: inner session is keyed by the relay-controlled peer id; a relay can relabel frames or drive session creation under an attacker-chosen label. Resolved by deriving peer id only from the verified cert + AAD binding + C2. |
| NEW-HIGH-3 | HIGH | OPEN (integration) | First-message fallback (`message_service.dart:254-258`) does `fetchBundle(senderId)` + `initializeSession(senderId,…)` on the **unauthenticated** relay `senderId` before any verification → attacker-driven session/ OTPK burn. |
| H3 | HIGH | **OPEN — reviewer decision** | KDF shape: fold `eph_pub‖recip_pub` into HKDF **IKM** (match libsodium `crypto_box_seal`) rather than the salt. Cryptographically equivalent today (both feed the same HMAC-extract), but standard + removes an attacker-salt question and a maintenance footgun. |
| H4 | HIGH | **OPEN — reviewer decision** | ChaCha20-Poly1305 is not key-committing; add a transcript commitment (`eph_pub‖recipient_id‖inner_ct`) inside the AEAD. Also resolves design-H1. Elevated by relay-as-CA active attacker. |
| H-NEW-1 | HIGH | **FIXED** | No Go→Dart Ed25519 cross-language vector existed. Added a golden vector (Go crypto/ed25519 sign → Dart ed25519_edwards verify + full seal/open). |
| M-NEW-2 | MED | **FIXED** | `_verifyCertificate` base64-decoded cert/sig/ik without fail-closed wrapping → raw `FormatException` could escape the contract. Now throws `SealedSenderException`. |
| M-NEW-4 | MED | **FIXED** | `exp is! int` rejected legit certs on Dart-web (JSON numbers are double). Now accepts `num` and normalizes. |
| M4 | MED | OPEN — reviewer decision | Fold `recipient_id` into HKDF `info` (not only AAD) to bind the key to its routing target cryptographically. |
| M5 | MED | NOTE | Length-prefix any variable field before it enters salt/info (preempts ambiguity if M4/H4 add variable-length data). FINE today. |
| M-NEW-1 | MED | NOTE | `cert.ik` is length-checked but not point-validated; real binding is C2 (compare to PreKey identity). decodePoint here would be no-op theater — deferred to C2. |
| M-NEW-3 | MED | **PARTIAL** | Added tests: wrong-length ik, expiry boundary (`==`), constructor rejects non-32 CA key, cross-language vector. Still untested: malformed base64 *inside* the sealed inner (needs a hand-crafted inner), Go `request_sender_cert` handler. |
| H-NEW-2 | MED | OPEN | Relay cert issuance has no per-user rate limit and the uid/ik auth-binding is untested. Add a server test driving `request_sender_cert`. |
| L-NEW-1 | LOW | **FIXED** | `handleAuthedFrame` decoded the header twice; consolidated. |
| L-NEW-2 | LOW | OPEN | Dev log leaks full `uid` (`server.go` `DEV prekey registered`) — already on the project's "remove before production" list. |
| cross-proto | — | NOTE | Reusing the libsignal identity key as the sealed-box static X25519 key is acceptable (XEdDSA domain-separates signing; the versioned HKDF `info` separates this DH from X3DH legs) but is **load-bearing on `info`** — never log raw `dh`; M4 strengthens it. |

### Biggest takeaways for the reviewer
1. **NEW-HIGH-1** is the one that most undermines the stated defense: C1 says "trust rests on out-of-band fingerprint verification," but verification is currently decorative (handle-keyed, never enforced, not pinned to key bytes). This needs to be a real, key-pinned gate.
2. **H3 + H4** are the recommended construction hardening (move public keys into the KDF IKM; add an in-AEAD transcript commitment) — these are design decisions we deliberately did NOT apply unilaterally; they want your sign-off.
3. The current app already ships relay-trusted `sender_id` (sealed sender unwired), so it has **no** metadata protection today — the integration is what delivers the property, and must carry C2/H1/H2/NEW-HIGH-1/2/3.

## 6. Specific questions for the reviewer

1. **C1:** Is "cert = metadata hiding + honest-relay integrity, with sender
   trust resting on out-of-band fingerprint verification" a correct and
   adequately-defended position given the relay-is-CA design? Or should the
   CA be decoupled from the relay (separate directory authority)?
2. Is the HKDF context binding (salt = `eph_pub‖recip_pub`, versioned info)
   sufficient, or should `recipient_id`/`sender_id` also be folded in?
3. Is the proposed H1 cert-to-envelope binding the right shape?
4. Any issue with X25519 low-order/non-canonical ephemeral points beyond the
   self-DoS we already fail-closed on (M1)?
5. Cross-language Ed25519: Go `crypto/ed25519` signs, Dart `ed25519_edwards`
   verifies. We assert RFC 8032 byte-compat (already used for relay auth) but
   have NOT yet added a Go-signed→Dart-verified test vector. Confirm needed.

## 7. What is tested (necessary, not sufficient)

- Dart (6): seal→open round-trip + sender authentication; fail-closed on
  tampered blob, wrong recipient (AAD), expired cert, wrong CA, malformed/
  short blob.
- Go (2): cert issue→verify against published pubkey + tamper rejection; CA
  key stable across reloads.
- **Missing:** cross-language cert vector; C2 binding test; H1/H2 behavior;
  end-to-end integration (the receive path is not wired yet).

## 8. Out of scope for this construction (documented elsewhere)

Anonymous upload channel (sealed blobs are still uploaded over the
authenticated WS → TCP-level sender correlation by the relay; needs a
separate unauthenticated transport — see `relay_service.dart` header),
message-size padding, cover traffic.
