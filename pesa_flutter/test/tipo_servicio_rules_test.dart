import 'package:flutter_test/flutter_test.dart';
import 'package:pesa_tablet/services/tipo_servicio_rules.dart';

void main() {
  group('Regla estricta de tipos de servicio', () {
    test('Ajuste / Mantenimiento no exigen CCA ni DVE', () {
      for (final n in ['Ajuste', 'Mantenimiento / Ajuste', 'Mantenimiento']) {
        final r = getRules(nombre: n);
        expect(r.pideCca, isFalse, reason: n);
        expect(r.pideDve, isFalse, reason: n);
        expect(r.esSoloAjuste, isTrue, reason: n);
      }
      // ID 2 = Ajuste en cat_tipo_servicio
      expect(getRules(id: 2).pideDve, isFalse);
      expect(getRules(id: 2).pideCca, isFalse);
    });

    test('Calibración habilita solo CCA', () {
      final r = getRules(nombre: 'Calibración + Ajuste');
      expect(r.pideCca, isTrue);
      expect(r.pideDve, isFalse);
      expect(getRules(nombre: 'CCA').pideCca, isTrue);
    });

    test('Inspección / Verificación / DVE habilitan solo DVE', () {
      for (final n in ['Ajuste + Inspección', 'Verificación', 'DVE']) {
        final r = getRules(nombre: n);
        expect(r.pideDve, isTrue, reason: n);
        expect(r.pideCca, isFalse, reason: n);
      }
    });

    test('Calibración + Ajuste + Inspección habilita ambos', () {
      final r = getRules(nombre: 'Calibración + Ajuste + Inspección');
      expect(r.pideCca, isTrue);
      expect(r.pideDve, isTrue);
    });

    test('Tipo desconocido / vacío no exige nada', () {
      expect(getRules(nombre: '').pideCca, isFalse);
      expect(getRules(nombre: '').pideDve, isFalse);
    });

    test('RMA / RE ignoran id_tipo_servicio inconsistente (id 4)', () {
      final rma = getRules(id: 4, nombre: 'Calibración + Ajuste', folio: 'RMA-26-633');
      expect(rma.esRemision, isTrue);
      expect(rma.pideCca, isFalse);
      expect(rma.pideDve, isFalse);
      final re = getRules(id: 4, nombre: 'Calibración + Ajuste', folio: 'RE-26-607');
      expect(re.esRevisionCeldas, isTrue);
      expect(re.pideCca, isFalse);
      expect(re.pideDve, isFalse);
    });
  });
}
