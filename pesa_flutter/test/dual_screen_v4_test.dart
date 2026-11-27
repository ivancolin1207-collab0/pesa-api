// test/dual_screen_v4_test.dart
// Pruebas automatizadas v4.0:
//   1. Normalización de división mínima y regla estricta DVE+Hologramas (solo Inspección).
//   2. Maquetación Dual-Screen Samsung Galaxy Z Fold8 Ultra:
//      - Pantalla externa plegada (Cover): Size(380, 840)
//      - Pantalla interna desplegada (Unfolded): Size(840, 920)
//      Verificando 0 RenderFlex overflow y 0 excepciones en pantallas y widgets clave.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pesa_tablet/screens/login_screen.dart';
import 'package:pesa_tablet/screens/mi_firma_screen.dart';
import 'package:pesa_tablet/screens/nuevo_doc_screen.dart';
import 'package:pesa_tablet/screens/pdf_preview_aprobacion_screen.dart';
import 'package:pesa_tablet/services/api_service.dart';
import 'package:pesa_tablet/services/auth_service.dart';
import 'package:pesa_tablet/services/metrology_helper.dart';
import 'package:pesa_tablet/services/sync_service.dart';
import 'package:pesa_tablet/services/tipo_servicio_rules.dart';
import 'package:pesa_tablet/theme/pesa_theme.dart';
import 'package:pesa_tablet/widgets/cliente_correo_poka_yoke.dart';
import 'package:pesa_tablet/widgets/pesa_components.dart';

