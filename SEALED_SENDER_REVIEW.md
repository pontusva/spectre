# Sealed Sender (sealed-sender-v1) — External Review Package

**Status: WIRED and in use for local/dev testing — Sealed Sender is now the
only wire path (the cleartext dev shim has been removed). C2 is implemented;
H1/H2 are addressed (see §5b). STILL REQUIRES an external cryptographer to
sign off on the bespoke construction before it is relied on to protect real
users.**

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

**Certificate** (relay-signed, `{uid, ik, iss, exp}`):
- `uid` = authenticated relay handle of the sender.
- `ik` = sender's Signal identity public key, taken by the relay from the
  sender's *own registered prekey bundle* (not from the request).
- `iss` = canonicalized domain of the issuing relay (structural host[:port]).
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
verify cert sig + expiry → `senderId = cert.uid`. C2 (IMPLEMENTED): for a
PreKey inner message, `PreKeySignalMessage.getIdentityKey()` MUST equal
`cert.ik` (constant-time, parse-only, before any decrypt/session init —
`SessionManager.assertFirstContactIdentity`); mismatch drops the message.

## 4. Artifacts to review

| Artifact | Path |
|----------|------|
| Client seal/open + cert verify | `lib/core/crypto/sealed_sender.dart` |
| Client CA TOFU-pin | `lib/services/network/sealed_ca_service.dart` |
| Receive/send wiring (seal/open, C2, key-pin, replay, history) | `lib/services/message_service.dart` |
| Inner Signal layer + C2 binding + remoteIdentityKey | `lib/core/crypto/session_manager.dart` |
| Relay CA key + cert issuance | `spectre-relay/server/sealed_ca.go` |
| Relay cert-request handling + `/sealed-ca` + rate limit | `spectre-relay/server/server.go` (`issueSenderCert`, `buildSenderCert`, `handleSealedCA`), `spectre-relay/server/ratelimit.go` |
| Full design + decisions + review findings | `SPECTRE_DEVLOG.md` → "Sealed Sender — Design" |
| Tests | client: `test/sealed_sender_test.dart` (14), `test/c2_binding_test.dart` (3), `test/identity_pin_test.dart` (3); relay: `server/sealed_ca_test.go` (3, incl. signed rotation) + `server/sealed_cert_test.go` (2, incl. rate limiter). **NOT YET WRITTEN:** Dart unit tests for the round-3 client hardening (padding, OOB-pin parsing, rotation-proof verify, seq-gap) and the relay `prekey_throttle_test.go` — see §9 notes. |

## 5. Findings from the internal (author + agent) pass

