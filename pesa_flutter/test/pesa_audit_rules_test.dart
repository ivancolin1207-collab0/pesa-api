import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pesa_tablet/services/auth_service.dart';
import 'package:pesa_tablet/services/tipo_servicio_rules.dart';
import 'package:pesa_tablet/widgets/captura_firma_tecnico_dialog.dart';

void main() {
  group('RBAC Administrador en App Móvil', () {
    test('Reconoce admin, administrador, superadmin, jefe y gerente', () {
      for (final r in const ['admin', 'Administrador', 'SUPERADMIN', 'jefe', 'Gerente', 'Dirección']) {
        expect(UsuarioActual.esRolAdmin(r), isTrue, reason: 'Rol esperado Admin: $r');
      }
      for (final r in const ['tecnico', 'Técnico de Campo', 'servicio', 'calibrador', 'inspector']) {
        expect(UsuarioActual.esRolAdmin(r), isFalse, reason: 'Rol NO debe ser Admin: $r');
      }
      expect(UsuarioActual.esRolAdmin('tecnico', 'ivancolin1207'), isTrue);
    });
  });

  group('Reglas estrictas DVE + Hologramas + CCA', () {
    test('Ajuste puro oculta CCA, Inicial J/I/A, DVE y Hologramas', () {
      final r = getRules(nombre: 'Ajuste');
      expect(r.tieneCalibracion, isFalse);
      expect(r.tieneInspeccion, isFalse);
      expect(r.pideCca, isFalse);
      expect(r.pideDve, isFalse);
      expect(r.pideHologramaAnterior, isFalse);
      expect(r.pideHologramaActualizado, isFalse);
    });

    test('Inspección / Verificación habilita DVE y Hologramas únicamente', () {
      for (final n in const ['Ajuste + Inspección', 'Inspección', 'Verificación Metrológica']) {
        final r = getRules(nombre: n);
        expect(r.tieneInspeccion, isTrue, reason: n);
        expect(r.pideDve, isTrue, reason: n);
        expect(r.pideHologramaAnterior, isTrue, reason: n);
        expect(r.pideCca, isFalse, reason: n);
      }
    });
  });

  group('Modal Firma Digital del Técnico', () {
    testWidgets('Valida trazo vacío antes de guardar y muestra botones completos', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => CapturFirmaTecnicoDialog.capturarBytes(
                  context,
                  username: 'tester',
                  nombreCompleto: 'Técnico Pruebas',
                  idTecnico: 0,
                  permitirCancelar: true,
                ),
                child: const Text('Abrir Modal'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Modal'));
      await tester.pumpAndSettle();

      expect(find.text('Firma Digital del Técnico'), findsOneWidget);
      expect(find.text('Guardar Firma'), findsOneWidget);
      expect(find.text('Limpiar'), findsOneWidget);
      expect(find.text('Cancelar'), findsOneWidget);

      await tester.tap(find.text('Guardar Firma'));
      await tester.pump();
      expect(
        find.text('Traza tu firma completa sobre la línea guía antes de guardar.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('Firma Digital del Técnico'), findsNothing);
    });
  });
}
