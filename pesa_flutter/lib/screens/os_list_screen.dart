// lib/screens/os_list_screen.dart — Dashboard corporativo responsive Flutter PESA (Apple HIG Compliant)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
import '../services/pdf_storage_service.dart';
import '../services/sync_service.dart';
import '../widgets/app_shell.dart';
import '../widgets/captura_firma_tecnico_dialog.dart';
import '../widgets/sync_check_badge.dart';

// ── Design Tokens ──────────────────────────────────────────────────────────
const _kCarmineRed = Color(0xFFB81D24);
const _kBgColor    = Color(0xFFF5F5F7);
const _kCardBg     = Color(0xFFFFFFFF);
const _kBorder     = Color(0xFFE5E5EA);
const _kTextPrim   = Color(0xFF1D1D1F);
const _kTextSec    = Color(0xFF86868B);
const _kTableHead  = Color(0xFFF3F4F6);

class OsListScreen extends StatefulWidget {
  const OsListScreen({super.key});
  @override
  State<OsListScreen> createState() => _OsListScreenState();
}

class _OsListScreenState extends State<OsListScreen> {
  List<Map<String, dynamic>> _all      = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  bool _syncDialogOpen = false;

  // ── Filters ───────────────────────────────────────────────────────────────
  String  _periodo   = 'Todo';
  String  _modalidad = 'Todas las Modalidades';
  String? _tecnico;
  String? _estado;
  String  _query     = '';
  final   _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final sync = context.read<SyncService>();
    sync.startNetworkMonitor();
    sync.addListener(_onSyncChanged);

