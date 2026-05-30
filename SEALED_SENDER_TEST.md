# Sealed Sender — Manual Two-Device Verification

End-to-end test for the Sealed Sender wiring (Session 3): real metadata-hiding
delivery between two clients, with the relay learning only
`(recipient_id, opaque_blob)` — never the sender. Unit coverage lives in
`test/sealed_sender_test.dart` and `test/c2_binding_test.dart`; this document
covers what only a running stack can confirm.

> The DEV cleartext wrapper (`kDevSenderAttribution`) is the known-good
> fallback and is **off by default**. The sealed path below is what runs when
> the flag is NOT set.

## Prerequisites
- Go toolchain installed (relay) and Flutter set up for the target device(s).
- Build the app **without** `--dart-define=SPECTRE_DEV_ATTRIBUTION=true`.

## 1. Start the relay (dev mode)
From the relay repo (or use `./run-dev.sh` — see that script):
```bash
SPECTRE_DEV=true SPECTRE_LISTEN_ADDR=":8080" \
SPECTRE_QUEUE_PATH="./data/offline_queue.enc" \
SPECTRE_PREKEY_PATH="./data/prekeys.enc" \
SPECTRE_SEALED_CA_PATH="./data/sealed_ca.key" \
go run .
```

## 2. Launch two clients
Each, against the relay (`<relay-host>` = `localhost` or the LAN IP for a phone):
```bash
flutter run -d <device> --dart-define=SPECTRE_RELAY_URL=ws://<relay-host>:8080/ws
```
- [ ] Both onboard and connect; relay logs `prekey bundle registered` for each.
- [ ] On first send, each client fetches/pins the CA key (`GET /sealed-ca`) and
      obtains a sender cert (`request_sender_cert` → `sender_cert`).

## 3. First contact A → B  (open() + C2 path)
- [ ] B renders the plaintext.
- [ ] The delivery frame carries **only** `recipient_id` + opaque `ciphertext` —
      **no `sender_id`, no `from`**. (The metadata win over the dev wrapper.)
- [ ] B's `[MessageService]` log shows neither `dropped sealed envelope` nor
      `identity binding` — i.e. `open()` succeeded and C2 passed.

## 4. Reply B → A  (whisper path, established session)
- [ ] A renders it. C2 is a no-op for non-first-contact (no drop).

## 5. Negative — CA pin mismatch (fail closed)
- Regenerate a *different* `sealed_ca.key` (delete the file, restart the relay),
  then point an **already-pinned** client at it.
- [ ] The pinned client fails closed (`SealedCaException` path): no sealed
      messaging, no key silently trusted.
- [ ] A *fresh install* instead TOFU-pins the new key (expected — that's the
      first-use anchor, not a downgrade).

## 6. Negative — forged / tampered envelope
- Primarily covered by `test/sealed_sender_test.dart` (tampered blob, wrong
  recipient, expired cert, wrong CA, wrong-length ik).
- With a tampering proxy on the wire: flip a blob byte →
  [ ] B logs `dropped sealed envelope :: <type>`, nothing renders.

## 7. Regression — dev wrapper still works
- Re-run both clients with `--dart-define=SPECTRE_DEV_ATTRIBUTION=true`.
- [ ] Existing two-device path still delivers (fallback unchanged).

## Known limitations exercised here (deferred blockers)
- **H2**: the receive path uses the device clock for cert-expiry and has no
  replay cache — a relay could redeliver a sealed PreKey blob. Trusted clock +
  `(eph_pub, nonce)` cache are a follow-up.
- **H1 / NEW-HIGH-1**: cert not yet bound to the envelope; `isVerified` not yet
  pinned to identity-key bytes. Until NEW-HIGH-1 lands, `senderId` is a CLAIM —
  out-of-band fingerprint verification remains the only sender-authenticity
  anchor (see `SEALED_SENDER_REVIEW.md` and the design notes in the devlog).
- Sealed blobs are still uploaded over the authenticated WS, so the relay can
  correlate the sender at the TCP/session layer. A separate anonymous upload
  channel is the true fix (documented, not built).

These MUST be closed (and an external cryptographer review completed) before
any production use.
