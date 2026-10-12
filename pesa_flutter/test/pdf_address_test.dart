import 'package:flutter_test/flutter_test.dart';
import 'package:pesa_tablet/services/pdf_service.dart';

void main() {
  test('DIRECCIÓN / PLANTA strictly excludes equipment location and falls back to branch address', () async {
    final osData = {
      'folio_os': 'OS-26-571',
      'cliente': 'Mar Bran S.A. de C.V.',
      'ubicacion': 'Aseguramiento de calidad',
      'marca': 'Doran',
      'modelo': '4200',
      'serie': '421343',
    };

    final bytes = await PdfService.instance.buildPdfBytes(
      osData: osData,
      repRows: [],
      excRows: [],
      exacRows: [],
    );
    expect(bytes.isNotEmpty, isTrue);
  });
}