| ID | Severity | Status | Summary |
|----|----------|--------|---------|
| C1 | CRITICAL | docs fixed | Relay-as-CA can forge attribution & MITM first contact; cert is NOT auth-vs-relay. Defense = out-of-band fingerprint verification. **Confirm this framing.** |
| C2 | CRITICAL | **IMPLEMENTED + TESTED** | `cert.ik == PreKeySignalMessage.getIdentityKey()` enforced pre-decrypt, constant-time (`SessionManager.assertFirstContactIdentity`, wired in `message_service.receiveMessage`). Dedicated unit test now exists: `test/c2_binding_test.dart` (match / mismatch / WHISPER no-op). |
| H1 | HIGH | **EFFECTIVELY ADDRESSED** | The "24h bearer token / re-stapleable" concern is now covered by the existing construction + C2: the cert rides INSIDE the AEAD (encrypted to the recipient, key bound to eph_pub, AAD bound to recipient_id) so it isn't extractable by the relay/observers and is already bound to its envelope; and C2 stops a cert-holder from stapling it onto a forged PreKey message (would need the sender's identity private key). Residual is the C1 relay-as-CA case, which H1 never addressed. No code change warranted. |
| H2 | HIGH | **MOSTLY ADDRESSED** | Replay now guarded by a PERSISTENT dedup: receiveMessage drops any message whose content-hash id already exists in the DB (SecureDatabase.messageExists), before decrypt — so a relay replaying an old sealed envelope after a restart can't re-drive session setup or re-notify. Reuses the existing Messages table, no new on-disk metadata. Remaining minor: expiry still trusts the device clock (no trusted offline time source) — documented, acceptable. |
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
| NEW-HIGH-1 | HIGH | **ADDRESSED** | Identity-key TOFU pinning + change detection + UI. On decrypt the receive path pins the peer's *session* identity key into `Conversation.recipientPublicKey` (`_checkAndPinIdentity`/`decideIdentityPin`, persisted via `updateConversationKey`); a later mismatch logs a SECURITY event, marks the contact unverified, and flags `DecryptedMessage.senderKeyChanged`, which `chat_screen` surfaces as a sticky red banner. A tappable verify bar + the standalone two-column safety-number screen make verification actually reachable; contacts are now created on first contact so the fingerprint exists. Unit-tested (`identity_pin_test`). Residual is inherent: **first-contact** trust still rests on the human fingerprint compare (no software distinguishes a first-contact MITM from a new peer — same as Signal). Minor: pin lookup scans `getConversations()` (skips archived) per message. |
| NEW-HIGH-2 | HIGH | REDUCED | Now that sealed sender is wired, the receive path keys the session by the **cert-authenticated** `senderId` (`cert.uid`), not a raw relay field, and C2 binds it to the PreKey identity. Residual misattribution requires the relay-as-CA forgery (C1), not a relabel. |
| NEW-HIGH-3 | HIGH | REDUCED | The first-message fallback (`fetchBundle`/`initializeSession`) now runs on the **cert-authenticated** `senderId`, not the unauthenticated wire field. Minor TODO: it still fires for Whisper-type failures where it can't help — tighten to PreKey-only to avoid a relay nudging spurious bundle fetches. |
| H3 | HIGH | **FIXED** | KDF shape: fold `eph_pub‖recip_pub` into HKDF **IKM** (match libsodium `crypto_box_seal`) rather than the salt. Cryptographically equivalent today (both feed the same HMAC-extract), but standard + removes an attacker-salt question and a maintenance footgun. (Implemented: public keys bound directly to IKM with static salt.) |
| H4 | HIGH | **FIXED** | ChaCha20-Poly1305 is not key-committing; add a transcript commitment (`eph_pub‖recipient_id‖inner_ct`) inside the AEAD. Also resolves design-H1. Elevated by relay-as-CA active attacker. (Implemented: `eph_pub` and `recip_id` added to AEAD payload and verified on open.) |
| FED-1 | HIGH | **FIXED** | Cross-domain sender identity forgery via spoofed X-Spectre-Relay-ID on the unauthenticated `/federation/deliver` endpoint. Identity AND reply routing both now derive from the signed `cert.iss`; the `federation_sender_relay` header is only validated for agreement and never trusted on its own. `iss` is canonicalized (lowercased, structurally validated host[:port]) before being used as a CA pin key or fetch host, and `open()` refuses a cert whose `iss` differs from the issuer its CA key was resolved for. |
| H-NEW-1 | HIGH | **FIXED** | No Go→Dart Ed25519 cross-language vector existed. Added a golden vector (Go crypto/ed25519 sign → Dart ed25519_edwards verify + full seal/open). |
| M-NEW-2 | MED | **FIXED** | `_verifyCertificate` base64-decoded cert/sig/ik without fail-closed wrapping → raw `FormatException` could escape the contract. Now throws `SealedSenderException`. |
| M-NEW-4 | MED | **FIXED** | `exp is! int` rejected legit certs on Dart-web (JSON numbers are double). Now accepts `num` and normalizes. |
| M4 | MED | **FIXED** | Fold `recipient_id` into HKDF `info` (not only AAD) to bind the key to its routing target cryptographically. (Implemented: folded length-prefixed `recipient_id` into HKDF info.) |
| M5 | MED | NOTE | Length-prefix any variable field before it enters salt/info (preempts ambiguity if M4/H4 add variable-length data). FINE today. |
| M-NEW-1 | MED | NOTE | `cert.ik` is length-checked but not point-validated; real binding is C2 (compare to PreKey identity). decodePoint here would be no-op theater — deferred to C2. |
| M-NEW-3 | MED | **PARTIAL** | Added tests: wrong-length ik, expiry boundary (`==`), constructor rejects non-32 CA key, cross-language vector. Still untested: malformed base64 *inside* the sealed inner (needs a hand-crafted inner), Go `request_sender_cert` handler. |
| H-NEW-2 | MED | **FIXED** | Relay cert issuance is now rate-limited per user (`ratelimit.go`, 6/min) and the uid/ik binding is tested (`sealed_cert_test.go`: cert.uid = authenticated user, cert.ik = registered bundle key, verifies against CA, refused with no bundle). |
| L-NEW-1 | LOW | **FIXED** | `handleAuthedFrame` decoded the header twice; consolidated. |
| L-NEW-2 | LOW | **FIXED** | Removed the `DEV prekey registered` / `DEV auth success` logs that recorded the user id; `prekey bundle registered` dropped to Debug with no identifier. |
| cross-proto | — | NOTE | Reusing the libsignal identity key as the sealed-box static X25519 key is acceptable (XEdDSA domain-separates signing; the versioned HKDF `info` separates this DH from X3DH legs) but is **load-bearing on `info`** — never log raw `dh`; M4 strengthens it. |

