import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/models/ad_proof_of_play_model.dart';

AdProofOfPlayRequest _sample({String status = 'completed'}) {
  return AdProofOfPlayRequest(
    playerCode: 'PLAYER-1',
    adCampaignId: 'camp-1',
    campaignId: 'campaign-1',
    adCampaignItemId: 'item-1',
    contentId: 'content-1',
    slotTimelineId: 'slot-123',
    adZoneId: 'zone-1',
    zoneId: 2,
    zoneName: 'Zone 2',
    creativeName: 'Creative A',
    creativeUrl: 'https://example.invalid/ad.mp4',
    mediaType: 'video/mp4',
    status: status,
    durationSeconds: 15,
    completionPercent: 100,
    playedAt: formatProofOfPlayPlayedAt(DateTime.utc(2026, 5, 22, 20, 27, 5)),
    errorMessage: null,
  );
}

void main() {
  group('AdProofOfPlayRequest — W17 retry-queue persistence', () {
    test('round-trips through toJson/fromJson unchanged', () {
      final original = _sample();
      final restored = AdProofOfPlayRequest.fromJson(original.toJson());
      expect(restored.toJson(), original.toJson());
    });

    test('round-trips an error message correctly, including null', () {
      final withError = AdProofOfPlayRequest(
        playerCode: 'P',
        adCampaignId: 'a',
        campaignId: 'c',
        adCampaignItemId: 'i',
        contentId: 'k',
        slotTimelineId: 's',
        adZoneId: 'z',
        zoneId: 1,
        zoneName: 'Z',
        creativeName: 'N',
        creativeUrl: 'u',
        mediaType: 'video/mp4',
        status: 'failed',
        durationSeconds: 10,
        completionPercent: 0,
        playedAt: formatProofOfPlayPlayedAt(),
        errorMessage: 'creative_load_error',
      );
      final restored = AdProofOfPlayRequest.fromJson(withError.toJson());
      expect(restored.errorMessage, 'creative_load_error');

      final withoutError = _sample();
      final restoredNoError =
          AdProofOfPlayRequest.fromJson(withoutError.toJson());
      expect(restoredNoError.errorMessage, isNull);
    });

    test('dedupKey combines slotTimelineId and status', () {
      final completed = _sample(status: 'completed');
      final failed = _sample(status: 'failed');
      expect(completed.dedupKey, isNot(failed.dedupKey));
      expect(completed.dedupKey, _sample(status: 'completed').dedupKey);
    });
  });
}
