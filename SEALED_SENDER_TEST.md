# Sealed Sender — Manual Two-Device Verification

End-to-end checklist for the Sealed Sender wiring: real metadata-hiding
delivery between two clients, where the relay learns only
`(recipient_id, opaque_blob, timestamp)` — never the sender. Unit coverage
lives in `test/sealed_sender_test.dart` + `test/identity_pin_test.dart`
(client) and `spectre-relay/server/*_test.go` (relay); this document covers
what only a running stack can confirm.

> Sealed Sender is the ONLY wire path — the old DEV cleartext shim has been
> removed. If the relay CA can't be pinned (relay unreachable on first run),
> the app shows "sealed sender: UNAVAILABLE" and messaging is disabled (sends
> queue, inbound drops) — there is no cleartext fallback.

## Prerequisites
- Go toolchain (relay) + Flutter for the target device(s).
- Two devices on the same LAN as the relay (or both on the relay host).
- Do a full `flutter run` (not hot reload) — the relay URL is a compile-time
  `--dart-define`.

## 1. Start the relay (dev mode)
From the relay repo: `./run-dev.sh` (it prints the LAN URL + launch commands),
or manually:
```bash
SPECTRE_DEV=true SPECTRE_LISTEN_ADDR=":8080" \
SPECTRE_QUEUE_PATH="./data/offline_queue.enc" \
SPECTRE_PREKEY_PATH="./data/prekeys.enc" \
SPECTRE_SEALED_CA_PATH="./data/sealed_ca.key" \
go run .
```

## 2. Launch two clients
Use `./run-linux.sh` / `RELAY_HOST=<lan-ip> ./run-macos.sh`, or:
```bash
flutter run -d <device> --dart-define=SPECTRE_RELAY_URL=ws://<relay-host>:8080/ws
```
- [ ] Each client logs `sealed sender: ACTIVE` at startup (not `UNAVAILABLE`).
- [ ] Both onboard + connect; relay logs `prekey bundle registered` (Debug).
- [ ] Each pins the CA (`GET /sealed-ca`) and gets a cert warmed on connect
      (`request_sender_cert` → `sender_cert`), so the first send is prompt.

## 3. Exchange IDs + first contact  A → B
- [ ] On each device: **⚙ → identity → [ copy ]**; paste the other's ID into
      **＋ new conversation**.
- [ ] A sends; B renders the plaintext.
- [ ] In B's relay `WS READ`, the delivery frame carries **only** `recipient_id`
      + opaque `ciphertext` — **no `sender_id`, no `from`**. (The metadata win.)
- [ ] B's `[MessageService]` log shows no `dropped sealed envelope` /
      `identity binding` line — `open()` succeeded and the C2 binding passed.
- [ ] B's send goes straight to **sent** (not stuck "queued").

## 4. Reply  B → A  (established-session / whisper path)
- [ ] A renders it. (C2 is a no-op for non-first-contact — no drop.)

## 5. Out-of-band verification (the real trust anchor)
- [ ] Each chat shows a **"unverified — tap to compare safety number"** bar.
- [ ] Tap it → the peer screen shows two columns: **YOUR WORDS** + **THEIR WORDS**.
- [ ] Cross-check: A's **THEIR WORDS** == B's **YOUR WORDS**, and A's **YOUR
      WORDS** == B's **THEIR WORDS**. (Different columns swap between devices.)
- [ ] Scroll to the bottom (verify is scroll-gated) → **MARK VERIFIED** on both.
- [ ] The chat bar turns green **"identity verified"**; the peer screen's red
      `UNVERIFIED` banner clears.

## 6. Readable history survives a restart
- [ ] Fully quit and re-`flutter run` a client (don't hot reload).
- [ ] Previously-sent/received messages still render as plaintext (persisted
      encrypted-at-rest), NOT `[ ciphertext — restart cleared cache ]`.
      (Messages from *before* this build show the placeholder — expected.)

## 7. Replay is dropped (H2)
- [ ] With the relay redelivering a queued message (e.g. reconnect after an
      offline send), the receiver does NOT show it twice — `[MessageService]`
      logs `duplicate/replayed inbound … ignored` (persistent dedup, survives
      restart).

## 8. Negative — CA pin mismatch (fail closed)
- Delete `sealed_ca.key`, restart the relay (new CA key), then point an
  **already-pinned** client at it.
- [ ] The pinned client fails closed (`SealedCaException`): sealed sender goes
      UNAVAILABLE, no key silently trusted.
- [ ] A *fresh install* TOFU-pins the new key instead (expected first-use
      anchor, not a downgrade).

## 9. Negative — tampered envelope
- Mostly covered by `test/sealed_sender_test.dart` (tampered blob, wrong
  recipient, expired cert, wrong CA, wrong-length ik, malformed blob).
- With a tampering proxy: flip a blob byte →
  [ ] B logs `dropped sealed envelope :: <type>`, nothing renders.

## 10. Panic wipe
- [ ] **⚙ → [ PANIC WIPE ]**: identity, sessions, prekeys, relay-auth, DB
      (incl. stored plaintext + pinned keys), and CA pin are destroyed; the app
      returns to onboarding. The peer's old user ID is now dead.

## Status of the known issues this exercises
- **C2** (cert.ik == PreKey identity): enforced, pre-decrypt.
- **H2** (replay): addressed via persistent dedup. Minor residual — expiry uses
  the device clock (no trusted offline time).
- **H1** (cert-to-envelope binding): covered — the cert rides inside the AEAD
  and C2 blocks re-stapling.
- **NEW-HIGH-1** (verification): real now — key pinned to identity-key bytes,
  change surfaced (banner), out-of-band verify reachable.
- Still open: an **external cryptographer review** (the gate), the **H3/H4**
  construction-hardening calls (reviewer's decision), and a separate
  **anonymous upload channel** (sealed blobs still go over the authenticated WS,
  so the relay can correlate the sender at the TCP layer). See
  `SEALED_SENDER_REVIEW.md`.

These (esp. the external review) MUST be resolved before any production use.
