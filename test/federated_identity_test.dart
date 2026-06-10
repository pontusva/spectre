import 'package:flutter_test/flutter_test.dart';
import 'package:spectre/services/message_service.dart';

/// Unit tests for the finding-3 fix: the domain half of a federated sender
/// identity comes from the SIGNED cert issuer, never from the unsigned
/// federation_sender_relay transport header. Pure functions, no DB — same
/// pattern as identity_pin_test.dart.
void main() {
  group('canonicalRelayDomain', () {
    test('lowercases and accepts host:port', () {
      expect(
        MessageService.canonicalRelayDomain('Relay-B.Example.org:8443'),
        'relay-b.example.org:8443',
      );
    });

    test('case/format variants collapse into ONE pin namespace', () {
      // Without canonicalization 'A.COM' and 'a.com' produce different TOFU
      // pin keys, letting a relay dodge a pinned-mismatch alarm by varying
      // case in iss.
      expect(
        MessageService.canonicalRelayDomain('A.COM'),
        MessageService.canonicalRelayDomain('a.com'),
      );
    });

    test('accepts dev-style hosts (docker service names, localhost, ports)', () {
      expect(MessageService.canonicalRelayDomain('relay-a:8080'), 'relay-a:8080');
      expect(MessageService.canonicalRelayDomain('localhost:8081'), 'localhost:8081');
    });

    test('rejects garbage that would fork pins or drive a hostile fetch', () {
      const bad = <String>[
        '',
        ' ',
        'a..b',
        '-a.com',
        'a.com-',
        'a-.com',
        'a.com:0',
        'a.com:70000',
        'a.com:port',
        'a.com/path',
        'a.com#frag',
        'a.com?q=1',
        'user@a.com',
        'a com',
        'a.com:443:443',
        'http://a.com',
      ];
      for (final b in bad) {
        expect(
          MessageService.canonicalRelayDomain(b),
          isNull,
          reason: 'should reject "$b"',
        );
      }
    });
  });

  group('deriveFullSenderId', () {
    test('no header -> bare local handle', () {
      expect(
        MessageService.deriveFullSenderId(
          senderUid: 'alice',
          canonicalIss: 'relay-a:8080',
          federationSenderRelay: null,
        ),
        'alice',
      );
      expect(
        MessageService.deriveFullSenderId(
          senderUid: 'alice',
          canonicalIss: 'relay-a:8080',
          federationSenderRelay: '',
        ),
        'alice',
      );
    });

    test('header agreeing with signed iss -> domain taken from the iss', () {
      // Header may differ in case; identity is built from the canonical
      // SIGNED value either way.
      expect(
        MessageService.deriveFullSenderId(
          senderUid: 'alice',
          canonicalIss: 'relay-a:8080',
          federationSenderRelay: 'RELAY-A:8080',
        ),
        'alice@relay-a:8080',
      );
    });

    test('header disagreeing with signed iss -> drop (the finding-3 forgery)', () {
      // A cert legitimately signed by relay A, delivered with a spoofed
      // X-Spectre-Relay-ID of relay B, used to be filed (and safety-number
      // verified) as alice@B. It must now be dropped.
      expect(
        MessageService.deriveFullSenderId(
          senderUid: 'alice',
          canonicalIss: 'relay-a:8080',
          federationSenderRelay: 'relay-b:8080',
        ),
        isNull,
      );
    });

    test('malformed header -> drop', () {
      expect(
        MessageService.deriveFullSenderId(
          senderUid: 'alice',
          canonicalIss: 'relay-a:8080',
          federationSenderRelay: 'relay-a:8080/evil',
        ),
        isNull,
      );
    });
  });
}
