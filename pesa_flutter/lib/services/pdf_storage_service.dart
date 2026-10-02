// lib/services/pdf_storage_service.dart
// Servicio para exportar PDF a descargas públicas y rescate manual de PDF.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'api_service.dart';
import 'local_db_service.dart';
import 'sync_service.dart';

class PdfStorageService {
  static final PdfStorageService instance = PdfStorageService._();
  PdfStorageService._();

  /// Obtiene una referencia segura al archivo PDF en el almacenamiento interno de la app
  Future<File> getWritablePdfFile(String folio) async {
    final appDir = await getApplicationDocumentsDirectory();
    final pdfsFolder = Directory('${appDir.path}/PESA_PDFs');
    if (!await pdfsFolder.exists()) {
      await pdfsFolder.create(recursive: true);
    }
    return File('${pdfsFolder.path}/$folio.pdf');
  }

  /// Extrae el ID del indicador/equipo probando todas las posibles claves en cascada
  static String extractInstrumentId(Map<String, dynamic> orden, {String? explicitId}) {
    if (explicitId != null && explicitId.trim().isNotEmpty) {
      return explicitId.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
    }
    final candidate = orden['id_indicador'] ?? 
                      orden['id_equipo'] ?? 
                      orden['id_instrumento'] ?? 
                      orden['instrumento_id'] ?? 
                      orden['no_id'] ??
                      orden['identificador'] ??
                      orden['no_serie'] ??
                      orden['ns'] ??
                      orden['equipo'] ??
                      orden['tipo_bascula'] ??
                      orden['instrumento_nombre'] ??
                      (orden['instrumento'] is Map
                          ? (orden['instrumento']['id_indicador'] ??
                             orden['instrumento']['id_equipo'] ??
                             orden['instrumento']['id_instrumento'] ??
                             orden['instrumento']['id'] ??
                             orden['instrumento']['no_serie'])
                          : null);
    
    if (candidate != null && candidate.toString().trim().isNotEmpty) {
      return candidate.toString().trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
    }
    return 'SIN-ID';
  }

  /// Genera el nombre estandarizado de archivo PDF:
  /// ${FOLIO}-${PRIMER_NOMBRE_CLIENTE}-${ID_INSTRUMENTO}-${SERVICIOS_TAGS}.pdf
  static String buildStandardPdfName({
    required String folio,
    String? cliente,
    String? idIndicador,
    String? tipoServicio,
    Map<String, dynamic>? osData,
  }) {
    final safeFolio = folio.replaceAll('/', '_').replaceAll('\\', '_').trim().toUpperCase();

    String rawCliente = (cliente ?? osData?['cliente'] ?? osData?['razon_social'] ?? osData?['cliente_nombre'] ?? '').toString();
    rawCliente = rawCliente.replaceAll(RegExp(r"[^\w\s\u00C0-\u024F]"), "").trim();
    String primerCliente = "CLIENTE";
    if (rawCliente.isNotEmpty) {
      final parts = rawCliente.split(RegExp(r'\s+'));
      if (parts.isNotEmpty && parts.first.trim().isNotEmpty) {
        primerCliente = parts.first.trim().toUpperCase();
        primerCliente = primerCliente
            .replaceAll(RegExp(r'[ÁÀÄÂ]'), 'A')
            .replaceAll(RegExp(r'[ÉÈËÊ]'), 'E')
            .replaceAll(RegExp(r'[ÍÌÏÎ]'), 'I')
            .replaceAll(RegExp(r'[ÓÒÖÔ]'), 'O')
            .replaceAll(RegExp(r'[ÚÙÜÛ]'), 'U')
            .replaceAll(RegExp(r'[Ñ]'), 'N');
      }
    }

    final rawIdInst = extractInstrumentId(osData ?? {}, explicitId: idIndicador);

    String rawServicio = (tipoServicio ?? osData?['tipo_servicio'] ?? osData?['servicio'] ?? '').toString().toUpperCase();
    bool hasAjuste = rawServicio.contains("AJUSTE") || (osData?['ajuste_requerido'] == true) || (osData?['ajuste'] == true);
    bool hasCCA = rawServicio.contains("CALIBRAC") || rawServicio.contains("CCA") || (osData?['cca_requerido'] == true);
    bool hasDVE = rawServicio.contains("INSPEC") || rawServicio.contains("VERIFIC") || rawServicio.contains("DVE") || (osData?['dve_requerido'] == true);

    String serviciosTags = "";
    if (hasAjuste && hasCCA && hasDVE) {
      serviciosTags = "AJUSTE, CCA Y DVE";
    } else if (hasAjuste && hasCCA) {
      serviciosTags = "AJUSTE Y CCA";
    } else if (hasAjuste && hasDVE) {
      serviciosTags = "AJUSTE Y DVE";
    } else if (hasCCA && hasDVE) {
      serviciosTags = "CCA Y DVE";
    } else if (hasAjuste) {
      serviciosTags = "AJUSTE";
    } else if (hasCCA) {
      serviciosTags = "CCA";
    } else if (hasDVE) {
      serviciosTags = "DVE";
    } else {
      serviciosTags = rawServicio.replaceAll(RegExp(r"[^\w\s\,]"), "").trim();
      if (serviciosTags.isEmpty) serviciosTags = "CCA";
    }

    return "$safeFolio-$primerCliente-$rawIdInst-$serviciosTags.pdf";
  }

