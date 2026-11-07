import 'package:flutter_test/flutter_test.dart';
import 'package:wocom_app/services/dial_plan.dart';

void main() {
  test('every flavour of a Jamaican number becomes 1876XXXXXXX', () {
    for (final raw in ['876 960 1004', '(876) 960-1004', '876-960-1004', '876.960.1004', '+1 876 960 1004', '1 (876) 960 1004', '18769601004', '960 1004', '960-1004']) {
      expect(normalizeDialString(raw), '18769601004', reason: raw);
    }
  });
  test('other North American numbers get a leading 1', () {
    expect(normalizeDialString('305 878 8092'), '13058788092');
    expect(normalizeDialString('+1 (305) 878-8092'), '13058788092');
  });
  test('international numbers get 011', () {
    expect(normalizeDialString('+44 20 7946 0958'), '011442079460958');
    expect(normalizeDialString('011 44 20 7946 0958'), '011442079460958');
  });
  test('extensions and feature codes are untouched', () {
    expect(normalizeDialString('2000'), '2000');
    expect(normalizeDialString('8000'), '8000');
    expect(normalizeDialString('*97'), '*97');
    expect(normalizeDialString('*8'), '*8');
    expect(normalizeDialString('1900'), '1900');
  });
}