    if (sync.orders.isNotEmpty) {
      _all = List<Map<String, dynamic>>.from(sync.orders);
      _loading = false;
      _applyFilters();
    } else {
      _loadLocal();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _comprobarFirmaYDescargar();
    });
  }

  Future<void> _comprobarFirmaYDescargar() async {
    if (!mounted) return;
    final auth = context.read<AuthService>();
    final isTecnico = auth.isTecnico;

    if (isTecnico && mounted) {
      final username = auth.username ?? '';
      final nombre   = auth.nombreCompleto ?? username;
      final idTec    = auth.idTecnico ?? 0;

      bool tieneFirmaLocal = false;
      try {
        tieneFirmaLocal = await FirmaTecnicoService.instance.tieneFirma(username);
      } catch (e) {
        debugPrint('[Dashboard] Error verificando firma local: $e');
      }

      if (!tieneFirmaLocal && mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => PopScope(
            canPop: false,
            child: CapturFirmaTecnicoDialog(
              username:       username,
              nombreCompleto: nombre,
              idTecnico:      idTec,
            ),
          ),
        );
      }
    }

    if (mounted) await _sincronizarOrdenesServidor();
  }

  // _syncDialogOpen: guard de doble llamada (sin modal visible)
  void _closeSyncDialog() {
    _syncDialogOpen = false;
    // Sin modal que cerrar — sync corre completamente en segundo plano.
  }

  /// Sincronización completamente silenciosa — SIN modal bloqueante.
  /// El usuario puede seguir navegando sin interrupciones.
  /// Al terminar muestra un SnackBar compacto flotante (3-4s).
  Future<void> _sincronizarOrdenesServidor() async {
    if (!mounted) return;
    if (_syncDialogOpen) return; // guard doble-llamada

    _syncDialogOpen = true;

    // Fire-and-forget: no bloquea el hilo principal de la UI
    () async {
      try {
        final syncSvc = context.read<SyncService>();
        if (syncSvc.state == SyncState.syncing) {
          syncSvc.forceResetSync();
          await Future.delayed(const Duration(milliseconds: 100));
        }
        // NO resetear last_sync_time aquí: preservar la diferencial rápida.
        // Solo en primer arranque (last_sync == null) se hace pull completo.

        await context.read<SyncService>().performSync();

        if (!mounted) return;

        // Refrescar dashboard incondicionalmente leyendo directo de SQLite
        await context.read<SyncService>().cargarOrdenes();
        await _loadLocal();

        if (!mounted) return;

        final sync = context.read<SyncService>();

        // ── SnackBar flotante: éxito ─────────────────────────────────────
        if (sync.state == SyncState.success) {
          final totalOS = _all.length;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Row(children: [
              const Icon(Icons.check_circle_outline, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(
                totalOS > 0
                    ? '✓ Sincronizado — $totalOS órdenes'
                    : sync.message.isNotEmpty ? sync.message : '✓ Sincronizado',
                style: const TextStyle(fontSize: 13),
              )),
            ]),
            backgroundColor: const Color(0xFF2E7D32),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            margin: const EdgeInsets.all(12),
          ));
        } else if (sync.state == SyncState.error || sync.state == SyncState.offline) {
          // ── SnackBar flotante: error real con botón Reintentar ─────────────
          final errText = (sync.errorMessage != null && sync.errorMessage!.isNotEmpty)
              ? sync.errorMessage!
              : (sync.message.isNotEmpty ? sync.message : 'Error al sincronizar');
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Row(children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(
                errText,
                style: const TextStyle(fontSize: 12),
              )),
            ]),
            backgroundColor: const Color(0xFFB81D24),
            duration: const Duration(seconds: 8),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            margin: const EdgeInsets.all(12),
            action: SnackBarAction(
              label: 'Reintentar',
              textColor: Colors.white70,
              onPressed: () => _sincronizarOrdenesServidor(),
            ),
          ));
          if (mounted) await _loadLocal();
        }

      } catch (e) {
        debugPrint('[Sync UI] Error silencioso: $e');
        if (mounted) await _loadLocal();
      } finally {
        _syncDialogOpen = false;
      }
    }();
  }


  @override
  void dispose() {
    context.read<SyncService>().removeListener(_onSyncChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSyncChanged() {
    final sync = context.read<SyncService>();
    final auth = context.read<AuthService>();
    final usuario = AuthService.usuarioActual;
    final isTecnico = auth.isTecnico || (usuario != null && usuario.rol.toUpperCase() == 'TECNICO');
    final currentIdTecnico = usuario?.id ?? auth.idTecnico;
    final currentNombre = (usuario?.nombre ?? auth.displayName).toLowerCase().trim();

    if (sync.orders.isNotEmpty && mounted) {
      final ordersToShow = isTecnico
          ? sync.orders.where((o) {
              String _norm(String s) => s
                  .replaceAll('á','a').replaceAll('é','e').replaceAll('í','i')
                  .replaceAll('ó','o').replaceAll('ú','u').replaceAll('ü','u');
              final idTec = int.tryParse(o['id_tecnico']?.toString() ?? '');
              // ID match takes priority (authoritative)
              if (idTec != null && idTec > 0) {
                if (currentIdTecnico != null && currentIdTecnico > 0) {
                  return idTec == currentIdTecnico;
                }
              }
              // Name-based fallback with apellido protection
              final tec = _norm((o['tecnico'] as String? ?? o['tecnico_nombre'] as String? ?? '').toLowerCase().trim());
              final myN = _norm(currentNombre);
              if (tec.isEmpty || myN.isEmpty) return false;
              if (tec == myN) return true;
              final tp = tec.split(RegExp(r'\s+')); final mp = myN.split(RegExp(r'\s+'));
              if (tp.length >= 2 && mp.length >= 2 && tp[0] == mp[0] && tp[1] != mp[1]) return false;
              return tec.contains(myN) || myN.contains(tec);
            }).toList()
          : sync.orders;

      setState(() {
        _all = List<Map<String, dynamic>>.from(ordersToShow);
        _loading = false;
      });
      _applyFilters();
    } else if (sync.state == SyncState.success || sync.state == SyncState.error) {
      _loadLocal();
    }
  }

  Future<void> _loadLocal() async {
    final sync = context.read<SyncService>();
    final auth = context.read<AuthService>();
    final usuario = AuthService.usuarioActual;
    final isTecnico = auth.isTecnico || (usuario != null && usuario.rol.toUpperCase() == 'TECNICO');
    final currentIdTecnico = usuario?.id ?? auth.idTecnico;
    final currentNombre = usuario?.nombre ?? auth.displayName;

    if (isTecnico) {
      await LocalDbService.instance.purgarOrdenesDeOtrosTecnicos(
        currentIdTecnico: currentIdTecnico,
        currentNombre: currentNombre,
        isAdmin: false,
      );
    }

    List<Map<String, dynamic>> filterMem(List<Map<String, dynamic>> src) {
      if (!isTecnico) return src;
      String _norm(String s) => s
          .replaceAll('á','a').replaceAll('é','e').replaceAll('í','i')
          .replaceAll('ó','o').replaceAll('ú','u').replaceAll('ü','u');
      final myN = _norm(currentNombre.toLowerCase().trim());
      return src.where((o) {
        final idTec = int.tryParse(o['id_tecnico']?.toString() ?? '');
        // ID match takes priority
        if (idTec != null && idTec > 0 && currentIdTecnico != null && currentIdTecnico > 0) {
          return idTec == currentIdTecnico;
        }
        // Name fallback with apellido protection
        final tec = _norm((o['tecnico'] as String? ?? o['tecnico_nombre'] as String? ?? '').toLowerCase().trim());
        if (tec.isEmpty || myN.isEmpty) return false;
        if (tec == myN) return true;
        final tp = tec.split(RegExp(r'\s+')); final mp = myN.split(RegExp(r'\s+'));
        if (tp.length >= 2 && mp.length >= 2 && tp[0] == mp[0] && tp[1] != mp[1]) return false;
        return tec.contains(myN) || myN.contains(tec);
      }).toList();
    }

    final memFiltered = filterMem(sync.orders);

    if (memFiltered.isNotEmpty && _all.isEmpty) {
      if (mounted) {
        setState(() {
          _all = List<Map<String, dynamic>>.from(memFiltered);
          _loading = false;
        });
        await _applyFilters();
      }
    } else if (_all.isEmpty) {
      if (mounted) setState(() => _loading = true);
    }

    try {
      var list = isTecnico
          ? await LocalDbService.instance.getOsForTecnico(
              nombreTecnico: currentNombre,
              idTecnico: currentIdTecnico,
            )
          : await LocalDbService.instance.getAllOs();

      if (list.isEmpty && isTecnico) {
        final all = await LocalDbService.instance.getAllOs();
        if (all.isNotEmpty) {
          list = filterMem(all);
        }
      }

      if (mounted) {
        final mutableList = list.map((m) => Map<String, dynamic>.from(m)).toList();
        if (mutableList.isNotEmpty) {
          setState(() { _all = mutableList; _loading = false; });
          await _applyFilters();
        } else if (memFiltered.isNotEmpty) {
          setState(() { _all = memFiltered.map((m) => Map<String, dynamic>.from(m)).toList(); _loading = false; });
          await _applyFilters();
        } else if (_all.isNotEmpty) {
          // Resguardo de base local: no vaciar si ya tenemos datos en memoria
          setState(() { _loading = false; });
          await _applyFilters();
        } else {
          setState(() { _all = []; _loading = false; });
        }
      }
    } catch (e) {
      debugPrint('[Dashboard] Error en _loadLocal: $e');
      if (mounted) {
        if (memFiltered.isNotEmpty) {
          setState(() { _all = memFiltered.map((m) => Map<String, dynamic>.from(m)).toList(); _loading = false; });
          await _applyFilters();
        } else if (_all.isNotEmpty) {
          setState(() { _loading = false; });
          await _applyFilters();
        } else {
          setState(() { _all = []; _loading = false; });
        }
      }
    }
  }

  Future<void> _applyFilters() async {
    final now = DateTime.now();
    final auth = context.read<AuthService>();
    final usuario = AuthService.usuarioActual;
    final isTecnico = auth.isTecnico || (usuario != null && usuario.rol.toUpperCase() == 'TECNICO');
    final currentIdTecnico = usuario?.id ?? auth.idTecnico;
    final currentNombre = usuario?.nombre ?? auth.displayName;

    final params = _FilterParams(
      all: _all,
      periodo: _periodo,
      modalidad: _modalidad,
      tecnico: _tecnico,
      estado: _estado,
      query: _query,
      nowYear: now.year,
      nowMonth: now.month,
      nowDay: now.day,
      isTecnico: isTecnico,
      currentTecnicoNombre: currentNombre,
      currentTecnicoId: currentIdTecnico,
    );

    final List<Map<String, dynamic>> result = _all.length > 20
        ? await compute(_filterIsolate, params)
        : _filterIsolate(params);

    if (mounted) setState(() => _filtered = result);
  }

  // ── Helpers de Estado de Ordenes ──────────────────────────────────────────
  static bool tieneDocumento(Map<String, dynamic> o) {
    final folioStr = (o['folio_os'] as String? ?? o['folio'] as String? ?? '').trim();
    final String? pdfPath = (o['pdf_path'] ?? o['pdf_path_local'])?.toString().trim();
    final String? pdfUrl = o['pdf_url']?.toString().trim();
    final bool hasPdfFlag = (o['has_pdf'] == 1 || o['has_pdf'] == '1' || o['has_pdf'] == true || o['pdf_subido'] == 1);

    final metro = o['metrologia_data'] ?? o['rep_json'] ?? o['exac_json'];
    final bool tieneMetrologia = metro != null &&
        metro.toString().trim().isNotEmpty &&
        metro.toString().trim() != '{}' &&
        metro.toString().trim() != '[]' &&
        metro.toString().trim() != 'null';

    // Verificar si el archivo existe físicamente en el almacenamiento local:
    bool fileExiste = false;
    final String? localPath = o['pdf_path_local']?.toString().trim();
    if (localPath != null && localPath.isNotEmpty) {
      try {
        fileExiste = File(localPath).existsSync();
      } catch (_) {}
    }
    if (!fileExiste && pdfPath != null && pdfPath.isNotEmpty) {
      try {
        fileExiste = File(pdfPath).existsSync();
      } catch (_) {}
    }
    if (!fileExiste && folioStr.isNotEmpty) {
      fileExiste = LocalDbService.instance.checkPdfExistsOnDiskSync(folioStr, localPath ?? pdfPath);
    }

    final bool hasB64 = (o['pdf_b64_local']?.toString().length ?? 0) > 100;

    return hasPdfFlag || (pdfUrl != null && pdfUrl.isNotEmpty) || tieneMetrologia || fileExiste || hasB64;
  }

  /// Alias para retrocompatibilidad
  static bool tienePdfReal(Map<String, dynamic> orden) => tieneDocumento(orden);

  static bool sinIniciar(Map<String, dynamic> orden) => !tieneDocumento(orden);

  // ── KPIs ─────────────────────────────────────────────────────────────────
  int get _kpiTotal => _filtered.length;

  int get _kpiProceso => _filtered.where((o) {
    if (tienePdfReal(o)) return false;
    final e = (o['estado'] as String? ?? '').trim().toUpperCase();
    final est = (o['estatus'] as String? ?? '').trim().toUpperCase();
    final isCancelada = e == 'CANCELADA' || e == 'CANCELADO' || est == 'CANCELADO';
    return !isCancelada;
  }).length;

  int get _kpiCerrado => _filtered.where((o) => tienePdfReal(o)).length;

  int get _kpiFisico => _filtered.where((o) {
    final m = (o['modalidad'] as String? ?? '').trim().toUpperCase();
    return m.contains('FISIC') || m.contains('FÍSIC');
  }).length;

  List<String> get _tecnicos => _all
      .map((o) => o['tecnico'] as String? ?? '').where((t) => t.isNotEmpty)
      .toSet().toList()..sort();
  List<String> get _estados => _all
      .map((o) => o['estado'] as String? ?? '').where((e) => e.isNotEmpty)
      .toSet().toList()..sort();

  List<_OsGroup> _groupByLote(List<Map<String, dynamic>> list) {
    final Map<String, List<Map<String, dynamic>>> buckets = {};
    for (final os in list) {
      final lote = (os['id_lote'] as String?) ?? (os['lote'] as String?) ?? '';
      final key = lote.isNotEmpty ? lote : 'solo_${os['folio_os'] ?? os['local_id']}';
      buckets.putIfAbsent(key, () => []).add(os);
    }
    return buckets.entries.map((e) {
      final isLote = !e.key.startsWith('solo_') && e.value.length > 1;
      return _OsGroup(loteKey: e.key, items: e.value, isLote: isLote);
    }).toList();
  }

  // ── Actions Handlers ──────────────────────────────────────────────────────
  Future<void> _abrirPdf(BuildContext context, Map<String, dynamic> os) async {
    final folio = (os['folio_os'] as String? ?? os['folio'] as String? ?? '').trim();
    final ctx = context;
    if (folio.isEmpty) return;

    String? pathToOpen;

    final memPath = (os['pdf_path_local'] as String? ?? '').trim();
    if (memPath.isNotEmpty && File(memPath).existsSync() && File(memPath).lengthSync() > 500) {
      pathToOpen = memPath;
    }

    if (pathToOpen == null) {
      try {
        final localOs = await LocalDbService.instance.getOsByFolio(folio);
        if (localOs != null) {
          final dbPath = (localOs['pdf_path_local'] as String? ?? '').trim();
          if (dbPath.isNotEmpty && File(dbPath).existsSync() && File(dbPath).lengthSync() > 500) {
            pathToOpen = dbPath;
            try { os['pdf_path_local'] = dbPath; } catch (_) {}
          } else {
            final b64 = localOs['pdf_b64_local'] as String?;
            if (b64 != null && b64.trim().isNotEmpty) {
              final docDir = await getApplicationDocumentsDirectory();
              final pdfDir = Directory('${docDir.path}/pdfs');
              if (!await pdfDir.exists()) await pdfDir.create(recursive: true);
              final restored = File('${pdfDir.path}/OS-$folio.pdf');
              await restored.writeAsBytes(base64Decode(b64.trim()), flush: true, mode: FileMode.write);
              if (restored.existsSync() && restored.lengthSync() > 500) {
                pathToOpen = restored.path;
                try { os['pdf_path_local'] = restored.path; } catch (_) {}
                await LocalDbService.instance.updatePdfPathLocal(folio, restored.path);
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[Dashboard] Error revisando SQLite para PDF de $folio: $e');
      }
    }

    if (pathToOpen == null) {
      final diskPath = await LocalDbService.instance.resolvePdfPathFromDisk(folio);
      if (diskPath != null && File(diskPath).existsSync() && File(diskPath).lengthSync() > 500) {
        pathToOpen = diskPath;
        try { os['pdf_path_local'] = diskPath; } catch (_) {}
      }
    }

    if (pathToOpen != null && File(pathToOpen).existsSync()) {
      try {
        final openRes = await OpenFilex.open(pathToOpen);
        if (openRes.type == ResultType.noAppToOpen || openRes.type == ResultType.error) {
          if (ctx.mounted) {
            ctx.push('/pdf-viewer', extra: {
              'pdfPath': pathToOpen,
              'pdfBytes': File(pathToOpen).readAsBytesSync(),
              'folio': folio,
            });
          }
        }
      } catch (_) {
        if (ctx.mounted) {
          ctx.push('/pdf-viewer', extra: {
            'pdfPath': pathToOpen,
            'pdfBytes': File(pathToOpen).readAsBytesSync(),
            'folio': folio,
          });
        }
      }
      return;
    }

    final connResults = await Connectivity().checkConnectivity();
    final isOnline = connResults.any((r) => r != ConnectivityResult.none);

    if (!isOnline) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text('El archivo no está en este dispositivo y no hay conexión a internet.'),
            backgroundColor: _kCarmineRed,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    try {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
                SizedBox(width: 10),
                Text('Descargando PDF oficial desde el servidor...'),
              ],
            ),
            duration: Duration(seconds: 3),
            backgroundColor: Color(0xFF2563EB),
          ),
        );
      }

      final downloadedPath = await ApiService.instance.downloadPdf(
        '/api/v1/ordenes/$folio/download-pdf',
        targetFileName: '$folio.pdf',
      );

      await LocalDbService.instance.updatePdfPathLocal(folio, downloadedPath);
      try {
        os['pdf_path_local'] = downloadedPath;
      } catch (_) {}

      if (ctx.mounted) {
        final bytes = await File(downloadedPath).readAsBytes();
        ctx.push('/pdf-viewer', extra: {
          'pdfPath': downloadedPath,
          'pdfBytes': bytes,
          'folio': folio,
        });
      }
    } catch (e) {
      if (e.toString().contains('read-only')) {
        final diskPath = await LocalDbService.instance.resolvePdfPathFromDisk(folio);
        if (diskPath != null && File(diskPath).existsSync() && ctx.mounted) {
          final bytes = await File(diskPath).readAsBytes();
          ctx.push('/pdf-viewer', extra: {
            'pdfPath': diskPath,
            'pdfBytes': bytes,
            'folio': folio,
          });
          return;
        }
      }
      if (ctx.mounted) {
        showDialog(
          context: ctx,
          builder: (dialogCtx) => AlertDialog(
            title: const Text('PDF no disponible'),
            content: Text(
              'No se pudo recuperar el PDF de la orden $folio.\n\n$e',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Entendido'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  Navigator.of(dialogCtx).pop();
                  PdfStorageService.instance.subirRespaldoManual(
                    context: ctx,
                    folio: folio,
                    osData: os,
                  );
                },
                icon: const Icon(Icons.file_upload_outlined, size: 16),
                label: const Text('Vincular PDF Manual'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _descargarPdfConNomenclatura(BuildContext context, Map<String, dynamic> os) async {
    final folio = (os['folio_os'] as String? ?? os['folio'] as String? ?? '').trim();
    if (folio.isEmpty) return;
    await PdfStorageService.instance.exportToDownloads(
      folio: folio,
      cliente: (os['cliente'] ?? os['razon_social'] ?? os['cliente_nombre'])?.toString(),
      idIndicador: (os['id_indicador'] ?? os['id_instrumento'] ?? os['no_serie'])?.toString(),
      tipoServicio: (os['tipo_servicio'] ?? os['servicio'])?.toString(),
      osData: os,
      sourcePdfPath: os['pdf_path_local'] as String?,
      context: context,
    );
  }

  void _mostrarDialogoRehacerToma(BuildContext context, Map<String, dynamic> os) {
    final folio = (os['folio_os'] as String? ?? os['folio'] as String? ?? '').trim();
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.edit_note_rounded, color: Color(0xFFF57C00), size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Reabrir toma: $folio',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          '¿Deseas reabrir y modificar la toma de $folio?\n\n'
          'Se abrirá el formulario cargando todas las lecturas de Repetibilidad, Excentricidad, Exactitud, datos de Instrumento y firmas guardados para que puedas ajustarlos.',
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF57C00),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Reabrir y Editar'),
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              final editOs = Map<String, dynamic>.from(os);
              editOs['estado'] = 'Proceso';
              try { os['estado'] = 'Proceso'; } catch (_) {}
              context.push('/captura/${os['local_id']}', extra: editOs);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarDialogoEliminarDatosDesdeCero(BuildContext context, Map<String, dynamic> os) async {
    final folio = ((os['folio_os'] ?? os['folio']) as String? ?? '').trim();
    if (folio.isEmpty) return;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFC62828), size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Reiniciar orden: $folio',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: const Text(
          '¿Deseas reiniciar por completo esta orden? Se borrarán todas las lecturas (Repetibilidad, Excentricidad, Exactitud), dictamen y firmas guardadas para comenzar desde cero.',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFC62828),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            icon: const Icon(Icons.delete_forever_rounded, size: 16),
            label: const Text('🗑️ Eliminar datos desde 0'),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Reiniciando orden $folio...'),
        duration: const Duration(seconds: 2),
      ),
    );

    final syncService = context.read<SyncService>();
    final ok = await syncService.resetearOrdenDesdeCero(folio, os);

    if (context.mounted) {
      if (ok) {
        // Recargar la lista local de órdenes para refrescar la pantalla y contadores
        await _loadLocal();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF2E7D32),
            content: Text('✓ Orden reiniciada correctamente. Lista para nueva captura.'),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFFC62828),
            content: Text('⚠️ No se pudo resetear la orden $folio por completo.'),
          ),
        );
      }
    }
  }

  Future<void> _subirPdfManual(BuildContext context, Map<String, dynamic> os) async {
    final folio = ((os['folio_os'] ?? os['folio']) as String? ?? '').trim();
    if (folio.isEmpty) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result == null || result.files.isEmpty) return;
      final pickedPath = result.files.single.path;
      if (pickedPath == null || pickedPath.isEmpty) return;

      final pickedFile = File(pickedPath);
      if (!await pickedFile.exists()) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('El archivo seleccionado no existe.')),
          );
        }
        return;
      }

      final appDocDir = await getApplicationDocumentsDirectory();
      final pdfsDir = Directory('${appDocDir.path}/Pesa_PDFs');
      if (!await pdfsDir.exists()) {
        await pdfsDir.create(recursive: true);
      }

      final safeFolio = folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final targetFile = File('${pdfsDir.path}/$safeFolio.pdf');
      final targetBytes = await pickedFile.readAsBytes();
      await targetFile.writeAsBytes(targetBytes, flush: true);

      final pdfB64 = base64Encode(targetBytes);

      // Guardar en SQLite local
      await LocalDbService.instance.saveManualPdf(
        folio,
        targetFile.path,
        pdfB64: pdfB64,
      );

      // Actualizar estado en memoria reactivo
      if (context.mounted) {
        context.read<SyncService>().updateLocalOrder(folio, {
          'pdf_path_local': targetFile.path,
          'pdf_b64_local': pdfB64,
          'estado': 'Cerrado',
          'estatus': 'Cerrado',
          'sync_status': 'PENDIENTE',
          'is_dirty': 1,
          'has_pdf': 1,
          'pdf_tipo': 'MANUAL',
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1565C0),
            content: Text('📄 PDF manual asignado a $folio. Subiendo al servidor Render...'),
          ),
        );
      }

      // Subida inmediata hacia Render / PostgreSQL
      try {
        final uploadOk = await ApiService.instance.uploadPdf(
          folio,
          targetFile,
          osId: os['local_id'] as int?,
        ).timeout(const Duration(seconds: 20));

        if (uploadOk) {
          await LocalDbService.instance.markPdfSubido(
            os['local_id'] as int? ?? 0,
            folio: folio,
          );
          await LocalDbService.instance.clearDirty(folio);
          if (context.mounted) {
            context.read<SyncService>().updateLocalOrder(folio, {
              'is_dirty': 0,
              'sync_status': 'SINCRONIZADO',
              'sync_check_status': 'SUBIDA_SERVIDOR',
              'pdf_subido': 1,
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: const Color(0xFF2E7D32),
                content: Text('✅ PDF de $folio sincronizado con éxito en Render.'),
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('[MANUAL PDF] Subida inmediata falló (se enviará en sync PUSH): $e');
      }
    } catch (e) {
      debugPrint('[MANUAL PDF] Error al seleccionar/guardar PDF: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFFC62828),
            content: Text('Error al cargar PDF: $e'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync        = context.watch<SyncService>();
    final auth        = context.watch<AuthService>();
    final hideTecnico = auth.isTecnico;

    final content = Scaffold(
      backgroundColor: _kBgColor,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 650) {
              return _MobilePhoneDashboard(
                state: this,
                sync: sync,
                hideTecnico: hideTecnico,
              );
            } else {
              return _TabletDesktopDashboard(
                state: this,
                sync: sync,
                hideTecnico: hideTecnico,
              );
            }
          },
        ),
      ),
    );
    return AppShell(currentRoute: '/os', child: content);
  }
}

