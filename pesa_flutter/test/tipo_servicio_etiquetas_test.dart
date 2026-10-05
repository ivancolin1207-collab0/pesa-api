import 'package:flutter_test/flutter_test.dart';
import 'package:pesa_tablet/services/tipo_servicio_rules.dart';

void main() {
  group('Etiqueta homologada de tipo de servicio (badge Dashboard)', () {
    test('por nombre (BD)', () {
      expect(getRules(nombre: 'Calibración + Ajuste + Inspección').etiquetaCorta,
          'Calibración + Ajuste + Inspección');
      expect(getRules(nombre: 'Ajuste + Inspección').etiquetaCorta, 'Ajuste + Inspección');
      expect(getRules(nombre: 'Calibración + Ajuste').etiquetaCorta, 'Calibración + Ajuste');
      expect(getRules(nombre: 'Ajuste').etiquetaCorta, 'Ajuste');
      expect(getRules(nombre: 'CCA + DVE + Ajuste').etiquetaCorta,
          'Calibración + Ajuste + Inspección');
    });

    test('por ID cuando el nombre viene vacío', () {
      expect(getRules(id: 6, nombre: '').etiquetaCorta, 'Ajuste + Inspección');
      expect(getRules(id: 7).etiquetaCorta, 'Calibración + Ajuste + Inspección');
      expect(getRules(id: 4).etiquetaCorta, 'Calibración + Ajuste');
      expect(getRules(id: 2).etiquetaCorta, 'Ajuste');
    });

    test('sin nombre ni ID → Sin tipo', () {
      expect(getRules(nombre: '').etiquetaCorta, 'Sin tipo');
    });

    test('banner descriptivo', () {
      expect(getRules(nombre: 'Calibración + Ajuste + Inspección').etiquetaLarga,
          'Calibración + Ajuste + Inspección (CCA + DVE)');
      expect(getRules(id: 4).etiquetaLarga, 'Calibración + Ajuste (CCA)');
    });
  });
}
