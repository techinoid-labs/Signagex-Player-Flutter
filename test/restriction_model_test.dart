import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/models/compaign_model.dart';

// Two fields the player needs and used to drop on the floor during parsing.
// Both were invisible failures: the payload carried the value, the model
// silently discarded it, and the feature that depended on it just never
// worked.
void main() {
  group('Restriction.fromJson', () {
    test('reads logic_operator, which decides AND vs OR grouping', () {
      final r = Restriction.fromJson({
        'type': 'player_tag',
        'operator': 'is',
        'values': ['lobby'],
        'logic_operator': 'OR',
      });
      expect(r.type, 'player_tag');
      expect(r.operator, 'is');
      expect(r.values, ['lobby']);
      // Dropped before: every set evaluated as a flat AND, so an OR
      // condition withheld content it should have played.
      expect(r.logicOperator, 'OR');
    });

    test('accepts the camelCase spelling too', () {
      final r = Restriction.fromJson({'type': 'date', 'logicOperator': 'AND'});
      expect(r.logicOperator, 'AND');
    });

    test('leaves logicOperator null when absent', () {
      // The evaluator treats null as AND; it must not invent an operator.
      final r = Restriction.fromJson({'type': 'date', 'operator': 'on'});
      expect(r.logicOperator, isNull);
    });

    test('coerces non-string values, which the CMS does send', () {
      // e.g. a location radius arriving as a number.
      final r = Restriction.fromJson({
        'type': 'location',
        'operator': 'is-inside',
        'values': [24.8607, 67.0011, 500],
      });
      expect(r.values, ['24.8607', '67.0011', '500']);
    });
  });

  group('Campaign.fromJson', () {
    test('reads player_tags, which is where a device\'s tags arrive', () {
      // The backend resolves this device's tags and attaches them to the
      // campaign. The player looked for them on the pairing response
      // instead, so a player_tag restriction always evaluated against an
      // empty list and could never match.
      final c = Campaign.fromJson({
        'campaign_id': 'c1',
        'player_tags': ['lobby', 'retail'],
      });
      expect(c.campaignId, 'c1');
      expect(c.playerTags, ['lobby', 'retail']);
    });

    test('leaves playerTags null when the payload omits it', () {
      final c = Campaign.fromJson({'campaign_id': 'c1'});
      expect(c.playerTags, isNull);
    });
  });
}