// ── Filter Isolate Model & Logic ───────────────────────────────────────────
class _FilterParams {
  final List<Map<String, dynamic>> all;
  final String periodo;
  final String modalidad;
  final String? tecnico;
  final String? estado;
  final String query;
  final int nowYear, nowMonth, nowDay;
  final bool isTecnico;
  final String currentTecnicoNombre;
  final int? currentTecnicoId;

  const _FilterParams({
    required this.all,
    required this.periodo,
    required this.modalidad,
    required this.tecnico,
    required this.estado,
    required this.query,
    required this.nowYear,
    required this.nowMonth,
    required this.nowDay,
    this.isTecnico = false,
    this.currentTecnicoNombre = '',
    this.currentTecnicoId,
  });
}

DateTime? _parseFecha(String s) {
  if (s.isEmpty) return null;
  final d = DateTime.tryParse(s);
  if (d != null) return d;
  if (s.contains('/')) {
    final parts = s.split('/');
    if (parts.length == 3) {
      if (parts[0].length == 4) {
        return DateTime.tryParse('${parts[0]}-${parts[1].padLeft(2, '0')}-${parts[2].padLeft(2, '0')}');
      } else {
        return DateTime.tryParse('${parts[2]}-${parts[1].padLeft(2, '0')}-${parts[0].padLeft(2, '0')}');
      }
    }
  }
  return null;
}