### Biggest takeaways for the reviewer
1. **C1 is THE question.** The relay is the CA, so it can forge attribution / MITM first contact; everything rests on the user comparing the out-of-band safety number (now implemented + reachable). Confirm that framing, or tell us to decouple the CA from the relay. (NEW-HIGH-1's key-pinning + verify UI is now done — verification is no longer decorative.)
2. **H3 + H4** are the recommended construction hardening (move public keys into the KDF IKM; add an in-AEAD transcript commitment) — **IMPLEMENTED** after reviewer decision.
3. ~~The current app ships relay-trusted `sender_id`~~ RESOLVED: sealed sender is now fully wired (send seals, receive opens + C2 binding), the cleartext dev shim is removed, and NEW-HIGH-1 (key-pinning + verify UI) is implemented. The metadata property is delivered; what remains is the external sign-off on the construction itself.

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
   verifies. A Go-signed→Dart-verified golden vector is now in the tests
   (H-NEW-1); confirm the approach is sound.

## 7. What is tested (necessary, not sufficient)

- Dart `sealed_sender_test` (14): seal→open round-trip + sender auth;
  fail-closed on tampered blob, wrong recipient (AAD), expired cert, wrong CA,
  malformed/short blob, wrong-length ik, expiry `==` boundary, non-32 CA key,
  cert-issuer ≠ expectedIss, verified `senderDomain`, and the H4 in-AEAD
  commitment checks (eph_pub / recip_id mismatch → fail closed);
  **Go-signed→Dart-verified cross-language vector**.
- Dart `c2_binding_test` (3): C2 binding (match / mismatch / WHISPER no-op).
- Dart `identity_pin_test` (3): TOFU pin decision (first-use / matched / changed).
- Go `sealed_ca_test` (2): cert issue→verify + tamper rejection; CA key stable
  across reloads. Go `sealed_cert_test` (2): uid/ik binding + refuse-without-
  bundle; rate-limiter budget/isolation/reset.
- **Still missing:** the round-3 client hardening is IMPLEMENTED but NOT yet
  unit-tested — `_padInner`/`_unpadInner` (R3-4), `SealedCaService` OOB-pin
  parsing + rotation-proof verify (R3-2), `decideSeqGap`/`claimNextOutboundSeq`
  (R3-7), and the degenerate-dh reject (R3-6). The `round3_hardening_test.dart`
  these findings reference was never created. Relay-side `prekeyLimiter` (R3-5)
  likewise lacks `prekey_throttle_test.go`. Also still missing: malformed
  base64 *inside* the sealed inner; an end-to-end (real WS) integration test.
  (C2 NOW HAS a dedicated unit test — `test/c2_binding_test.dart`. Go-side CA
  rotation IS tested — `sealed_ca_test.go`. Sealed sender is fully wired into
  send/receive.)

## 8. Out of scope for this construction (documented elsewhere)

Anonymous upload channel (sealed blobs are still uploaded over the
authenticated WS → TCP-level sender correlation by the relay; needs a
separate unauthenticated transport — see `relay_service.dart` header),
cover traffic. (Message-size padding for the FIRST-CONTACT type oracle is now
addressed — see §9 R3-4 — but full traffic shaping for arbitrary-length
messages remains out of scope.)

## 9. Third pass (round 3) — findings and disposition

A third independent adversarial pass (full notes in the round-3 review
memo) confirmed the seal/open primitive layer is sound and surfaced
architectural + correctness items. Disposition below; "FIXED" items have
code + tests landed this session.

| ID | Sev | Status | Disposition |
|----|-----|--------|-------------|
| R3-1 | HIGH | OPEN (architectural) | "Decouple the CA" is insufficient on its own: the relay also owns registration + the prekey directory, so a separate CA fed by relay-served bundles is still forgeable. The real fix moves the uid↔ik registration authority OFF the relay (a separate directory service), demoting the relay to a dumb pipe that cannot serve bundles. Not closeable in a patch — this is the headline agenda item for the external/architectural review. Interim mitigation landed: out-of-band CA pin (see R3-2) removes the relay's ability to be its own pinned authority for configured deployments. |
| R3-2 | HIGH | **FIXED** | CA-rotation kill switch + no safe rotation path. (a) Client now accepts a changed CA key ONLY if the `/sealed-ca` response carries a rotation proof — `prev_public_key` == the pinned key AND `rotation_sig` = Ed25519(oldPriv, newPub) verifies under the pinned key (`SealedCaService._rotationProofValid`); an unsigned change still fails closed. Relay mints the proof from a `<path>.prev` file (`SealedCA` rotation, `/sealed-ca` serves it). (b) Out-of-band CA pin via `--dart-define=SPECTRE_SEALED_CA=domain:b64` (`SealedCaService.parseOobPins`, wired in `main.dart`): an OOB-pinned domain never TOFU-trusts the relay and a served key that disagrees fails closed. Tests: `sealed_ca_test.go` (`TestSealedCASignedRotation`: proof verifies under old key, NOT under new key, stable across reload) — **Go side covered. DART SIDE NOT YET TESTED:** the `round3_hardening_test.dart` referenced here (OOB-pin parsing, `_rotationProofValid`) was never created; `SealedCaService` rotation/OOB logic is currently unit-test-uncovered. |
| R3-3 | HIGH | PARTIAL (UI done, arch open) | Verification-before-attribution. The UI side is largely in place from NEW-HIGH-1: unverified state renders in danger-red as "sender identity is a relay claim", first-contact is a loud non-dismissible-as-trusted banner, key-change is sticky red. STILL the architectural residual of R3-1: first-contact MITM is undetectable in-band (same as Signal); only out-of-band safety-number compare anchors trust. Making verification strictly MANDATORY before any "secure" affordance (vs. reachable) is the remaining UX-rigor item. |
| R3-4 | MED | **FIXED** | First-contact size oracle. Sealed inner is now length-prefixed and zero-padded to a 1024-byte bucket before AEAD (`SealedSender._padInner`/`_unpadInner`), so a first-contact PreKey envelope and an established-session Whisper envelope are not size-distinguishable up to the bucket. **TEST NOT YET WRITTEN:** the `round3_hardening_test.dart` referenced here (`_padInner`/`_unpadInner` round-trip, two small inners → equal blob length, bucket-multiple overflow) was never created. `sealed_sender_test.dart` only uses a local padding helper to build the H4-commitment test inputs — it does not test the padding logic itself. |
| R3-5 | MED | **FIXED** | Unauthenticated OTPK drain → forward-secrecy downgrade. `/prekeys/{id}` is now per-TARGET rate-limited; over budget it serves the static bundle WITHOUT consuming an OTPK — byte-shape-identical to the legitimate exhausted fallback, so no new oracle (`prekeyLimiter`, `getBundleWithOTPK` in server.go / prekey_store.go). **TEST NOT YET WRITTEN:** the `prekey_throttle_test.go` referenced here was never created; the throttle path is currently unit-test-uncovered. |
| R3-6 | MED | **FIXED** | The outer AEAD is NOT an unconditional "auth gate": the libsignal-java-lineage `Curve.calculateAgreement` does not reject the all-zero/small-order result. `_deriveKey` now rejects an all-zero `dh` (constant-time) and the doc comments were corrected to state the outer layer is recipient-bound confidentiality, with the inner cert+ratchet as the actual authentication. |
| R3-7 | MED | **FIXED (detection)** | Hash dedup ≠ stream integrity — a relay can silently drop/withhold/reorder. Added a per-conversation monotonic sequence carried INSIDE the E2E payload (`{v:1,...,s:<seq>}`), claimed atomically per send (`claimNextOutboundSeq`), with forward-gap detection on receive (`decideSeqGap`, schema v5 `lastInboundSeq`). A gap surfaces a sticky `_SuppressionGapBanner` (decay-red, distinct from impersonation-red). Detection only — the dropped message cannot be recovered. **TEST NOT YET WRITTEN:** the `round3_hardening_test.dart` referenced here (`decideSeqGap`: in-order / gap / off-by-one / reorder / legacy-seqless) was never created; `decideSeqGap`/`claimNextOutboundSeq` are currently unit-test-uncovered. |
| R3-8 | LOW | NOTE | H4's transcript commitment is a transcript check, not AEAD key-commitment — true, and key-commitment isn't needed in this 1:1 receiver-derives-key model. Docs no longer claim it addresses non-committing AEAD; its value is cert-envelope binding. |
| R3-9 | LOW | NOTE | Cert `exp` is near-vestigial (cert rides confidentially inside the AEAD; relay-as-CA can re-mint), so the H2 "device-clock residual" is correctly LOW, not blocking. |
| R3-10 | LOW | NOTE | The raw-32 vs 0x05-tagged representation of eph_pub/recip_pub in the HKDF IKM is exercised by the seal→open round-trip + the Go→Dart golden vector; a silent representation mismatch fails closed (AEAD won't decrypt) and never "tries both". |
| R3-11 | INFO | NOTE | A client self-signature binding uid↔ik does not fix R3-1 (the attacker signs its own ik for the victim's uid — circular). Confirms no in-band crypto fix; only out-of-band verification or off-relay registration works. |

### Round-3 blocking items still open
1. **R3-1 / R3-3 (architectural):** move registration authority off the relay (separate directory service) and make out-of-band verification mandatory-before-attribution in the product, not merely reachable. The OOB CA pin (R3-2) is the landed interim; the structural fix is an external-review agenda item.
2. **External cryptographer review** of the bespoke construction AND the relay-as-CA/registration architecture — unchanged gate, not substituted by any internal pass.
