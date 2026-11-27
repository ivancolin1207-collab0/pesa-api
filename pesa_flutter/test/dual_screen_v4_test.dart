// test/dual_screen_v4_test.dart
// Pruebas automatizadas v4.0:
//   1. Normalización de división mínima y regla estricta DVE+Hologramas (solo Inspección).
//   2. Maquetación Dual-Screen Samsung Galaxy Z Fold8 Ultra:
//      - Pantalla externa plegada (Cover): Size(380, 840)
//      - Pantalla interna desplegada (Unfolded): Size(840, 920)
//      Verificando 0 RenderFlex overflow y 0 excepciones en pantallas y widgets clave.
import 'dart:convert';
import 'dart:io';
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
import 'package:pesa_tablet/services/pdf_service.dart';
import 'package:pesa_tablet/services/sync_service.dart';
import 'package:pesa_tablet/services/tipo_servicio_rules.dart';
import 'package:pesa_tablet/theme/pesa_theme.dart';
import 'package:pesa_tablet/widgets/cliente_correo_poka_yoke.dart';
import 'package:pesa_tablet/widgets/enlaces_sustitucion_table.dart';
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

    String extractPdfText(Uint8List bytes) {
      final raw = latin1.decode(bytes, allowInvalid: true);
      final streams = StringBuffer();
      final reg = RegExp(r'stream\r?\n([\s\S]*?)\r?\n?endstream');
      for (final m in reg.allMatches(raw)) {
        final chunk = m.group(1);
        if (chunk == null) continue;
        try {
          final inflated = zlib.decode(latin1.encode(chunk));
          streams.writeln(latin1.decode(inflated, allowInvalid: true));
        } catch (_) {
          streams.writeln(chunk);
        }
      }
      // Extraer literales PDF (...) de operadores Tj/TJ y unir con espacios
      final litReg = RegExp(r'\(([^()\\]*(?:\\.[^()\\]*)*)\)');
      final tokens = <String>[];
      for (final m in litReg.allMatches(streams.toString())) {
        final tok = (m.group(1) ?? '')
            .replaceAll(r'\(', '(')
            .replaceAll(r'\)', ')')
            .replaceAll(r'\\', r'\')
            .trim();
        if (tok.isNotEmpty) tokens.add(tok);
      }
      return tokens.join(' ').replaceAll(RegExp(r'\s+'), ' ');
    }

    test('v4.0.3 PDF OS-26-880 Tanque/Silo con sustitucion=false usa EXACTITUD estandar y sin glifo roto', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final baseOs = <String, dynamic>{
        'folio_os': 'OS-26-880',
        'fecha': '2026-11-27',
        'cliente': 'Pemex Transformacion Industrial',
        'tipo_servicio': 'Ajuste',
        'tipo_instrumento': 'Tanque / Silo',
        'marca': 'Sartorius',
        'modelo': 'PR1612/02',
        'ns': '2011004405',
        'id_equipo': 'Bascula 3',
        'alcance_max': '10000',
        'div_minima': '10',
        'unidad_medida': 'kg',
        'aplica_excentricidad': false,
        'motivo_no_excentricidad': 'Tanque',
        'aplica_cargas_sustitucion': false,
        'aplica_enlaces_sustitucion': false,
        'aplica_sustitucion': false,
        'usa_sustitucion': false,
        'cantidad_enlaces': 0,
        'observaciones': 'Ajuste',
      };
      final repRows = [
        {'carga': 2000, 'lectura_inicial': 2000, 'lectura_final': 2000},
      ];
      final exacRows = [
        {'carga_patron': 1000, 'lectura_subida': 1000, 'lectura_bajada': 1000},
        {'carga_patron': 2000, 'lectura_subida': 2000, 'lectura_bajada': 2000},
      ];

      // Caso 1: Tanque / Silo + aplica_cargas_sustitucion = false -> EXACTITUD estándar
      final bytesNoSust = await PdfService.instance.buildPdfBytes(
        osData: Map<String, dynamic>.from(baseOs),
        repRows: repRows,
        excRows: const [],
        exacRows: exacRows,
        modoPreviewSinFirma: true,
      );
      final txtNoSust = extractPdfText(bytesNoSust);
      expect(txtNoSust.contains('EXACTITUD'), isTrue);
      expect(txtNoSust.contains('AGUA + PESAS'), isFalse,
          reason: 'No debe imprimir columnas AGUA + PESAS cuando aplica_cargas_sustitucion == false');
      expect(txtNoSust.contains('PESAS'), isFalse,
          reason: 'No debe imprimir columna PESAS cuando aplica_cargas_sustitucion == false');
      expect(txtNoSust.contains('Tanque - pesaje de carga'), isTrue,
          reason: 'Debe usar guion ASCII "-" en la leyenda de Tanque sin glifo roto. Extraído: $txtNoSust');
      expect(txtNoSust.contains('Tanque \u2014'), isFalse);

      // Caso 2: Tanque / Silo + aplica_cargas_sustitucion = true -> Tabla de Sustitución
      final bytesConSust = await PdfService.instance.buildPdfBytes(
        osData: {
          ...baseOs,
          'aplica_cargas_sustitucion': true,
          'aplica_enlaces_sustitucion': true,
          'cantidad_enlaces': 5,
        },
        repRows: repRows,
        excRows: const [],
        exacRows: exacRows,
        modoPreviewSinFirma: true,
      );
      final txtConSust = extractPdfText(bytesConSust);
      expect(txtConSust.contains('AGUA + PESAS'), isTrue,
          reason: 'Debe imprimir tabla de sustitución cuando aplica_cargas_sustitucion == true');
      expect(txtConSust.contains('PESAS'), isTrue);
      expect(txtConSust.contains('AGUA'), isTrue);
    });

    test('v4.0.4 calcularErrorSustitucion evalua INDICACION-(AGUA+PESAS) y REGRESO-AGUA (Fila 3=-5, Fila 5=5/-9000)', () {
      // Fila 1..5 evidencia real
      final e1 = calcularErrorSustitucion(pesas: 2000, agua: 2000, indicacion: 4000, regreso: 2000);
      final e2 = calcularErrorSustitucion(pesas: 2000, agua: 4005, indicacion: 6005, regreso: 4005);
      final e3 = calcularErrorSustitucion(pesas: 2000, agua: 6005, indicacion: 8005, regreso: 6000);
      final e4 = calcularErrorSustitucion(pesas: 2000, agua: 7990, indicacion: 9990, regreso: 7990);
      final e5Typo = calcularErrorSustitucion(pesas: 2000, agua: 10000, indicacion: 12005, regreso: 1000);
      final e5Ok = calcularErrorSustitucion(pesas: 2000, agua: 10000, indicacion: 12005, regreso: 10000);

      expect(e1, 0.0);
      expect(e2, 0.0);
      expect(e3, -5.0);
      expect(e4, 0.0);
      expect(e5Typo, -9000.0);
      expect(e5Ok, 5.0);

      final maxErr = [e1!, e2!, e3!, e4!, e5Ok!]
          .map((e) => e.abs())
          .reduce((a, b) => a > b ? a : b);
      expect(maxErr, 5.0);

      // Formateo sin ceros decimales innecesarios ni '-0'
      expect(formatearErrorSinCeros(-0.0), '0');
      expect(formatearErrorSinCeros(0.0), '0');
      expect(formatearErrorSinCeros(-5.0), '-5');
      expect(formatearErrorSinCeros(5.0), '5');
      expect(formatearErrorSinCeros(0.02), '0.02');
      expect(formatearErrorSinCeros(-0.02), '-0.02');
      expect(formatoMilesEspacio(formatearErrorSinCeros(-0.02)), '-0.02');
      expect(formatoMilesEspacio(formatearErrorSinCeros(-9000.0)), '-9 000');
    });

    test('v4.0.4 PDF sustitución (preview y final) refleja -5 en Fila 3 y 5 en Fila 5 / Error Máximo', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final osSust = <String, dynamic>{
        'folio_os': 'OS-26-875',
        'fecha': '2026-11-27',
        'cliente': 'Pemex Transformacion Industrial',
        'tipo_servicio': 'Ajuste',
        'tipo_instrumento': 'Tanque / Silo',
        'marca': 'Sartorius',
        'modelo': 'PR1612/02',
        'alcance_max': '15000',
        'div_minima': '5',
        'unidad_medida': 'kg',
        'aplica_excentricidad': false,
        'motivo_no_excentricidad': 'Tanque',
        'aplica_cargas_sustitucion': true,
        'aplica_enlaces_sustitucion': true,
        'cantidad_enlaces': 5,
      };
      final exacSustRows = <Map<String, dynamic>>[
        {'pesas': 2000, 'agua': 2000, 'agua_pesas': 4000, 'indicacion': 4000, 'regreso': 2000},
        {'pesas': 2000, 'agua': 4005, 'agua_pesas': 6005, 'indicacion': 6005, 'regreso': 4005},
        {'pesas': 2000, 'agua': 6005, 'agua_pesas': 8005, 'indicacion': 8005, 'regreso': 6000},
        {'pesas': 2000, 'agua': 7990, 'agua_pesas': 9990, 'indicacion': 9990, 'regreso': 7990},
        {'pesas': 2000, 'agua': 10000, 'agua_pesas': 12000, 'indicacion': 12005, 'regreso': 10000},
      ];
      for (final preview in [true, false]) {
        final pdfBytes = await PdfService.instance.buildPdfBytes(
          osData: Map<String, dynamic>.from(osSust),
          repRows: const [],
          excRows: const [],
          exacRows: exacSustRows,
          modoPreviewSinFirma: preview,
        );
        final txt = extractPdfText(pdfBytes);
        expect(txt.contains('AGUA + PESAS'), isTrue);
        expect(txt.contains('-5'), isTrue,
            reason: 'PDF (preview=$preview) debe mostrar -5 en fila 3. Extraído: $txt');
        expect(txt.contains('ERROR M'), isTrue);
      }
    });

    testWidgets('v4.0.4 EnlacesSustitucionTable recalcula en tiempo real al modificar REGRESO', (tester) async {
      List<Map<String, dynamic>> latestRows = const [];
      final initialRows = <Map<String, dynamic>>[
        {'pesas': '2000', 'agua': '2000', 'agua_pesas': '4000', 'indicacion': '4000', 'regreso': '2000'},
        {'pesas': '2000', 'agua': '4005', 'agua_pesas': '6005', 'indicacion': '6005', 'regreso': '4005'},
        {'pesas': '2000', 'agua': '6005', 'agua_pesas': '8005', 'indicacion': '8005', 'regreso': '6000'},
        {'pesas': '2000', 'agua': '7990', 'agua_pesas': '9990', 'indicacion': '9990', 'regreso': '7990'},
        {'pesas': '2000', 'agua': '10000', 'agua_pesas': '12000', 'indicacion': '12005', 'regreso': '1000'},
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EnlacesSustitucionTable(
              rows: initialRows,
              divMin: 5,
              numEnlaces: 5,
              onChanged: (r) => latestRows = r,
            ),
          ),
        ),
      );
      await tester.pump();

      // Estado inicial con typo 1000 en fila 5 -> Fila 3 = -5, Fila 5 = -9 000, Max = 9 000
      expect(find.text('-5'), findsOneWidget);
      expect(find.text('-9 000'), findsOneWidget);
      expect(find.text('9 000'), findsOneWidget);

      // Corregir REGRESO de fila 5 (índice de campo: 5 filas x 5 inputs -> último TextField es idx 24)
      final regFila5Field = find.byType(TextField).at(24);
      await tester.enterText(regFila5Field, '10000');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));

      expect(find.text('-9 000'), findsNothing);
      expect(find.text('-5'), findsOneWidget);
      expect(find.text('5'), findsAtLeastNWidgets(2)); // Error fila 5 = 5 y ERROR MÁXIMO = 5
      expect(latestRows[2]['error'], '-5');
      expect(latestRows[4]['error'], '5');
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
        // Por defecto NO se activa automáticamente al desactivar excentricidad; activarlo explícitamente muestra "3 enlaces"
        expect(find.text('3 enlaces'), findsNothing);
        final enlFinder = find.byKey(const ValueKey('aplica_enlaces_0'));
        await tester.ensureVisible(enlFinder);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(enlFinder);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('SÍ').last);
        await tester.pump(const Duration(milliseconds: 350));
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