/// Compara la fecha de una orden contra el periodo seleccionado.
/// Soporta strings con formato YYYY-MM-DD y DD/MM/YYYY sin tronar.
bool coincidePeriodo(String fechaStr, String periodo, [DateTime? ahoraRef]) {
  if (periodo == 'Todo') return true;
  if (fechaStr.trim().isEmpty) return false;
  try {
    DateTime? fechaOrden;
    try {
      fechaOrden = DateTime.parse(fechaStr.trim());
    } catch (_) {
      fechaOrden = _parseFecha(fechaStr);
    }
    if (fechaOrden == null) return true;

    final ahora = ahoraRef ?? DateTime.now();
    final f = DateTime(fechaOrden.year, fechaOrden.month, fechaOrden.day);
    final hoy = DateTime(ahora.year, ahora.month, ahora.day);
    final diffDays = hoy.difference(f).inDays;

    if (periodo == 'Hoy') {
      return diffDays == 0 ||
          (fechaOrden.year == ahora.year && fechaOrden.month == ahora.month && fechaOrden.day == ahora.day);
    } else if (periodo == 'Semana') {
      // Órdenes de los últimos 7 días móviles (ej. del 25 de septiembre al 2 de octubre)
      return (diffDays >= 0 && diffDays <= 7) ||
          (ahora.difference(fechaOrden).inDays <= 7 && ahora.difference(fechaOrden).inDays >= 0);
    } else if (periodo == 'Mes') {
      // Ventana de 30 días para evitar que el cambio de mes vacíe la tabla
      final mismoMes = fechaOrden.year == ahora.year && fechaOrden.month == ahora.month;
      final ventana30 = (diffDays >= 0 && diffDays <= 30) ||
          (ahora.difference(fechaOrden).inDays <= 30 && ahora.difference(fechaOrden).inDays >= 0);
      return mismoMes || ventana30;
    }
  } catch (_) {}
  return true;
}

List<Map<String, dynamic>> _filterIsolate(_FilterParams p) {
  final now = DateTime(p.nowYear, p.nowMonth, p.nowDay);
  final filtered = p.all.where((os) {
    // 1. REGLA ESTRICTA DE AISLAMIENTO POR TÉCNICO:
    // No mostrar bajo ninguna circunstancia órdenes de otros técnicos en la vista del técnico
    if (p.isTecnico) {
      // Helper: normaliza acentos para comparación tolerante de strings
      String _norm(String s) => s
          .replaceAll('á','a').replaceAll('é','e').replaceAll('í','i')
          .replaceAll('ó','o').replaceAll('ú','u').replaceAll('ü','u');

      final idTec = int.tryParse(os['id_tecnico']?.toString() ?? '');
      final myId  = p.currentTecnicoId;
      final myNom = _norm(p.currentTecnicoNombre.toLowerCase().trim());

      // ── Caso A: La orden tiene id_tecnico válido ──────────────────────────
      if (idTec != null && idTec > 0) {
        if (myId != null && myId > 0) {
          // Ambos IDs conocidos: comparación directa, SIN fallback a nombre.
          // Si los IDs difieren → excluir siempre.
          if (idTec != myId) return false;
          // IDs iguales → incluir; ir directo a los demás filtros.
        } else if (myNom.isNotEmpty) {
          // No tenemos ID de usuario en sesión → comparar por nombre completo
          final tecNorm = _norm((os['tecnico'] as String? ?? os['tecnico_nombre'] as String? ?? '').toLowerCase().trim());
          if (tecNorm.isEmpty) return true;
          final tecParts = tecNorm.split(RegExp(r'\s+'));
          final myParts  = myNom.split(RegExp(r'\s+'));
          // Mismo primer nombre pero apellido diferente → personas distintas
          if (tecParts.length >= 2 && myParts.length >= 2 &&
              tecParts[0] == myParts[0] && tecParts[1] != myParts[1]) return false;
          if (tecNorm != myNom && !tecNorm.contains(myNom) && !myNom.contains(tecNorm)) return false;
        }
      } else {
        // ── Caso B: Orden sin id_tecnico (formatos físicos o legacy) ─────────
        if (myNom.isNotEmpty) {
          final tecNorm = _norm((os['tecnico'] as String? ?? os['tecnico_nombre'] as String? ?? '').toLowerCase().trim());
          // Sin técnico asignado → excluir para evitar fugas entre técnicos
          if (tecNorm.isEmpty) return false;
          final tecParts = tecNorm.split(RegExp(r'\s+'));
          final myParts  = myNom.split(RegExp(r'\s+'));
          // Mismo primer nombre pero apellido diferente → personas distintas → excluir
          if (tecParts.length >= 2 && myParts.length >= 2 &&
              tecParts[0] == myParts[0] && tecParts[1] != myParts[1]) return false;
          // Verificación por nombre completo (no solo primer nombre)
          if (tecNorm != myNom && !tecNorm.contains(myNom) && !myNom.contains(tecNorm)) return false;
        }
      }
    }

    // 2. REPARACIÓN DEL FILTRO TEMPORAL (HOY / SEMANA / MES / TODO)
    if (p.periodo != 'Todo') {
      final fechaStr = (os['fecha'] as String? ?? '').trim();
      if (!coincidePeriodo(fechaStr, p.periodo, now)) {
        return false;
      }
    }

    if (p.modalidad.isNotEmpty && p.modalidad != 'Todas las Modalidades') {
      final m = (os['modalidad'] as String? ?? '').trim().toUpperCase();
      final isFisico = m.contains('FISIC') || m.contains('FÍSIC');
      if (p.modalidad == 'Solo Físicos' && !isFisico) return false;
      if (p.modalidad == 'Solo Digitales' && isFisico) return false;
    }

    if (p.tecnico != null && p.tecnico!.isNotEmpty &&
        !(os['tecnico'] as String? ?? '').toLowerCase().contains(p.tecnico!.toLowerCase())) return false;

    if (p.estado != null && p.estado!.isNotEmpty &&
        (os['estado'] as String? ?? '') != p.estado) return false;

    if (p.query.isNotEmpty) {
      final q = p.query.toLowerCase().trim();
      final ok = ['folio_os', 'cliente', 'sucursal', 'tecnico', 'tipo_servicio', 'id_lote', 'lote']
          .any((k) => (os[k]?.toString().toLowerCase() ?? '').contains(q));
      if (!ok) return false;
    }

    return true;
  }).toList();

  final uniqueMap = <String, Map<String, dynamic>>{};
  for (final os in filtered) {
    final folio = (os['folio_os'] as String? ?? '').trim();
    final key = folio.isNotEmpty
        ? folio
        : (os['local_id'] ?? os['id'] ?? '').toString();
    if (key.isNotEmpty) uniqueMap[key] = os;
  }
  return uniqueMap.values.toList();
}

// ═══════════════════════════════════════════════════════════════════════════
// VISTA PARA CELULARES (MobilePhoneDashboard - < 650px)
// ═══════════════════════════════════════════════════════════════════════════
class _MobilePhoneDashboard extends StatelessWidget {
  final _OsListScreenState state;
  final SyncService sync;
  final bool hideTecnico;

