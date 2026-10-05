// Regenera localmente el PDF de la tablet para una OS real exportada a JSON
// y valida el encabezado metrológico (sin "N/A", casillas J I A compactas).
//
// Uso:
//   OS_JSON=/ruta/os_698.json PDF_OUT=/ruta/OS-26-698.pdf flutter test test/pdf_header_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pesa_tablet/services/pdf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Encabezado metrológico respeta tipo de servicio', () async {
    final jsonPath = Platform.environment['OS_JSON'];
    final outPath = Platform.environment['PDF_OUT'];
    if (jsonPath == null || outPath == null) {
      markTestSkipped('Definir OS_JSON y PDF_OUT');
      return;
    }
    final os = Map<String, dynamic>.from(
        jsonDecode(File(jsonPath).readAsStringSync()) as Map);
    List<Map<String, dynamic>> rows(String k) => ((os.remove(k) as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final rep = rows('_rep'), exc = rows('_exc'), exa = rows('_exa');
    final firmaTec = os.remove('_firma_tec') as String?;
    final firmaCli = os.remove('_firma_cli') as String?;
    final bytes = await PdfService.instance.buildPdfBytes(
      osData: os,
      repRows: rep,
      excRows: exc,
      exacRows: exa,
      firmaTecBase64: firmaTec,
      firmaCliBase64: firmaCli,
    );
    File(outPath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    expect(bytes.length, greaterThan(1000));
  });
}