void main() {
  group('v4.0 Reglas Metrológicas y Poka-Yoke', () {
    test('formatearDivisionMinima elimina ceros sobrantes preservando unidad', () {
      expect(formatearDivisionMinima('0.020 kg'), '0.02 kg');
      expect(formatearDivisionMinima('0.500 g'), '0.5 g');
      expect(formatearDivisionMinima('10.000 kg'), '10 kg');
    });

    test('Regla estricta: DVE y Hologramas solo con Inspección / Verificación', () {
      final ajuste = getRules(nombre: 'Ajuste');
      expect(ajuste.pideCca, isFalse);
      expect(ajuste.pideDve, isFalse);
      expect(ajuste.pideHologramaAnterior, isFalse);
      expect(ajuste.pideHologramaActualizado, isFalse);

      final calibAjuste = getRules(nombre: 'Calibración + Ajuste');
      expect(calibAjuste.pideCca, isTrue);
      expect(calibAjuste.pideDve, isFalse);
      expect(calibAjuste.pideHologramaAnterior, isFalse);

      final calibInsp = getRules(nombre: 'Calibración + Inspección');
      expect(calibInsp.pideCca, isTrue);
      expect(calibInsp.pideDve, isTrue);
      expect(calibInsp.pideHologramaAnterior, isTrue);
      expect(calibInsp.pideHologramaActualizado, isTrue);
    });

    test('Validación Poka-Yoke rechaza remitente institucional y genéricos', () {
      expect(esCorreoClienteValido('calidad@cliente-industrial.com'), isTrue);
      expect(esCorreoClienteValido('ivancolin1207@gmail.com'), isFalse);
      expect(esCorreoClienteValido('Cliente'), isFalse);
      expect(esCorreoClienteValido('Sin registrar'), isFalse);
      expect(esCorreoClienteValido(''), isFalse);
    });
  });

  group('v4.0 Dual-Screen Samsung Galaxy Z Fold8 Ultra (Cover 380x840 & Unfolded 840x920)', () {
    Future<void> verifyNoOverflowAtSize(
      WidgetTester tester,
      Size logicalSize,
      Widget child,
    ) async {
      final errors = <FlutterErrorDetails>[];
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details);
      };
      try {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = logicalSize;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AuthService()),
              ChangeNotifierProvider(create: (_) => SyncService()),
            ],
            child: MaterialApp(
              theme: PesaTheme.lightTheme,
              home: child,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));

        final overflows = errors.where(
          (e) => e.exceptionAsString().contains('RenderFlex overflowed'),
        );
        expect(
          overflows,
          isEmpty,
          reason: 'RenderFlex overflow detectado en ${logicalSize.width}x${logicalSize.height}: $overflows',
        );
      } finally {
        FlutterError.onError = prevOnError;
      }
    }

    for (final entry in <String, Size>{
      'Cover 380x840': const Size(380, 840),
      'Unfolded 840x920': const Size(840, 920),
    }.entries) {
      testWidgets('LoginScreen sin overflow en ${entry.key}', (tester) async {
        await verifyNoOverflowAtSize(tester, entry.value, const LoginScreen());
        expect(find.byType(LoginScreen), findsOneWidget);
      });

      testWidgets('ClienteCorreoPokaYokeCard + PesaComponents sin overflow en ${entry.key}', (tester) async {
        final ctrl = ClienteCorreoController();
        addTearDown(ctrl.dispose);
        await verifyNoOverflowAtSize(
          tester,
          entry.value,
          Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const PesaCard(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        PesaStatusBadge(label: 'Cerrado', dotColor: PesaColors.dotGreen),
                        PesaStatusBadge(label: 'En Proceso', dotColor: PesaColors.dotAmber),
                        PesaStatusBadge(label: 'Cancelada', dotColor: PesaColors.dotRed),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ClienteCorreoPokaYokeCard(controller: ctrl, loteId: 'LOTE-TEST-01'),
                  const SizedBox(height: 12),
                  PesaPrimaryButton(label: 'Finalizar Servicio', onPressed: () {}),
                ],
              ),
            ),
          ),
        );
        expect(find.byType(ClienteCorreoPokaYokeCard), findsOneWidget);
        expect(find.text('Finalizar Servicio'), findsOneWidget);
      });

      testWidgets('MiFirmaScreen sin overflow en ${entry.key}', (tester) async {
        await verifyNoOverflowAtSize(tester, entry.value, const MiFirmaScreen());
        expect(find.byType(MiFirmaScreen), findsOneWidget);
      });

      testWidgets('NuevoDocScreen 4 pasos y Enlaces Sustitución sin overflow en ${entry.key}', (tester) async {
        ApiService.instance.injectToken('eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYWRtaW4ifQ.sig');
        await verifyNoOverflowAtSize(tester, entry.value, const NuevoDocScreen());
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Modalidad de Trabajo'), findsOneWidget);
        expect(find.text('Tipo de Documento'), findsOneWidget);
        expect(find.text('Parámetros del Formato y Equipos'), findsOneWidget);
        expect(find.text('Confirmar Folios y Ejecutar'), findsOneWidget);
        expect(find.textContaining('OS-26-XXX'), findsNothing);

        // Desactivar Excentricidad -> debe aparecer Motivo No Aplica y bloque Enlaces de Sustitución
        final excFinder = find.byKey(const ValueKey('aplica_exc_0'));
        await tester.ensureVisible(excFinder);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(excFinder);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('NO').last);
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.byKey(const ValueKey('enlaces_sustitucion_card_0')), findsOneWidget);
        expect(find.textContaining('NOM-010-SCFI / OIML R 76'), findsOneWidget);
        expect(find.text('3 enlaces'), findsOneWidget);
      });

      testWidgets('PdfPreviewAprobacionScreen sin overflow y botones operativos en ${entry.key}', (tester) async {
        await verifyNoOverflowAtSize(
          tester,
          entry.value,
          PdfPreviewAprobacionScreen(
            folio: 'OS-26-864',
            pdfBytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2D]),
            tipoDocumento: 'Orden de Servicio (OS)',
            customPreviewBody: const Center(child: Text('Documento PDF de prueba')),
          ),
        );
        expect(find.text('Vista Previa para Revisión del Cliente — OS-26-864'), findsOneWidget);
        expect(find.text('Sin firma del cliente'), findsOneWidget);
        expect(find.text('Volver a Corregir'), findsOneWidget);
        expect(find.text('Estoy de Acuerdo — Pasar a Firmar'), findsOneWidget);
      });
    }
  });
}