  const _MobilePhoneDashboard({
    required this.state,
    required this.sync,
    required this.hideTecnico,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewPadding.bottom;
    final isOnline = sync.state != SyncState.offline && sync.state != SyncState.error;

    return Column(
      children: [
        // ── 1. HEADER & STATUS ───────────────────────────────────────────
        Container(
          color: _kCardBg,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _kBorder)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.menu_rounded, color: _kTextPrim, size: 24),
                onPressed: () => AppShell.toggleMenu(context),
                tooltip: 'Menú',
              ),
              const SizedBox(width: 4),
              const Text(
                'Servicios PESA',
                style: TextStyle(
                  color: _kTextPrim,
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                ),
              ),
              const Spacer(),
              // Píldora sutil de conectividad
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isOnline ? const Color(0xFFE8F5E9) : const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isOnline ? const Color(0xFF2E7D32) : const Color(0xFF86868B),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      isOnline ? 'En línea' : 'Sin conexión',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isOnline ? const Color(0xFF2E7D32) : const Color(0xFF86868B),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              // Botón sincronizar circular
              IconButton(
                icon: sync.state == SyncState.syncing
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: _kCarmineRed),
                      )
                    : const Icon(Icons.sync_rounded, color: _kTextPrim, size: 22),
                // [FIX-CUELGUE] Si está sincroni... siempre permitir tocar para forzar reset
                onPressed: () {
                  if (sync.state == SyncState.syncing) {
                    sync.forceResetSync();
                  } else {
                    state._sincronizarOrdenesServidor();
                  }
                },
                tooltip: sync.state == SyncState.syncing ? 'Toca para cancelar' : 'Sincronizar',
              ),
            ],
          ),
        ),

        // ── 2. KPI SUMMARY (Grid 2x2 Limpio) ──────────────────────────────
        Container(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    _buildMobileKpiCard('TOTAL PERÍODO', state._kpiTotal, const Color(0xFF2E7D32)),
                    const SizedBox(height: 8),
                    _buildMobileKpiCard('CERRADOS', state._kpiCerrado, const Color(0xFF1565C0)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  children: [
                    _buildMobileKpiCard('EN PROCESO', state._kpiProceso, _kCarmineRed),
                    const SizedBox(height: 8),
                    _buildMobileKpiCard('FORMATOS FÍSICOS', state._kpiFisico, const Color(0xFF7B1FA2)),
                  ],
                ),
              ),
            ],
          ),
        ),

        // ── 3. FILTROS RÁPIDOS (Horizontal Scroll + Search Bar) ────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: [
                    for (final p in ['Todo', 'Hoy', 'Semana', 'Mes']) ...[
                      ChoiceChip(
                        label: Text(p),
                        selected: state._periodo == p,
                        selectedColor: _kCarmineRed,
                        labelStyle: TextStyle(
                          fontSize: 12,
                          fontWeight: state._periodo == p ? FontWeight.bold : FontWeight.normal,
                          color: state._periodo == p ? Colors.white : _kTextPrim,
                        ),
                        backgroundColor: Colors.white,
                        side: BorderSide(
                          color: state._periodo == p ? _kCarmineRed : _kBorder,
                        ),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        onSelected: (_) {
                          state.setState(() => state._periodo = p);
                          state._applyFilters();
                        },
                      ),
                      const SizedBox(width: 6),
                    ],
                    _buildMobileChipDropdown(
                      label: state._estado ?? 'Estado',
                      items: ['Todos', ...state._estados],
                      onSelected: (val) {
                        state.setState(() => state._estado = (val == 'Todos' ? null : val));
                        state._applyFilters();
                      },
                    ),
                    const SizedBox(width: 6),
                    _buildMobileChipDropdown(
                      label: state._modalidad,
                      items: ['Todas las Modalidades', 'Solo Físicos', 'Solo Digitales'],
                      onSelected: (val) {
                        state.setState(() => state._modalidad = val);
                        state._applyFilters();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Search bar (Estilo iOS 40px, #EBEBED, radius 10px)
              SizedBox(
                height: 40,
                child: TextField(
                  controller: state._searchCtrl,
                  style: const TextStyle(fontSize: 13, color: _kTextPrim),
                  decoration: InputDecoration(
                    hintText: 'Buscar por folio, cliente, sucursal...',
                    hintStyle: const TextStyle(color: _kTextSec, fontSize: 13),
                    prefixIcon: const Icon(Icons.search, size: 18, color: _kTextSec),
                    suffixIcon: state._query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.cancel, size: 16, color: _kTextSec),
                            onPressed: () {
                              state._searchCtrl.clear();
                              state.setState(() => state._query = '');
                              state._applyFilters();
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    filled: true,
                    fillColor: const Color(0xFFEBEBED),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: _kCarmineRed, width: 1.5),
                    ),
                  ),
                  onChanged: (v) {
                    state.setState(() => state._query = v);
                    state._applyFilters();
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // ── 4. LISTA DE TARJETAS TÉCNICAS (Card List View) ────────────────
        Expanded(
          child: state._loading
              ? const Center(child: CircularProgressIndicator(color: _kCarmineRed))
              : state._filtered.isEmpty
                  ? _EmptyState(onSync: () => context.read<SyncService>().performSync())
                  : _buildMobileCardList(context),
        ),
        SizedBox(height: bottom > 0 ? bottom : 8),
      ],
    );
  }

  Widget _buildMobileKpiCard(String label, int value, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _kTextSec,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value.toString(),
            maxLines: 1,
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileChipDropdown({
    required String label,
    required List<String> items,
    required ValueChanged<String> onSelected,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      height: 32,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          hint: Text(label, style: const TextStyle(fontSize: 12, color: _kTextPrim)),
          isDense: true,
          icon: const Icon(Icons.arrow_drop_down, size: 18, color: _kTextSec),
          items: items.map((item) {
            return DropdownMenuItem<String>(
              value: item,
              child: Text(item, style: const TextStyle(fontSize: 12, color: _kTextPrim)),
            );
          }).toList(),
          onChanged: (v) {
            if (v != null) onSelected(v);
          },
        ),
      ),
    );
  }

  Widget _buildMobileCardList(BuildContext context) {
    final groups = state._groupByLote(state._filtered);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: groups.length,
      itemBuilder: (ctx, i) {
        final group = groups[i];
        if (group.isLote) {
          return _MobileLoteCard(
            group: group,
            state: state,
            onCaptura: (os) => ctx.push(
              '/captura/${os['local_id']}',
              extra: Map<String, dynamic>.from(os),
            ),
          );
        }
        final os = group.items.first;
        return _MobileOsCard(
          os: os,
          onCaptura: () => ctx.push(
            '/captura/${os['local_id']}',
            extra: Map<String, dynamic>.from(os),
          ),
          onAbrirPdf: state._abrirPdf,
          onDescargarPdf: state._descargarPdfConNomenclatura,
          onRehacer: state._mostrarDialogoRehacerToma,
          onEliminarDatos: state._mostrarDialogoEliminarDatosDesdeCero,
          onSubirPdfManual: state._subirPdfManual,
        );
      },
    );
  }
}

// ── Mobile Individual Technical Card ───────────────────────────────────────
class _MobileOsCard extends StatelessWidget {
  final Map<String, dynamic> os;
  final VoidCallback onCaptura;
  final Function(BuildContext, Map<String, dynamic>) onAbrirPdf;
  final Function(BuildContext, Map<String, dynamic>) onDescargarPdf;
  final Function(BuildContext, Map<String, dynamic>) onRehacer;
  final Function(BuildContext, Map<String, dynamic>) onEliminarDatos;
  final Function(BuildContext, Map<String, dynamic>) onSubirPdfManual;

  const _MobileOsCard({
    required this.os,
    required this.onCaptura,
    required this.onAbrirPdf,
    required this.onDescargarPdf,
    required this.onRehacer,
    required this.onEliminarDatos,
    required this.onSubirPdfManual,
  });

