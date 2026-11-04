import 'package:flutter_test/flutter_test.dart';
import '../lib/services/linux_remote_view.dart';

void main() {
  test('adapter replies complete only the request with the same id and type', () async {
    final sent = <Map<String, dynamic>>[];
    final remote = LinuxRemoteView(writeOverride: sent.add);
    final sign = remote.signOta('{"phase":"updated"}');
    final verify = remote.verifyOta({'data': '{}', 'signature': 'x'});
    final signId = sent[0]['id'] as int, verifyId = sent[1]['id'] as int;
    expect(signId == verifyId, false);

    remote.handleOtaReply({'id': 999, 'ota_signed': {'data': 'other'}}); // unknown request
    remote.handleOtaReply({'id': signId, 'ota_verified': {'job': 'j'}}); // wrong type for a signature
    remote.handleOtaReply({'id': verifyId, 'ota_rejected': 'stale'});
    remote.handleOtaReply({'id': signId, 'ota_signed': {'data': 'mine', 'key': 'k', 'signature': 's'}});

    final signed = await sign, verified = await verify;
    expect(signed.value?['data'], 'mine');
    expect(verified.value, null);
    expect(verified.reason, 'stale');
  });
}
