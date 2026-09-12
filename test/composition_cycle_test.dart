import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/models/compaign_model.dart';

// W05: cyclic composition references used to overflow the stack because
// composition expansion (compaign_model.dart's _mergeCompositionInMediaItem
// / _mergeCompositionInZoneList) recursively followed linked zones with no
// visited-ID set and no depth limit. These tests exercise the exact
// reproduced counterexample (a self-referencing composition) plus the
// broader A->B->A case, through the public normalizeCampaignResponse entry
// point -- the same function mqtt_view_model.dart calls on every incoming
// publish_campaign payload.
void main() {
  setUp(() {
    // normalizeCampaignResponse populates this module-level registry as a
    // side effect -- reset it so one test's fixture can't leak into another.
    setGlobalCompositionCampaigns([]);
  });

  CampaignResponse baseResponse(List<Campaign> campaigns) => CampaignResponse(
        action: 'publish_campaign',
        sender: 'test',
        data: CampaignData(
          success: true,
          message: null,
          playerCampaigns: campaigns,
        ),
      );

  test('a composition referencing itself does not overflow the stack', () {
    // Campaign A: one zone, whose one media item is itself a composition
    // that links back to A's own campaign id -- the exact shape of the
    // audit's reproduced counterexample.
    final campaignA = Campaign(
      campaignId: 'composition_A',
      campaignName: 'A',
      zones: [
        CampaignZone(
          id: 1,
          x: 0,
          y: 0,
          width: 100,
          height: 100,
          mediaItems: [
            MediaItem(
              id: 'm1',
              mediaType: 'composition',
              settings: Settings(compositionCampaignId: 'composition_A'),
            ),
          ],
        ),
      ],
    );

    final model = baseResponse([campaignA]);

    expect(
      () => normalizeCampaignResponse(model, {'data': <String, dynamic>{}}),
      returnsNormally,
    );
  });

  test('a mutual A -> B -> A composition cycle does not overflow the stack', () {
    final campaignA = Campaign(
      campaignId: 'composition_A',
      campaignName: 'A',
      zones: [
        CampaignZone(
          id: 1,
          x: 0,
          y: 0,
          width: 100,
          height: 100,
          mediaItems: [
            MediaItem(
              id: 'm-a-links-b',
              mediaType: 'composition',
              settings: Settings(compositionCampaignId: 'composition_B'),
            ),
          ],
        ),
      ],
    );

    final campaignB = Campaign(
      campaignId: 'composition_B',
      campaignName: 'B',
      zones: [
        CampaignZone(
          id: 1,
          x: 0,
          y: 0,
          width: 100,
          height: 100,
          mediaItems: [
            MediaItem(
              id: 'm-b-links-a',
              mediaType: 'composition',
              settings: Settings(compositionCampaignId: 'composition_A'),
            ),
          ],
        ),
      ],
    );

    final model = baseResponse([campaignA, campaignB]);

    expect(
      () => normalizeCampaignResponse(model, {'data': <String, dynamic>{}}),
      returnsNormally,
    );
  });

  test('deep but acyclic nesting still resolves normally', () {
    // A -> B -> C -> D, no cycle -- must not be rejected by the depth cap
    // (kMaxCompositionNestingDepth) at a depth this shallow.
    Campaign compositionLinkingTo(String id, String? nextId) => Campaign(
          campaignId: id,
          campaignName: id,
          zones: [
            CampaignZone(
              id: 1,
              x: 0,
              y: 0,
              width: 100,
              height: 100,
              mediaItems: [
                if (nextId != null)
                  MediaItem(
                    id: '$id-link',
                    mediaType: 'composition',
                    settings: Settings(compositionCampaignId: nextId),
                  )
                else
                  MediaItem(id: '$id-leaf', mediaType: 'image/jpeg', mediaUrl: 'https://example.invalid/leaf.jpg'),
              ],
            ),
          ],
        );

    final campaigns = [
      compositionLinkingTo('composition_A', 'composition_B'),
      compositionLinkingTo('composition_B', 'composition_C'),
      compositionLinkingTo('composition_C', 'composition_D'),
      compositionLinkingTo('composition_D', null),
    ];

    final model = baseResponse(campaigns);
    expect(
      () => normalizeCampaignResponse(model, {'data': <String, dynamic>{}}),
      returnsNormally,
    );
  });
}
