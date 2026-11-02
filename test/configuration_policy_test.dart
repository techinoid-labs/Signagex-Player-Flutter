import 'package:flutter_test/flutter_test.dart';
import 'package:digital_signage/utils/configuration_policy.dart';
void main() {
  test('percentages preserve zero and reject invalid values', () {
    expect(configurationPercent(0),0); expect(configurationPercent('100'),100);
    for (final value in [-1,101,0.5,'NaN','1; reboot',null]) { expect(()=>configurationPercent(value),throwsFormatException); }
  });
  test('empty windows allow all days',()=>expect(inConfigurationWindow([],DateTime(2026,11,2)),isTrue));
  test('uses Sunday-first mask and exclusive end', () {
    final window = [{'days':['1000000'],'from':'10:00','to':'11:00'}];
    expect(inConfigurationWindow(window,DateTime(2026,11,1,10)),isTrue);
    expect(inConfigurationWindow(window,DateTime(2026,11,2,10)),isFalse);
    expect(inConfigurationWindow(window,DateTime(2026,11,1,11)),isFalse);
  });
  test('overnight window belongs to its starting day', () {
    final window = [{'days':'0100000','from':'22:00','to':'06:00'}];
    expect(inConfigurationWindow(window,DateTime(2026,11,2,23)),isTrue);
    expect(inConfigurationWindow(window,DateTime(2026,11,3,5,59)),isTrue);
    expect(inConfigurationWindow(window,DateTime(2026,11,3,6)),isFalse);
    expect(inConfigurationWindow(window,DateTime(2026,11,2,5)),isFalse);
  });
  test('equal endpoints mean a full selected day',()=>expect(inConfigurationWindow([{'days':'0100000','from':'00:00','to':'00:00'}],DateTime(2026,11,2,23)),isTrue));
  test('malformed times and masks fail', () {
    expect(()=>inConfigurationWindow([{'from':'25:00','to':'01:00'}],DateTime.now()),throwsFormatException);
    expect(()=>inConfigurationWindow([{'days':'Monday','from':'00:00','to':'01:00'}],DateTime(2026,11,2,0)),throwsFormatException);
  });
}