  @override
  Widget build(BuildContext context) {
    final folioStr  = (os['folio_os'] as String? ?? os['folio'] as String? ?? '').trim();
    final estado    = (os['estado'] as String? ?? '').toUpperCase().trim();
    final estatus   = (os['estatus'] as String? ?? '').toUpperCase().trim();
    final modalidad = (os['modalidad'] as String? ?? 'DIGITAL').toUpperCase();
    final syncSt    = (os['sync_status'] as String? ?? '');

    final bool pdfReal = _OsListScreenState.tienePdfReal(os);
    final bool noIniciada = _OsListScreenState.sinIniciar(os);
    final bool isFisico = modalidad == 'FISICA' || modalidad == 'FISICO';

    final String estatusLabel = pdfReal
        ? '✓ PDF Listo'
        : (noIniciada ? '⚠️ Sin Formato' : 'Pendiente');
    final Color estatusFg = pdfReal
        ? const Color(0xFF2E7D32)
        : (noIniciada ? const Color(0xFFD97706) : const Color(0xFF2563EB));
    final Color estatusBg = pdfReal
        ? const Color(0xFFE8F5E9)
        : (noIniciada ? const Color(0xFFFFFBEB) : const Color(0xFFEFF6FF));

    final bool isSincronizado = syncSt == 'SINCRONIZADO' ||
        syncSt == 'SINCRONIZADO_RENDER' ||
        os['is_synced'] == 1 ||
        os['is_synced'] == '1' ||
        os['sync_check_status'] == 'SUBIDA_SERVIDOR' ||
        os['sync_check_status'] == 'AUDITADA_ADMIN' ||
        os['sync_check_status'] == 'ABIERTO' ||
        (pdfReal && syncSt != 'PENDIENTE_ACTUALIZAR');

    final fechaStr = (os['fecha'] as String? ?? '').split('T').first.split(' ').first;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fila Superior: Folio destacado + Badge de Estatus
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                folioStr.isNotEmpty ? folioStr : '—',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: _kCarmineRed,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: estatusBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  estatusLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: estatusFg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Fila Media: Cliente (14px semi-bold) + Sucursal (12px #86868B)
          Text(
            os['cliente'] as String? ?? 'Sin cliente',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: _kTextPrim,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if ((os['sucursal'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              os['sucursal'].toString(),
              style: const TextStyle(
                fontSize: 12,
                color: _kTextSec,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),

          // Fila de Metadatos: Tipo de servicio + Fecha + Sync Badge
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  os['tipo_servicio'] as String? ?? 'Servicio',
                  style: const TextStyle(
                    fontSize: 11,
                    color: _kTextPrim,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                fechaStr,
                style: const TextStyle(
                  fontSize: 12,
                  color: _kTextSec,
                ),
              ),
              const Spacer(),
              SyncCheckBadge(
                status: (os['sync_check_status'] as String?)?.isNotEmpty == true
                    ? os['sync_check_status'] as String
                    : (isSincronizado ? 'SUBIDA_SERVIDOR' : 'RECIBIDA_TABLET'),
                showLabel: true,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Fila Inferior (Acciones ergonómicas táctiles)
          if (pdfReal) ...[
            // A) TIENE PDF REAL GENERADO O ADJUNTADO
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE3F2FD),
                        foregroundColor: const Color(0xFF1565C0),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFFBBDEFB)),
                        ),
                      ),
                      onPressed: () => onAbrirPdf(context, os),
                      child: const Text(
                        '📄 Ver PDF',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE8F5E9),
                        foregroundColor: const Color(0xFF2E7D32),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFFC8E6C9)),
                        ),
                      ),
                      onPressed: () => onDescargarPdf(context, os),
                      child: const Text(
                        '📥 Descargar',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFF3E0),
                        foregroundColor: const Color(0xFFE65100),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFFFFE0B2)),
                        ),
                      ),
                      onPressed: () => onRehacer(context, os),
                      child: const Text(
                        '🔄 Rehacer',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEDE7F6),
                        foregroundColor: const Color(0xFF5E35B1),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFFD1C4E9)),
                        ),
                      ),
                      onPressed: () => onSubirPdfManual(context, os),
                      icon: const Icon(Icons.upload_file_rounded, size: 16),
                      label: const Text(
                        '📤 Subir PDF manual',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFEBEE),
                        foregroundColor: const Color(0xFFC62828),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFFFFCDD2)),
                        ),
                      ),
                      onPressed: () => onEliminarDatos(context, os),
                      icon: const Icon(Icons.delete_forever_rounded, size: 16),
                      label: const Text(
                        '🗑️ Eliminar datos',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            // B) SIN PDF / SIN INICIAR / PENDIENTE
            if (isFisico) ...[
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C3AED),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => context.push('/escaneo', extra: {'folio_os': os['folio_os'] ?? ''}),
                  icon: const Icon(Icons.document_scanner_outlined, size: 18),
                  label: const Text(
                    '📤 Adjuntar PDF Escaneado',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: noIniciada ? const Color(0xFFE65100) : _kCarmineRed,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: onCaptura,
                  icon: Icon(noIniciada ? Icons.edit : Icons.edit_document, size: 18),
                  label: Text(
                    noIniciada ? '✍️ Iniciar Captura' : '📝 Continuar Toma de Datos',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEDE7F6),
                        foregroundColor: const Color(0xFF5E35B1),
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Color(0xFFD1C4E9)),
                        ),
                      ),
                      onPressed: () => onSubirPdfManual(context, os),
                      icon: const Icon(Icons.upload_file_rounded, size: 16),
                      label: const Text(
                        '📤 Subir PDF manual',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                if (!noIniciada) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFEBEE),
                          foregroundColor: const Color(0xFFC62828),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Color(0xFFFFCDD2)),
                          ),
                        ),
                        onPressed: () => onEliminarDatos(context, os),
                        icon: const Icon(Icons.delete_forever_rounded, size: 16),
                        label: const Text(
                          '🗑️ Eliminar datos',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Mobile Lote Card ───────────────────────────────────────────────────────
class _MobileLoteCard extends StatefulWidget {
  final _OsGroup group;
  final _OsListScreenState state;
  final void Function(Map<String, dynamic> os) onCaptura;

  const _MobileLoteCard({
    required this.group,
    required this.state,
    required this.onCaptura,
  });

  @override
  State<_MobileLoteCard> createState() => _MobileLoteCardState();
}

class _MobileLoteCardState extends State<_MobileLoteCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final count = widget.group.items.length;
    final first = widget.group.items.first;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFED7AA), width: 1),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _kCarmineRed,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'LOTE · $count OS',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      first['cliente'] as String? ?? 'Cliente del Lote',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _kTextPrim),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: _kCarmineRed,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                children: widget.group.items.map((os) {
                  return _MobileOsCard(
                    os: os,
                    onCaptura: () => widget.onCaptura(os),
                    onAbrirPdf: widget.state._abrirPdf,
                    onDescargarPdf: widget.state._descargarPdfConNomenclatura,
                    onRehacer: widget.state._mostrarDialogoRehacerToma,
                    onEliminarDatos: widget.state._mostrarDialogoEliminarDatosDesdeCero,
                    onSubirPdfManual: widget.state._subirPdfManual,
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// VISTA PARA TABLETS Y PANTALLAS ANCHAS (TabletDesktopDashboard - >= 650px)
// ═══════════════════════════════════════════════════════════════════════════
class _TabletDesktopDashboard extends StatelessWidget {
  final _OsListScreenState state;
  final SyncService sync;
  final bool hideTecnico;

  const _TabletDesktopDashboard({
    required this.state,
    required this.sync,
    required this.hideTecnico,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewPadding.bottom;

    return Column(
      children: [
        // Top Header
        _Header(
          sync: sync,
          onSync: state._sincronizarOrdenesServidor,
          onRefresh: state._loadLocal,
        ),
        // 4 KPI Cards horizontally balanced
        _KpiBar(
          total: state._kpiTotal,
          proceso: state._kpiProceso,
          cerrado: state._kpiCerrado,
          fisico: state._kpiFisico,
        ),
        // Filter Bar
        _FilterBar(
          periodo:    state._periodo,
          modalidad:  state._modalidad,
          tecnico:    state._tecnico,
          estado:     state._estado,
          tecnicos:   state._tecnicos,
          estados:    state._estados,
          searchCtrl: state._searchCtrl,
          query:      state._query,
          hideTecnico: hideTecnico,
          onPeriodo:   (v) { state.setState(() => state._periodo = v); state._applyFilters(); },
          onModalidad: (v) { state.setState(() => state._modalidad = v); state._applyFilters(); },
          onTecnico:   (v) { state.setState(() => state._tecnico = v); state._applyFilters(); },
          onEstado:    (v) { state.setState(() => state._estado = v); state._applyFilters(); },
          onSearch:    (v) { state.setState(() => state._query = v); state._applyFilters(); },
          onClear:     ()  { state._searchCtrl.clear(); state.setState(() => state._query = ''); state._applyFilters(); },
        ),
        // Table Header & Rows (CERO SCROLL HORIZONTAL - 2 Niveles)
        Expanded(
          child: Column(
            children: [
              _TableHeader(hideTecnico: hideTecnico),
              Expanded(
                child: state._loading
                    ? const Center(child: CircularProgressIndicator(color: _kCarmineRed))
                    : state._filtered.isEmpty
                        ? _EmptyState(onSync: () => context.read<SyncService>().performSync())
                        : _buildTabletGroupedList(context),
              ),
            ],
          ),
        ),
        SizedBox(height: bottom > 0 ? bottom : 8),
      ],
    );
  }

  Widget _buildTabletGroupedList(BuildContext context) {
    final groups = state._groupByLote(state._filtered);

    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (ctx, i) {
        final group = groups[i];
        if (group.isLote) {
          return _LoteRow(
            group: group,
            hideTecnico: hideTecnico,
            onCaptura: (os) => ctx.push(
              '/captura/${os['local_id']}',
              extra: Map<String, dynamic>.from(os),
            ),
          );
        }
        final os = group.items.first;
        return _OsRow(
          os: os,
          index: i,
          hideTecnico: hideTecnico,
          onCaptura: () => ctx.push(
            '/captura/${os['local_id']}',
            extra: Map<String, dynamic>.from(os),
          ),
          onAbrirPdf: state._abrirPdf,
          onDescargarPdf: state._descargarPdfConNomenclatura,
          onRehacer: state._mostrarDialogoRehacerToma,
          onEliminarDatos: state._mostrarDialogoEliminarDatosDesdeCero,
          onSubirPdfManual: state._subirPdfManual,
        );
      },
    );
  }
}

// ── Header (Tablet / Desktop) ──────────────────────────────────────────────
class _Header extends StatelessWidget {
  final SyncService sync;
  final VoidCallback onSync;
  final VoidCallback onRefresh;
  const _Header({required this.sync, required this.onSync, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: _kCardBg,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.menu_rounded, color: _kTextPrim, size: 24),
            tooltip: 'Alternar menú lateral',
            onPressed: () => AppShell.toggleMenu(context),
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: _kCarmineRed, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.scale, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Resumen Operativo de Servicios',
                  style: TextStyle(color: _kTextPrim, fontWeight: FontWeight.w800, fontSize: 15),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Órdenes de Servicio, Revisiones e Inventarios',
                  style: TextStyle(color: _kTextSec, fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _SyncChip(sync: sync),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _kTextPrim,
              side: const BorderSide(color: _kBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            onPressed: () {
              // [FIX-CUELGUE] Si está trabado, forzar reset antes de reintentar
              if (sync.state == SyncState.syncing) {
                sync.forceResetSync();
              } else {
                onSync();
              }
            },
            icon: sync.state == SyncState.syncing
                ? const SizedBox(
                    width: 13, height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _kCarmineRed),
                  )
                : const Icon(Icons.sync, size: 15),
            label: Text(
              sync.state == SyncState.syncing ? 'Cancelar' : 'Sincronizar',
              style: const TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(width: 4),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: _kTextPrim,
              side: const BorderSide(color: _kBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              minimumSize: Size.zero,
            ),
            onPressed: onRefresh,
            child: const Icon(Icons.refresh, size: 16),
          ),
          Builder(builder: (ctx) {
            final isTecnico = ctx.watch<AuthService>().isTecnico;
            if (isTecnico) return const SizedBox.shrink();
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 4),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kCarmineRed,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  onPressed: () => context.push('/nuevo-doc'),
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text(
                    '+ Nuevo Documento',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _SyncChip extends StatelessWidget {
  final SyncService sync;
  const _SyncChip({required this.sync});
  @override
  Widget build(BuildContext context) {
    switch (sync.state) {
      case SyncState.syncing:
        return _chip(Colors.blue.shade50, Colors.blue.shade700, '↻ Sincronizando...');
      case SyncState.success:
        return _chip(Colors.green.shade50, Colors.green.shade700, '✓ Sincronizado');
      case SyncState.error:
        final errText = (sync.errorMessage != null && sync.errorMessage!.isNotEmpty)
            ? sync.errorMessage!
            : (sync.message.isNotEmpty ? sync.message : '⚠ Error');
        return _chip(Colors.orange.shade50, Colors.orange.shade700, errText);
      case SyncState.offline:
        return _chip(Colors.grey.shade100, Colors.grey.shade600, '📵 Sin conexión');
      default:
        return _chip(Colors.grey.shade100, Colors.grey.shade600, 'Listo');
    }
  }
  Widget _chip(Color bg, Color fg, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Text(label, style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w600)),
      );
}

// ── KPI Bar (Tablet / Desktop - 4 horizontal cards) ───────────────────────
class _KpiBar extends StatelessWidget {
  final int total, proceso, cerrado, fisico;
  const _KpiBar({
    required this.total,
    required this.proceso,
    required this.cerrado,
    required this.fisico,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kCardBg,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          _KpiCard(
            label: 'TOTAL PERIODO',
            value: total,
            sub: '${total == 1 ? "1 orden" : "$total órdenes"} en el periodo',
            color: const Color(0xFF16A34A),
          ),
          const SizedBox(width: 12),
          _KpiCard(
            label: 'EN PROCESO',
            value: proceso,
            sub: 'órdenes pendientes de cerrar',
            color: _kCarmineRed,
          ),
          const SizedBox(width: 12),
          _KpiCard(
            label: 'CERRADOS',
            value: cerrado,
            sub: 'Total cerradas',
            color: const Color(0xFF2563EB),
          ),
          const SizedBox(width: 12),
          _KpiCard(
            label: 'FORMATOS FÍSICOS',
            value: fisico,
            sub: 'órdenes en formato físico',
            color: const Color(0xFF7C3AED),
          ),
        ],
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label, sub;
  final int value;
  final Color color;
  const _KpiCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _kCardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: _kTextSec,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                value.toString(),
                style: TextStyle(
                  color: color,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                sub,
                style: const TextStyle(color: _kTextSec, fontSize: 10),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
}

// ── Filter Bar (Tablet / Desktop) ─────────────────────────────────────────
class _FilterBar extends StatelessWidget {
  final String periodo;
  final String modalidad;
  final String? tecnico, estado;
  final List<String> tecnicos, estados;
  final TextEditingController searchCtrl;
  final String query;
  final ValueChanged<String> onPeriodo;
  final ValueChanged<String> onModalidad;
  final ValueChanged<String?> onTecnico, onEstado;
  final ValueChanged<String> onSearch;
  final VoidCallback onClear;
  final bool hideTecnico;

  const _FilterBar({
    required this.periodo,
    required this.modalidad,
    required this.tecnico,
    required this.estado,
    required this.tecnicos,
    required this.estados,
    required this.searchCtrl,
    required this.query,
    this.hideTecnico = false,
    required this.onPeriodo,
    required this.onModalidad,
    required this.onTecnico,
    required this.onEstado,
    required this.onSearch,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kCardBg,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              for (final p in ['Hoy', 'Semana', 'Mes', 'Todo'])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(
                      p,
                      style: TextStyle(
                        fontSize: 12,
                        color: periodo == p ? _kCarmineRed : _kTextSec,
                        fontWeight: periodo == p ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                    selected: periodo == p,
                    selectedColor: Colors.red.shade50,
                    checkmarkColor: _kCarmineRed,
                    side: BorderSide(color: periodo == p ? _kCarmineRed : _kBorder),
                    backgroundColor: _kCardBg,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    onSelected: (_) => onPeriodo(p),
                  ),
                ),
              const Spacer(),
              if (!hideTecnico) ...[
                _DropdownFilter(
                  hint: 'Todos los Técnicos',
                  value: tecnico,
                  items: tecnicos,
                  onChanged: onTecnico,
                ),
                const SizedBox(width: 8),
              ],
              _ModalidadDropdownFilter(
                value: modalidad,
                onChanged: onModalidad,
              ),
              const SizedBox(width: 8),
              _DropdownFilter(
                hint: 'Todos los Estados',
                value: estado,
                items: estados,
                onChanged: onEstado,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 36,
            child: TextField(
              controller: searchCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Buscar por folio, cliente, sucursal o técnico...',
                hintStyle: const TextStyle(color: _kTextSec, fontSize: 12),
                prefixIcon: const Icon(Icons.search, size: 16, color: _kTextSec),
                suffixIcon: query.isNotEmpty
                    ? IconButton(icon: const Icon(Icons.close, size: 14), onPressed: onClear)
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _kBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _kCarmineRed),
                ),
                filled: true,
                fillColor: _kCardBg,
              ),
              onChanged: onSearch,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModalidadDropdownFilter extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _ModalidadDropdownFilter({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
        color: _kCardBg,
      ),
      child: DropdownButton<String>(
        value: value,
        isDense: true,
        underline: const SizedBox(),
        style: const TextStyle(fontSize: 12, color: _kTextPrim),
        items: const [
          DropdownMenuItem(
            value: 'Todas las Modalidades',
            child: Text('Todas las Modalidades', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          DropdownMenuItem(
            value: 'Solo Físicos',
            child: Text('Solo Físicos', style: TextStyle(fontSize: 12, color: Color(0xFF7C3AED), fontWeight: FontWeight.w600)),
          ),
          DropdownMenuItem(
            value: 'Solo Digitales',
            child: Text('Solo Digitales', style: TextStyle(fontSize: 12, color: Color(0xFF2563EB), fontWeight: FontWeight.w600)),
          ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

class _DropdownFilter extends StatelessWidget {
  final String hint;
  final String? value;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  const _DropdownFilter({
    required this.hint,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(6),
        color: _kCardBg,
      ),
      child: DropdownButton<String>(
        value: value,
        hint: Text(hint, style: const TextStyle(fontSize: 12, color: _kTextSec)),
        isDense: true,
        underline: const SizedBox(),
        style: const TextStyle(fontSize: 12, color: _kTextPrim),
        items: [
          DropdownMenuItem<String>(value: null, child: Text(hint, style: const TextStyle(color: _kTextSec))),
          ...items.map((t) => DropdownMenuItem<String>(value: t, child: Text(t))),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

// ── Table Header (Tablet / Desktop - Weighted Auto-Stretch Columns) ───────
// ── Table Header (Tablet / Desktop - 6 Columnas Nivel 1) ─────────────────
class _TableHeader extends StatelessWidget {
  final bool hideTecnico;
  const _TableHeader({this.hideTecnico = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kTableHead,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: const Row(
        children: [
          SizedBox(width: 130, child: _TH('FOLIO OS')),
          SizedBox(width: 95, child: _TH('FECHA')),
          Expanded(
            flex: 3,
            child: _TH('CLIENTE / SUCURSAL'),
          ),
          SizedBox(width: 90, child: _TH('MODALIDAD')),
          SizedBox(width: 100, child: _TH('ESTATUS')),
          SizedBox(width: 90, child: _TH('SYNC')),
        ],
      ),
    );
  }
}

class _TH extends StatelessWidget {
  final String label;
  const _TH(this.label);
  @override
  Widget build(BuildContext context) => Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: _kTextPrim,
          letterSpacing: 0.5,
        ),
      );
}

// ── Table Row (Tablet / Desktop - Layout 2 Niveles) ────────────────────────
class _OsRow extends StatelessWidget {
  final Map<String, dynamic> os;
  final int index;
  final VoidCallback onCaptura;
  final Function(BuildContext, Map<String, dynamic>) onAbrirPdf;
  final Function(BuildContext, Map<String, dynamic>) onDescargarPdf;
  final Function(BuildContext, Map<String, dynamic>) onRehacer;
  final Function(BuildContext, Map<String, dynamic>) onEliminarDatos;
  final Function(BuildContext, Map<String, dynamic>) onSubirPdfManual;
  final bool indent;
  final bool hideTecnico;

  const _OsRow({
    required this.os,
    required this.index,
    required this.onCaptura,
    required this.onAbrirPdf,
    required this.onDescargarPdf,
    required this.onRehacer,
    required this.onEliminarDatos,
    required this.onSubirPdfManual,
    this.indent = false,
    this.hideTecnico = false,
  });

  @override
  Widget build(BuildContext context) {
    final folioStr  = (os['folio_os'] as String? ?? os['folio'] as String? ?? '').trim();
    final modalidad = (os['modalidad'] as String? ?? 'DIGITAL').toUpperCase();
    final syncSt    = (os['sync_status'] as String? ?? '');
    final isFisico  = modalidad.contains('FISIC') || modalidad.contains('FÍSIC');
    final isEven    = index % 2 == 0;

    final bool hasDoc = _OsListScreenState.tieneDocumento(os);

    // Estatus badge:
    // Si tieneDocumento(o) == true: [ ✓ PDF Listo ] (Verde).
    // Si tieneDocumento(o) == false: [ ⚠️ Sin Formato ] (Ámbar).
    final String estatusLabel = hasDoc ? '✓ PDF Listo' : '⚠️ Sin Formato';
    final Color estatusFg = hasDoc ? const Color(0xFF2E7D32) : const Color(0xFFD97706);
    final Color estatusBg = hasDoc ? const Color(0xFFE8F5E9) : const Color(0xFFFFFBEB);

    final bool isSincronizado = syncSt == 'SINCRONIZADO' ||
        syncSt == 'SINCRONIZADO_RENDER' ||
        os['is_synced'] == 1 ||
        os['is_synced'] == '1' ||
        os['sync_check_status'] == 'SUBIDA_SERVIDOR' ||
        os['sync_check_status'] == 'AUDITADA_ADMIN' ||
        os['sync_check_status'] == 'ABIERTO' ||
        (hasDoc && syncSt != 'PENDIENTE_ACTUALIZAR');

    // Sync badge:
    // Si tieneDocumento(o) == false: NUNCA mostrar "✓ Enviada". Debe mostrar [ Abierto ] o [ Asignada ].
    String effectiveSyncStatus;
    final rawSync = (os['sync_check_status'] as String? ?? '').trim().toUpperCase();
    if (!hasDoc) {
      if (rawSync == 'AUDITADA_ADMIN' || rawSync == 'ABIERTO') {
        effectiveSyncStatus = 'AUDITADA_ADMIN';
      } else {
        effectiveSyncStatus = 'ASIGNADA';
      }
    } else {
      if (rawSync == 'SUBIDA_SERVIDOR' || rawSync == 'ENVIADA' || rawSync == 'AUDITADA_ADMIN' || rawSync == 'ABIERTO') {
        effectiveSyncStatus = rawSync;
      } else {
        effectiveSyncStatus = isSincronizado ? 'SUBIDA_SERVIDOR' : 'RECIBIDA_TABLET';
      }
    }

    final fechaStr = (os['fecha'] as String? ?? '').split('T').first.split(' ').first;

    return Container(
      color: isEven ? _kCardBg : const Color(0xFFFAFAFA),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── NIVEL 1 (Superior): Datos esenciales al 100% del ancho ────────
          Row(
            children: [
              // [FOLIO OS] (130px)
              SizedBox(
                width: 130,
                child: Padding(
                  padding: EdgeInsets.only(left: indent ? 12.0 : 0.0),
                  child: Text(
                    folioStr.isNotEmpty ? folioStr : '—',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kCarmineRed),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              // [FECHA] (95px)
              SizedBox(
                width: 95,
                child: Text(
                  fechaStr,
                  style: const TextStyle(fontSize: 11, color: _kTextPrim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // [CLIENTE / SUCURSAL] (Expanded, flex: 3)
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      os['cliente'] ?? '—',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kTextPrim),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    if ((os['sucursal'] ?? '').toString().isNotEmpty || (os['tipo_servicio'] ?? '').toString().isNotEmpty)
                      Text(
                        [
                          if ((os['sucursal'] ?? '').toString().isNotEmpty) os['sucursal']!.toString(),
                          if ((os['tipo_servicio'] ?? '').toString().isNotEmpty) os['tipo_servicio']!.toString(),
                        ].join(' · '),
                        style: const TextStyle(fontSize: 10, color: _kTextSec),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                  ],
                ),
              ),
              // [MODALIDAD] (90px)
              SizedBox(
                width: 90,
                child: _Badge(
                  label: isFisico ? 'Físico' : 'Digital',
                  fg: isFisico ? const Color(0xFF7C3AED) : const Color(0xFF2563EB),
                  bg: isFisico ? const Color(0xFFF3F0FF) : const Color(0xFFEFF6FF),
                ),
              ),
              // [ESTATUS] (100px)
              SizedBox(
                width: 100,
                child: _Badge(
                  label: estatusLabel,
                  fg: estatusFg,
                  bg: estatusBg,
                ),
              ),
              // [SYNC] (90px)
              SizedBox(
                width: 90,
                child: SyncCheckBadge(
                  status: effectiveSyncStatus,
                  showLabel: true,
                ),
              ),
            ],
          ),

          // ── NIVEL 2 (Inferior): Fila de acciones alineada a la derecha con margen de 6px ───
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (hasDoc) ...[
                  // Si tiene PDF / formato:
                  // [ 📄 Ver PDF ]  [ 📥 Descargar ]  [ 🔄 Rehacer ]  [ 📤 Subir PDF ]  [ 🗑️ Reset ]
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1976D2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      minimumSize: const Size(60, 30),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: const Icon(Icons.picture_as_pdf, size: 14),
                    label: const Text('📄 Ver PDF', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    onPressed: () => onAbrirPdf(context, os),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      minimumSize: const Size(65, 30),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: const Icon(Icons.download, size: 14),
                    label: const Text('📥 Descargar', style: TextStyle(fontSize: 11)),
                    onPressed: () => onDescargarPdf(context, os),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF57C00),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: const Size(60, 30),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: const Icon(Icons.replay_rounded, size: 14),
                    label: const Text('🔄 Rehacer', style: TextStyle(fontSize: 11)),
                    onPressed: () => onRehacer(context, os),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4338CA),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: const Size(55, 30),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: const Icon(Icons.upload_file, size: 14),
                    label: const Text('📤 Subir PDF', style: TextStyle(fontSize: 11)),
                    onPressed: () => onSubirPdfManual(context, os),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFC62828),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: const Size(55, 30),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: const Icon(Icons.delete_forever, size: 14),
                    label: const Text('🗑️ Reset', style: TextStyle(fontSize: 11)),
                    onPressed: () => onEliminarDatos(context, os),
                  ),
                ] else ...[
                  // Si no tiene formato:
                  // [ ✍️ Iniciar Captura ]  [ 📤 Subir PDF manual ]
                  if (isFisico) ...[
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF7C3AED),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: const Size(110, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      icon: const Icon(Icons.document_scanner_outlined, size: 14),
                      label: const Text('📤 Adjuntar PDF', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      onPressed: () => context.push('/escaneo', extra: {'folio_os': os['folio_os'] ?? ''}),
                    ),
                  ] else ...[
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE65100),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: const Size(115, 30),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      icon: const Icon(Icons.edit, size: 14),
                      label: const Text(
                        '✍️ Iniciar Captura',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      onPressed: onCaptura,
                    ),
                  ],
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4338CA),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      minimumSize: const Size(55, 30),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: const Icon(Icons.upload_file, size: 14),
                    label: const Text('📤 Subir PDF manual', style: TextStyle(fontSize: 11)),
                    onPressed: () => onSubirPdfManual(context, os),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tablet Lote Row ────────────────────────────────────────────────────────
class _LoteRow extends StatefulWidget {
  final _OsGroup group;
  final void Function(Map<String, dynamic> os) onCaptura;
  final bool hideTecnico;
  const _LoteRow({
    required this.group,
    required this.onCaptura,
    this.hideTecnico = false,
  });

  @override
  State<_LoteRow> createState() => _LoteRowState();
}

class _LoteRowState extends State<_LoteRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final first = widget.group.items.first;
    final count = widget.group.items.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            color: const Color(0xFFFFF7ED),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: _kBorder),
                left: BorderSide(color: _kCarmineRed, width: 3),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 130,
                  child: Row(
                    children: [
                      Icon(_expanded ? Icons.keyboard_arrow_down : Icons.chevron_right, size: 18, color: _kCarmineRed),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(color: _kCarmineRed, borderRadius: BorderRadius.circular(4)),
                        child: Text('LOTE · $count OS', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 95,
                  child: Text(
                    (first['fecha'] as String? ?? '').split('T').first,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    first['cliente'] ?? '—',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    softWrap: true,
                  ),
                ),
                const SizedBox(width: 90, child: Text('Lote', style: TextStyle(fontSize: 11))),
                const SizedBox(width: 100, child: Text('Lote', style: TextStyle(fontSize: 11, color: _kCarmineRed))),
                const SizedBox(width: 90),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (int i = 0; i < widget.group.items.length; i++)
            _OsRow(
              os: widget.group.items[i],
              index: i,
              hideTecnico: widget.hideTecnico,
              onCaptura: () => widget.onCaptura(widget.group.items[i]),
              onAbrirPdf: (ctx, os) => (context.findAncestorStateOfType<_OsListScreenState>())?._abrirPdf(ctx, os),
              onDescargarPdf: (ctx, os) => (context.findAncestorStateOfType<_OsListScreenState>())?._descargarPdfConNomenclatura(ctx, os),
              onRehacer: (ctx, os) => (context.findAncestorStateOfType<_OsListScreenState>())?._mostrarDialogoRehacerToma(ctx, os),
              onEliminarDatos: (ctx, os) => (context.findAncestorStateOfType<_OsListScreenState>())?._mostrarDialogoEliminarDatosDesdeCero(ctx, os),
              onSubirPdfManual: (ctx, os) => (context.findAncestorStateOfType<_OsListScreenState>())?._subirPdfManual(ctx, os),
              indent: true,
            ),
      ],
    );
  }
}

// ── Shared Helpers ─────────────────────────────────────────────────────────
class _Badge extends StatelessWidget {
  final String label;
  final Color fg, bg;
  const _Badge({required this.label, required this.fg, required this.bg});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
        child: Text(
          label,
          style: TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
      );
}


class _EmptyState extends StatelessWidget {
  final VoidCallback onSync;
  const _EmptyState({required this.onSync});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.assignment_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            const Text(
              'No hay registros para este período',
              style: TextStyle(fontSize: 15, color: _kTextSec),
            ),
            const SizedBox(height: 4),
            const Text(
              'Sincroniza para descargar las órdenes del servidor',
              style: TextStyle(fontSize: 12, color: _kTextSec),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onSync,
              icon: const Icon(Icons.sync, size: 16),
              label: const Text('Sincronizar con servidor'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _kCarmineRed,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      );
}

class _OsGroup {
  final String loteKey;
  final List<Map<String, dynamic>> items;
  final bool isLote;
  const _OsGroup({
    required this.loteKey,
    required this.items,
    required this.isLote,
  });
}