  /// Exporta el PDF de una orden a la carpeta pública de Descargas de Android:
  /// /storage/emulated/0/Download/PESA_Respaldos/${nombreGenerado}
  Future<File?> exportToDownloads({
    required String folio,
    String? cliente,
    String? idIndicador,
    String? tipoServicio,
    Map<String, dynamic>? osData,
    String? sourcePdfPath,
    Uint8List? pdfBytes,
    BuildContext? context,
  }) async {
    try {
      final localDb = await LocalDbService.instance.getOsByFolio(folio);
      final mergedData = <String, dynamic>{
        ...?localDb,
        ...?osData,
      };

      final fileName = buildStandardPdfName(
        folio: folio,
        cliente: cliente,
        idIndicador: idIndicador,
        tipoServicio: tipoServicio,
        osData: mergedData,
      );
      final safeFolio = folio.replaceAll('/', '_').replaceAll('\\', '_').trim();

      Directory? targetDir;

      if (Platform.isAndroid) {
        final publicDownload = Directory('/storage/emulated/0/Download/PESA_Respaldos');
        if (!await publicDownload.exists()) {
          try {
            await publicDownload.create(recursive: true);
          } catch (e) {
            debugPrint('[PdfStorage] Cannot create public Download dir directly: $e');
          }
        }
        if (await publicDownload.exists()) {
          targetDir = publicDownload;
        }
      }

      // Fallback a getDownloadsDirectory() o getExternalStorageDirectory()
      if (targetDir == null) {
        try {
          final downDir = await getDownloadsDirectory();
          if (downDir != null) {
            targetDir = Directory('${downDir.path}/PESA_Respaldos');
            if (!await targetDir.exists()) await targetDir.create(recursive: true);
          }
        } catch (_) {}
      }

      // Fallback final a Documents
      if (targetDir == null) {
        final docDir = await getApplicationDocumentsDirectory();
        targetDir = Directory('${docDir.path}/PESA_Respaldos');
        if (!await targetDir.exists()) await targetDir.create(recursive: true);
      }

      File targetFile = File('${targetDir.path}/$fileName');

      try {
        // 1. Si se proveyeron bytes directamente
        if (pdfBytes != null && pdfBytes.isNotEmpty) {
          await targetFile.writeAsBytes(pdfBytes, flush: true);
        }
        // 2. Si se proveyó una ruta local existente
        else if (sourcePdfPath != null && sourcePdfPath.isNotEmpty && File(sourcePdfPath).existsSync() && File(sourcePdfPath).lengthSync() > 500) {
          await File(sourcePdfPath).copy(targetFile.path);
        }
      } catch (e) {
        debugPrint("Advertencia: No se pudo escribir en carpeta pública o falló copia ($e). Usando copia interna.");
        final fallbackFile = await getWritablePdfFile(safeFolio);
        if (pdfBytes != null && pdfBytes.isNotEmpty) {
          await fallbackFile.writeAsBytes(pdfBytes, flush: true);
        } else if (sourcePdfPath != null && sourcePdfPath.isNotEmpty && File(sourcePdfPath).existsSync()) {
          await File(sourcePdfPath).copy(fallbackFile.path);
        }
        targetFile = fallbackFile;
      }
      
      // 3. Buscar en SQLite y disco local
      if (pdfBytes == null && (sourcePdfPath == null || sourcePdfPath.isEmpty || !File(sourcePdfPath).existsSync())) {
        String? foundPath;
        final dbPath = (localDb?['pdf_path_local'] as String? ?? '').trim();

        if (dbPath.isNotEmpty && File(dbPath).existsSync() && File(dbPath).lengthSync() > 500) {
          foundPath = dbPath;
        } else {
          final appDoc = await getApplicationDocumentsDirectory();
          final cand1 = File('${appDoc.path}/Pesa_PDFs/$safeFolio.pdf');
          final cand2 = File('${appDoc.path}/PESA_Tablet/PDF_OS/$safeFolio.pdf');

          if (await cand1.exists() && await cand1.length() > 500) {
            foundPath = cand1.path;
          } else if (await cand2.exists() && await cand2.length() > 500) {
            foundPath = cand2.path;
          } else {
            // Intentar reconstruir desde pdf_b64_local en SQLite
            final b64 = localDb?['pdf_b64_local'] as String?;
            if (b64 != null && b64.trim().isNotEmpty) {
              final pdfDir = Directory('${appDoc.path}/Pesa_PDFs');
              if (!await pdfDir.exists()) await pdfDir.create(recursive: true);
              final restored = File('${pdfDir.path}/$safeFolio.pdf');
              await restored.writeAsBytes(base64Decode(b64.trim()));
              if (await restored.exists() && await restored.length() > 500) {
                foundPath = restored.path;
              }
            }
          }
        }

        if (foundPath != null && File(foundPath).existsSync()) {
          await File(foundPath).copy(targetFile.path);
        } else {
          // 4. Si no se encontró localmente, intentar descargar desde el servidor Render si hay red
          final conn = await Connectivity().checkConnectivity();
          final isOnline = conn.any((r) => r != ConnectivityResult.none);

          if (isOnline) {
            if (context != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Row(
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                      SizedBox(width: 10),
                      Text('Descargando PDF desde el servidor para guardar en Descargas...'),
                    ],
                  ),
                  backgroundColor: Color(0xFF2563EB),
                  duration: Duration(seconds: 3),
                ),
              );
            }
            final downloadedPath = await ApiService.instance.downloadPdf(
              '/api/v1/ordenes/$folio/download-pdf',
              targetFileName: '$safeFolio.pdf',
            );
            if (File(downloadedPath).existsSync()) {
              await File(downloadedPath).copy(targetFile.path);
              await LocalDbService.instance.updatePdfPathLocal(folio, downloadedPath);
            } else {
              throw Exception('No se pudo descargar el PDF desde el servidor.');
            }
          } else {
            throw Exception('El PDF no está disponible localmente y no hay conexión a internet.');
          }
        }
      }

      debugPrint('[PdfStorage] ✅ PDF exportado a: ${targetFile.path}');

      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '✓ Guardado: $fileName',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF16A34A),
            duration: const Duration(seconds: 4),
          ),
        );
      }

      return targetFile;
    } catch (e, st) {
      debugPrint('[PdfStorage] Error exportando PDF: $e\n$st');
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al exportar PDF: ${e.toString().replaceAll("Exception: ", "")}'),
            backgroundColor: const Color(0xFFC8102E),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return null;
    }
  }

  /// Ejecuta el flujo de rescate manual:
  /// 1. Selecciona un PDF con FilePicker.
  /// 2. Vincula el PDF a la orden `folio` y actualiza SQLite local a 'Cerrado' / `pdf_path_local`.
  /// 3. Si hay red, realiza la subida multipart a Render de inmediato.
  Future<bool> subirRespaldoManual({
    required BuildContext context,
    required String folio,
    Map<String, dynamic>? osData,
  }) async {
    try {
      // 1. Selector de archivos
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        dialogTitle: 'Selecciona el PDF respaldado para el Folio $folio',
      );

      if (result == null || result.files.isEmpty || result.files.first.path == null) {
        debugPrint('[PdfStorage] Selección de archivo cancelada por el usuario');
        return false;
      }

      final pickedPath = result.files.first.path!;
      final pickedFile = File(pickedPath);

      if (!await pickedFile.exists() || await pickedFile.length() < 500) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('El archivo seleccionado no es un PDF válido o está vacío.'),
              backgroundColor: Color(0xFFC8102E),
            ),
          );
        }
        return false;
      }

      final safeFolio = folio.replaceAll('/', '_').replaceAll('\\', '_').trim();
      final docDir = await getApplicationDocumentsDirectory();
      final pdfDir = Directory('${docDir.path}/Pesa_PDFs');
      if (!await pdfDir.exists()) await pdfDir.create(recursive: true);

      final localPdfFile = File('${pdfDir.path}/$safeFolio.pdf');
      await pickedFile.copy(localPdfFile.path);

      debugPrint('[PdfStorage] Respaldo manual copiado localmente a ${localPdfFile.path}');

      // 2. Actualizar SQLite local a 'Cerrado' e is_dirty = 1
      final nowIso = DateTime.now().toIso8601String();
      final updateMap = <String, dynamic>{
        'folio_os': folio,
        'estatus': 'Cerrado',
        'estado': 'COMPLETADA_DIGITAL',
        'pdf_path_local': localPdfFile.path,
        'pdf_subido': 0,
        'is_dirty': 1,
        'sync_check_status': 'RECIBIDA_TABLET',
        'sync_status': 'PENDIENTE_ACTUALIZAR',
        'updated_at': nowIso,
      };

      if (osData != null) {
        updateMap.addAll(osData);
        updateMap['estatus'] = 'Cerrado';
        updateMap['estado'] = 'COMPLETADA_DIGITAL';
        updateMap['pdf_path_local'] = localPdfFile.path;
        updateMap['is_dirty'] = 1;
      }

      await LocalDbService.instance.upsertOs(updateMap);
      await LocalDbService.instance.updatePdfPathLocal(folio, localPdfFile.path);

      // Actualizar memoria de SyncService si context tiene el provider
      if (context.mounted) {
        try {
          final sync = context.read<SyncService>();
          sync.updateLocalOrder(folio, {
            'estatus': 'Cerrado',
            'estado': 'COMPLETADA_DIGITAL',
            'pdf_path_local': localPdfFile.path,
            'is_dirty': 1,
            'sync_check_status': 'RECIBIDA_TABLET',
          });
        } catch (_) {}
      }

      // 3. Verificar conectividad para intento de subida inmediato
      final conn = await Connectivity().checkConnectivity();
      final isOnline = conn.any((r) => r != ConnectivityResult.none);

      if (isOnline) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
                  SizedBox(width: 10),
                  Text('Subiendo PDF respaldado al servidor Render...'),
                ],
              ),
              backgroundColor: Color(0xFF2563EB),
              duration: Duration(seconds: 4),
            ),
          );
        }

        final uploadOk = await ApiService.instance.uploadPdf(folio, localPdfFile);

        if (uploadOk) {
          await LocalDbService.instance.updateOsSyncCheckStatus(
            folio,
            'SUBIDA_SERVIDOR',
            isSynced: 1,
            pdfSubido: 1,
          );

          if (context.mounted) {
            try {
              final sync = context.read<SyncService>();
              sync.updateLocalOrder(folio, {
                'sync_check_status': 'SUBIDA_SERVIDOR',
                'pdf_subido': 1,
                'is_dirty': 0,
              });
            } catch (_) {}

            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✓ PDF respaldado subido exitosamente al servidor.'),
                backgroundColor: Color(0xFF16A34A),
                duration: Duration(seconds: 4),
              ),
            );
          }
          return true;
        }
      }

      // Offline o si el upload online falló: Notificar guardado local seguro
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ PDF vinculado localmente (Cerrado). Se subirá al recuperar conexión.'),
            backgroundColor: Color(0xFFD97706),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return true;
    } catch (e, st) {
      debugPrint('[PdfStorage] Error en subirRespaldoManual: $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al procesar respaldo manual: $e'),
            backgroundColor: const Color(0xFFC8102E),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return false;
    }
  }
}
