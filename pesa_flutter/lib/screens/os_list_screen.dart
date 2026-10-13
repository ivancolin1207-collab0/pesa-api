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
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
import '../services/pdf_storage_service.dart';
import '../services/sync_service.dart';
import '../services/tipo_servicio_rules.dart';
import '../widgets/app_shell.dart';
import '../widgets/captura_firma_tecnico_dialog.dart';
import '../widgets/sync_check_badge.dart';
import 'calibraciones_repositorio_view.dart';
import 'captura_screen.dart';
import 'remision_captura_screen.dart';
import 'revision_bascula_screen.dart';
import 'levantamiento_proyecto_screen.dart';
import 'levantamiento_metrologico_screen.dart';

/// Formatea fecha y hora de entrega por correo (dd/MM/yyyy HH:mm)
String formatearFechaHoraEnvio(dynamic val) {
  if (val == null) return 'Reciente';
  final s = val.toString().trim();
  if (s.isEmpty) return 'Reciente';
  if (s.contains('/') && s.contains(':')) return s;
  try {
    final dt = DateTime.tryParse(s);
    if (dt != null) {
      return DateFormat('dd/MM/yyyy HH:mm').format(dt.toLocal());
    }
  } catch (_) {}
  return s;
}

/// Función auxiliar de normalización de cadenas (remover diacríticos/acentos y minúsculas)
String normalizarTexto(String texto) {
  var conAcentos = 'ÁÉÍÓÚáéíóúÀÈÌÒÙàèìòùÄËÏÖÜäëïöüÑñ';
  var sinAcentos = 'AEIOUaeiouAEIOUaeiouAEIOUaeiouNn';
  String resultado = texto.trim().toLowerCase();
  for (int i = 0; i < conAcentos.length; i++) {
    resultado = resultado.replaceAll(conAcentos[i], sinAcentos[i]);
  }
  return resultado;
}

// ── Design Tokens ──────────────────────────────────────────────────────────
const _kCarmineRed = Color(0xFFB81D24);
const _kBgColor    = Color(0xFFF5F5F7);
const _kCardBg     = Color(0xFFFFFFFF);
const _kBorder     = Color(0xFFE5E5EA);
const _kTextPrim   = Color(0xFF1D1D1F);
const _kTextSec    = Color(0xFF86868B);
const _kTableHead  = Color(0xFFF3F4F6);

/// Enrutador dinámico por tipo de documento:
/// RMA -> RemisionCapturaScreen
/// RE -> RevisionBasculaScreen
/// LP -> LevantamientoProyectoScreen
/// LV -> LevantamientoMetrologicoScreen
/// Resto -> CalibracionAjusteScreen (CapturaScreen)
void navegarCapturaSegunTipo(BuildContext context, Map<String, dynamic> orden) {
  final tipoDoc = (orden['tipo_documento'] ?? '').toString().toUpperCase();
  final tipoSrv = (orden['tipo_servicio'] ?? '').toString().toUpperCase();
  final folio = (orden['folio_os'] ?? orden['folio_rma'] ?? '').toString().toUpperCase();
  final tipo = '$tipoDoc $tipoSrv $folio';

  if (tipo.contains('RMA') || tipo.contains('REMISI')) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => RemisionCapturaScreen(orden: orden)));
  } else if (tipo.contains('REVISI') || tipoDoc == 'RE' || folio.startsWith('RE-')) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => RevisionBasculaScreen(orden: orden)));
  } else if (tipo.contains('PROYECTO') || tipoDoc == 'LP' || folio.startsWith('LP-')) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => LevantamientoProyectoScreen(orden: orden)));
  } else if (tipo.contains('METROL') || tipoDoc == 'LV' || folio.startsWith('LV-')) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => LevantamientoMetrologicoScreen(orden: orden)));
  } else {
    Navigator.push(context, MaterialPageRoute(builder: (_) => CalibracionAjusteScreen(orden: orden)));
  }
}

/// Retorna true si la modalidad del documento es explícitamente física.
/// Las remisiones (RMA-) y revisiones pueden ser tanto Digitales como Físicas,
/// según se defina en el backend / logística.
bool esModalidadFisica(String? modalidad) {
  final m = (modalidad ?? '').trim().toLowerCase();
  return m.contains('fisic') || m.contains('físic');
}

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

  // ── Cerrojo de Despacho de Correo (Debounce) ──────────────────────────────
  bool _estaEnviandoEmail = false;

  // ── Filters ───────────────────────────────────────────────────────────────
  String  _periodo   = 'Todo';
  String  _modalidad = 'Todas las Modalidades';
  String? _tecnico;
  String? _estado;
  String  _filtroTipoServicio = 'Todos los Servicios';
  String  _filtroEmpresa = 'Todas las Empresas';
  List<String> _listaEmpresas = ['Todas las Empresas'];
  List<String> _listaTiposServicio = ['Todos los Servicios'];
  String  _query     = '';
  final   _searchCtrl = TextEditingController();

  // ── Vista: Mis Órdenes vs Repositorio de Calibraciones (solo supervisión) ──
  bool _vistaRepositorio = false;
  int _seqCorreosVisto = 0;

  void _actualizarListasFiltros() {
    final empresasSet = <String>{};
    final tiposSet = <String>{
      'Calibración + Ajuste',
      'Ajuste',
      'Revisión',
      'Remisión',
      'Inspección',
      'Levantamiento',
      'Calibración',
      'Mantenimiento',
    };

    for (final o in _all) {
      final cli = (o['cliente'] ?? '').toString().trim();
      if (cli.isNotEmpty &&
          cli.toLowerCase() != 'none' &&
          cli.toLowerCase() != 'null' &&
          cli.toLowerCase() != '--' &&
          cli.toLowerCase() != 'cliente' &&
          cli.toLowerCase() != 'empresa') {
        empresasSet.add(cli);
      }
      final ts = (o['tipo_servicio'] ?? '').toString().trim();
      if (ts.isNotEmpty &&
          ts.toLowerCase() != 'none' &&
          ts.toLowerCase() != 'null' &&
          ts.toLowerCase() != '--') {
        tiposSet.add(ts);
      }
    }

    final listaEmpresasSorted = empresasSet.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final listaTiposSorted = tiposSet.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    _listaEmpresas = ['Todas las Empresas', ...listaEmpresasSorted];
    _listaTiposServicio = ['Todos los Servicios', ...listaTiposSorted];

    if (!_listaEmpresas.contains(_filtroEmpresa)) {
      _filtroEmpresa = 'Todas las Empresas';
    }
    if (!_listaTiposServicio.contains(_filtroTipoServicio)) {
      _filtroTipoServicio = 'Todos los Servicios';
    }
  }

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    final usuario = AuthService.usuarioActual;
    final isAdmin = auth.isAdmin || (usuario != null && usuario.isAdmin);
    if (isAdmin) {
      _vistaRepositorio = true;
      _tecnico = null;
    }

    final sync = context.read<SyncService>();
    sync.startNetworkMonitor();
    _seqCorreosVisto = sync.correosDespachadosSeq;
    sync.addListener(_onSyncChanged);

    if (sync.orders.isNotEmpty) {
      _all = List<Map<String, dynamic>>.from(sync.orders);
      _loading = false;
      _actualizarListasFiltros();
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

  void _mostrarMenuSincronizacion(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    'Opciones Avanzadas de Sincronización',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_upload_rounded, color: Color(0xFF2563EB), size: 28),
                  title: const Text('Forzar reenvío de órdenes cerradas', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Marca órdenes cerradas como pendientes y las sube forzosamente a PostgreSQL.'),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final sync = context.read<SyncService>();
                    final n = await sync.forzarReenvioOrdenesCerradas();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: Colors.green.shade700,
                          content: Text('Se forzó el reenvío de $n órdenes cerradas al servidor.'),
                        ),
                      );
                      await _loadLocal();
                    }
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.sync_problem_rounded, color: Color(0xFFD97706), size: 28),
                  title: const Text('Resincronización completa (PULL total)', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Descarga nuevamente todas las órdenes desde el servidor sin usar caché de fecha.'),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final sync = context.read<SyncService>();
                    await sync.resincronizacionCompleta();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          backgroundColor: Color(0xFF2563EB),
                          content: Text('Resincronización completa ejecutada.'),
                        ),
                      );
                      await _loadLocal();
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    context.read<SyncService>().removeListener(_onSyncChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSyncChanged() {
    final syncCorreos = context.read<SyncService>();
    if (syncCorreos.correosDespachadosSeq != _seqCorreosVisto) {
      _seqCorreosVisto = syncCorreos.correosDespachadosSeq;
      final n = syncCorreos.ultimosCorreosDespachados;
      if (n > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF2E7D32),
              content: Text('✓ Se enviaron los correos pendientes con éxito ($n)'),
            ),
          );
        });
      }
    }
    final sync = context.read<SyncService>();
    final auth = context.read<AuthService>();
    final usuario = AuthService.usuarioActual;
    final isAdmin = auth.isAdmin || (usuario != null && usuario.isAdmin);
    final isTecnico = !isAdmin && (auth.isTecnico || (usuario != null && usuario.isTecnico));
    final currentIdTecnico = usuario?.id ?? auth.idTecnico;
    final currentNombre = (usuario?.nombre ?? auth.displayName).toLowerCase().trim();

    if (sync.orders.isNotEmpty && mounted) {
      final ordersToShow = isTecnico
          ? sync.orders.where((o) {
              final userNorm = normalizarTexto(currentNombre);
              final idTec = int.tryParse(o['id_tecnico']?.toString() ?? '');
              // ID match takes priority (authoritative)
              if (idTec != null && idTec > 0) {
                if (currentIdTecnico != null && currentIdTecnico > 0) {
                  return idTec == currentIdTecnico;
                }
              }
              // Name-based matching with normalizarTexto
              final bool esMiOrden = normalizarTexto(o['tecnico'] as String? ?? '') == userNorm ||
                                     normalizarTexto(o['tecnico_nombre'] as String? ?? '') == userNorm;
              if (esMiOrden) return true;
              final tec = normalizarTexto(o['tecnico'] as String? ?? o['tecnico_nombre'] as String? ?? '');
              if (tec.isEmpty || userNorm.isEmpty) return false;
              final tp = tec.split(RegExp(r'\s+')); final mp = userNorm.split(RegExp(r'\s+'));
              if (tp.length >= 2 && mp.length >= 2 && tp[0] == mp[0] && tp[1] != mp[1]) return false;
              return tec.contains(userNorm) || userNorm.contains(tec);
            }).toList()
          : sync.orders;

      setState(() {
        _all = List<Map<String, dynamic>>.from(ordersToShow);
        _loading = false;
      });
      _actualizarListasFiltros();
      _applyFilters();
    } else if (sync.state == SyncState.success || sync.state == SyncState.error) {
      _loadLocal();
    }
  }

  Future<void> _loadLocal() async {
    final sync = context.read<SyncService>();
    final auth = context.read<AuthService>();
    final usuario = AuthService.usuarioActual;
    final isAdmin = auth.isAdmin || (usuario != null && usuario.isAdmin);
    final isTecnico = !isAdmin && (auth.isTecnico || (usuario != null && usuario.isTecnico));
    final currentIdTecnico = usuario?.id ?? auth.idTecnico;
    final currentNombre = usuario?.nombre ?? auth.displayName;

    if (isTecnico) {
      await LocalDbService.instance.purgarOrdenesDeOtrosTecnicos(
        currentIdTecnico: currentIdTecnico,
        currentNombre: currentNombre,
        isAdmin: false,
      );
    }
    // Órdenes históricas que quedaron sin tipo de servicio → rellenar (solo vacíos)
    await LocalDbService.instance.parchearTiposServicioConocidos();

    List<Map<String, dynamic>> filterMem(List<Map<String, dynamic>> src) {
      if (!isTecnico) return src;
      final userNorm = normalizarTexto(currentNombre);
      return src.where((o) {
        final idTec = int.tryParse(o['id_tecnico']?.toString() ?? '');
        // ID match takes priority
        if (idTec != null && idTec > 0 && currentIdTecnico != null && currentIdTecnico > 0) {
          return idTec == currentIdTecnico;
        }
        // Name fallback with normalizarTexto
        final bool esMiOrden = normalizarTexto(o['tecnico'] as String? ?? '') == userNorm ||
                               normalizarTexto(o['tecnico_nombre'] as String? ?? '') == userNorm;
        if (esMiOrden) return true;
        final tec = normalizarTexto(o['tecnico'] as String? ?? o['tecnico_nombre'] as String? ?? '');
        if (tec.isEmpty || userNorm.isEmpty) return false;
        final tp = tec.split(RegExp(r'\s+')); final mp = userNorm.split(RegExp(r'\s+'));
        if (tp.length >= 2 && mp.length >= 2 && tp[0] == mp[0] && tp[1] != mp[1]) return false;
        return tec.contains(userNorm) || userNorm.contains(tec);
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
          _actualizarListasFiltros();
          await _applyFilters();
        } else if (memFiltered.isNotEmpty) {
          setState(() { _all = memFiltered.map((m) => Map<String, dynamic>.from(m)).toList(); _loading = false; });
          _actualizarListasFiltros();
          await _applyFilters();
        } else if (_all.isNotEmpty) {
          // Resguardo de base local: no vaciar si ya tenemos datos en memoria
          setState(() { _loading = false; });
          _actualizarListasFiltros();
          await _applyFilters();
        } else {
          setState(() { _all = []; _loading = false; });
          _actualizarListasFiltros();
        }
      }
    } catch (e) {
      debugPrint('[Dashboard] Error en _loadLocal: $e');
      if (mounted) {
        if (memFiltered.isNotEmpty) {
          setState(() { _all = memFiltered.map((m) => Map<String, dynamic>.from(m)).toList(); _loading = false; });
          _actualizarListasFiltros();
          await _applyFilters();
        } else if (_all.isNotEmpty) {
          setState(() { _loading = false; });
          _actualizarListasFiltros();
          await _applyFilters();
        } else {
          setState(() { _all = []; _loading = false; });
          _actualizarListasFiltros();
        }
      }
    }
  }

  Future<void> _applyFilters() async {
    final now = DateTime.now();
    final auth = context.read<AuthService>();
    final usuario = AuthService.usuarioActual;
    final isAdmin = auth.isAdmin || (usuario != null && usuario.isAdmin);
    final isTecnico = !isAdmin && (auth.isTecnico || (usuario != null && usuario.isTecnico));
    final currentIdTecnico = usuario?.id ?? auth.idTecnico;
    final currentNombre = usuario?.nombre ?? auth.displayName;

    final params = _FilterParams(
      all: _all,
      periodo: _periodo,
      modalidad: _modalidad,
      tecnico: _tecnico,
      estado: _estado,
      tipoServicio: _filtroTipoServicio,
      empresa: _filtroEmpresa,
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
    // 1. Archivo físico existente en disco local (con tamaño válido)
    bool fileExiste = false;
    final String? localPath = o['pdf_path_local']?.toString().trim();
    if (localPath != null && localPath.isNotEmpty) {
      try {
        final f = File(localPath);
        fileExiste = f.existsSync() && f.lengthSync() > 500;
      } catch (_) {}
    }
    if (!fileExiste && pdfPath != null && pdfPath.isNotEmpty) {
      try {
        final f = File(pdfPath);
        fileExiste = f.existsSync() && f.lengthSync() > 500;
      } catch (_) {}
    }
    if (!fileExiste && folioStr.isNotEmpty) {
      fileExiste = LocalDbService.instance.checkPdfExistsOnDiskSync(folioStr, localPath ?? pdfPath);
    }
    if (fileExiste) return true;

    // 2. Base64 de PDF válido presente
    final bool hasB64 = (o['pdf_b64_local']?.toString().length ?? 0) > 100 || (o['pdf_base64']?.toString().length ?? 0) > 100;
    if (hasB64) return true;

    // 3. Confirmación explícita del servidor con URL de PDF real y bandera has_pdf
    if (hasPdfFlag && pdfUrl != null && pdfUrl.isNotEmpty && !pdfUrl.contains('null') && !pdfUrl.contains('404')) return true;

    // 4. Captura metrológica completa con firmas guardadas
    final metro = o['metrologia_data'] ?? o['rep_json'] ?? o['exac_json'];
    final bool tieneMetrologia = metro != null &&
        metro.toString().trim().isNotEmpty &&
        metro.toString().trim() != '{}' &&
        metro.toString().trim() != '[]' &&
        metro.toString().trim() != 'null';
    final bool hasFirmas = (o['firma_tecnico']?.toString().length ?? 0) > 20 || (o['firma_cliente']?.toString().length ?? 0) > 20;

    return (tieneMetrologia && hasFirmas);
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

  int get _kpiFisico => _filtered.where((o) => esModalidadFisica(o['modalidad'] as String?)).length;

  List<String> get _tecnicos => _all
      .map((o) => o['tecnico'] as String? ?? '').where((t) => t.isNotEmpty)
      .toSet().toList()..sort();
  List<String> get _estados => _all
      .map((o) => o['estado'] as String? ?? '').where((e) => e.isNotEmpty)
      .toSet().toList()..sort();

  List<_OsGroup> _groupByLote(List<Map<String, dynamic>> list) {
    final Map<String, List<Map<String, dynamic>>> buckets = {};
    for (final os in list) {
      // Criterio primario: id_lote explícito del servidor
      final lote = (os['id_lote'] as String?) ?? (os['lote'] as String?) ?? '';
      String key;
      if (lote.isNotEmpty) {
        key = lote;
      } else {
        // Criterio secundario: agrupar por cliente + fecha de servicio
        // cuando no hay lote asignado en el servidor (ej. Mar Bran multi-báscula)
        final cliente   = (os['cliente'] as String? ?? '').trim();
        final sucursal  = (os['sucursal'] as String? ?? '').trim();
        final fecha     = (os['fecha_servicio'] as String?
            ?? os['fecha_os'] as String?
            ?? os['fecha'] as String?
            ?? '').split('T').first.trim(); // solo la fecha, sin hora
        // Solo agrupamos si hay cliente + fecha válidos (evitar agrupaciones falsas)
        if (cliente.isNotEmpty && fecha.isNotEmpty) {
          key = 'grp_${cliente}_${sucursal}_$fecha';
        } else {
          key = 'solo_${os['folio_os'] ?? os['local_id']}';
        }
      }
      buckets.putIfAbsent(key, () => []).add(os);
    }
    return buckets.entries.map((e) {
      final isLote = !e.key.startsWith('solo_') && e.value.length > 1;
      return _OsGroup(loteKey: e.key, items: e.value, isLote: isLote);
    }).toList();
  }

  // ── Actions Handlers ──────────────────────────────────────────────────────
  /// True si la OS ya fue enviada al servidor (su PDF oficial vive en PostgreSQL).
  static bool _pdfEnServidor(Map<String, dynamic> os) {
    final st = (os['sync_check_status'] ?? '').toString().toUpperCase();
    final est = (os['estatus'] ?? os['estado'] ?? '').toString().toUpperCase();
    final hasPdf = os['has_pdf'] == 1 || os['has_pdf'] == '1' || os['has_pdf'] == true;
    final hasUrl = (os['pdf_url'] ?? '').toString().isNotEmpty;
    return st == 'SUBIDA_SERVIDOR' || st == 'AUDITADA_ADMIN' || st == 'ABIERTO' ||
        st == 'ENVIADA' || st == 'SINCRONIZADO' ||
        est.contains('CERRAD') || est.contains('COMPLET') ||
        hasPdf || hasUrl ||
        os['pdf_subido'] == 1 || os['pdf_subido'] == true;
  }

  /// Invalida la caché local y descarga la versión VIGENTE del PDF del servidor
  /// (p. ej. tras regenerar la firma en backend). Retorna la ruta nueva o null.
  Future<String?> _refrescarPdfDesdeServidor(Map<String, dynamic> os) async {
    final folio = (os['folio_os'] as String? ?? os['folio'] as String? ?? '').trim();
    if (folio.isEmpty || !_pdfEnServidor(os)) return null;
    try {
      final conn = await Connectivity().checkConnectivity();
      if (!conn.any((r) => r != ConnectivityResult.none)) return null;
      final bytes = await ApiService.instance.fetchPdfFresco(folio);
      if (bytes == null) return null;

      // PRESERVACIÓN: NO borrar ni sobreescribir copias locales firmadas.
      // La versión del servidor se guarda en una caché de solo-visualización
      // separada (no registrada en SQLite ni usada para subir/enviar).
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/pdfs_servidor_cache');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final safe = folio.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${cacheDir.path}/$safe.pdf');
      await file.writeAsBytes(bytes, flush: true, mode: FileMode.write);
      debugPrint('[Dashboard] PDF vigente del servidor de $folio → ${file.path} (${bytes.length} B, solo vista)');
      return file.path;
    } catch (e) {
      debugPrint('[Dashboard] No se pudo refrescar PDF de $folio: $e');
      return null;
    }
  }

  Future<void> _abrirPdf(BuildContext context, Map<String, dynamic> os) async {
    final folio = (os['folio_os'] as String? ?? os['folio'] as String? ?? '').trim();
    final ctx = context;
    if (folio.isEmpty) return;

    if (!_OsListScreenState.tieneDocumento(os)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El formato aún no ha sido capturado ni generado en campo.'),
          backgroundColor: Color(0xFFD97706),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    // Si la OS ya está en el servidor, SIEMPRE mostrar la versión vigente
    // (evita abrir una copia local estancada con firma antigua).
    String? pathToOpen = await _refrescarPdfDesdeServidor(os);

    final memPath = (os['pdf_path_local'] as String? ?? '').trim();
    if (pathToOpen == null && memPath.isNotEmpty && File(memPath).existsSync() && File(memPath).lengthSync() > 500) {
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
      if (e.toString().contains('404')) {
        final sqldb = await LocalDbService.instance.database;
        await sqldb.update(
          'ordenes_servicio',
          {
            'has_pdf': 0,
            'estatus': 'Asignada',
            'estado': 'PROCESO',
            'sync_status': 'Pendiente',
            'sync_check_status': 'ASIGNADA',
            'pdf_url': null,
          },
          where: 'folio_os = ? OR folio = ?',
          whereArgs: [folio, folio],
        );
        try {
          os['has_pdf'] = 0;
          os['estatus'] = 'Asignada';
          os['estado'] = 'PROCESO';
          os['sync_status'] = 'Pendiente';
          os['sync_check_status'] = 'ASIGNADA';
          os['pdf_url'] = null;
        } catch (_) {}
        if (mounted) await _loadLocal();
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(
              backgroundColor: Colors.orange.shade800,
              content: Text('La orden $folio no tiene formato generado en el servidor. Se habilitó para captura.'),
              duration: const Duration(seconds: 4),
            ),
          );
        }
        return;
      }
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

    if (!_OsListScreenState.tieneDocumento(os)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El formato aún no ha sido capturado ni generado en campo.'),
          backgroundColor: Color(0xFFD97706),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    // Borrar la copia vieja y bajar la vigente del servidor antes de exportar
    final fresco = await _refrescarPdfDesdeServidor(os);
    if (!context.mounted) return;

    String? sourcePath = fresco ?? os['pdf_path_local'] as String?;
    if (sourcePath == null || sourcePath.isEmpty || !File(sourcePath).existsSync() || File(sourcePath).lengthSync() < 100) {
      try {
        final downloaded = await ApiService.instance.downloadPdf(
          '/api/v1/ordenes/$folio/download-pdf',
          targetFileName: '$folio.pdf',
        );
        if (File(downloaded).existsSync() && File(downloaded).lengthSync() > 100) {
          sourcePath = downloaded;
          await LocalDbService.instance.updatePdfPathLocal(folio, downloaded);
          os['pdf_path_local'] = downloaded;
        }
      } catch (e) {
        if (e.toString().contains('404')) {
          final sqldb = await LocalDbService.instance.database;
          await sqldb.update(
            'ordenes_servicio',
            {
              'has_pdf': 0,
              'estatus': 'Asignada',
              'estado': 'PROCESO',
              'sync_status': 'Pendiente',
              'sync_check_status': 'ASIGNADA',
              'pdf_url': null,
            },
            where: 'folio_os = ? OR folio = ?',
            whereArgs: [folio, folio],
          );
          try {
            os['has_pdf'] = 0;
            os['estatus'] = 'Asignada';
            os['estado'] = 'PROCESO';
            os['sync_status'] = 'Pendiente';
            os['sync_check_status'] = 'ASIGNADA';
            os['pdf_url'] = null;
          } catch (_) {}
          if (mounted) await _loadLocal();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.orange.shade800,
                content: Text('La orden $folio no tiene formato generado en el servidor. Se habilitó para captura.'),
                duration: const Duration(seconds: 4),
              ),
            );
          }
          return;
        }
      }
    }

    if (sourcePath == null || sourcePath.isEmpty || !File(sourcePath).existsSync() || File(sourcePath).lengthSync() < 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El formato aún no ha sido capturado ni generado en campo.'),
          backgroundColor: Color(0xFFD97706),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    await PdfStorageService.instance.exportToDownloads(
      folio: folio,
      cliente: (os['cliente'] ?? os['razon_social'] ?? os['cliente_nombre'])?.toString(),
      idIndicador: (os['id_indicador'] ?? os['id_instrumento'] ?? os['no_serie'])?.toString(),
      tipoServicio: (os['tipo_servicio'] ?? os['servicio'])?.toString(),
      osData: os,
      sourcePdfPath: sourcePath,
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
            onPressed: () async {
              Navigator.of(dialogCtx).pop();
              // Eliminar la copia vieja estancada del PDF (el Base64 en SQLite
              // queda como respaldo hasta que se genere el nuevo).
              await LocalDbService.instance.invalidarPdfLocal(
                folio, pathExtra: os['pdf_path_local']?.toString());
              final editOs = Map<String, dynamic>.from(os);
              editOs['estado'] = 'Proceso';
              editOs.remove('pdf_path_local');
              try { os['estado'] = 'Proceso'; os.remove('pdf_path_local'); } catch (_) {}
              if (!context.mounted) return;
              navegarCapturaSegunTipo(context, editOs);
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

  /// Función universal de captura y envío de correo para órdenes individuales y lotes
  Future<void> _procesarEnvioCorreo({required dynamic item, required bool esLote}) async {
    if (_estaEnviandoEmail) {
      debugPrint('[ENVIO CORREO] Clic ignorado: despacho de correo en progreso.');
      return;
    }
    try {
      await _procesarEnvioCorreoImpl(item: item, esLote: esLote);
    } catch (e, st) {
      debugPrint('[ENVIO CORREO] Error no controlado: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFFD97706),
            content: Text('No se pudo procesar el envío de correo: $e'),
          ),
        );
      }
    }
  }

  Future<void> _procesarEnvioCorreoImpl({required dynamic item, required bool esLote}) async {
    List<Map<String, dynamic>> items = [];
    String loteId = '';
    String folio = '';

    String folioDe(dynamic m) {
      if (m is Map) {
        return ((m['folio_os'] ?? m['folio'])?.toString() ?? '').trim();
      }
      return m?.toString().trim() ?? '';
    }

    if (esLote) {
      if (item is _OsGroup) {
        items = item.items.map((m) => Map<String, dynamic>.from(m)).toList();
        final rawLote = items.isNotEmpty
            ? (items.first['id_lote'] ?? items.first['lote'])?.toString().trim()
            : null;
        if (rawLote != null && rawLote.isNotEmpty) {
          loteId = rawLote;
        } else if (item.loteKey.isNotEmpty && !item.loteKey.startsWith('solo_')) {
          loteId = item.loteKey;
        }
      } else if (item is Map) {
        final itemMap = Map<String, dynamic>.from(item);
        final rawLote = (itemMap['id_lote'] ?? itemMap['lote'] ?? itemMap['id'] ?? itemMap['lote_id'])?.toString().trim();
        if (rawLote != null && rawLote.isNotEmpty) {
          loteId = rawLote;
        }
        if (itemMap['ordenes'] is List) {
          items = (itemMap['ordenes'] as List)
              .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{'folio': e.toString()})
              .toList();
        } else if (itemMap['hijos'] is List) {
          items = (itemMap['hijos'] as List)
              .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{'folio': e.toString()})
              .toList();
        } else if (itemMap['items'] is List) {
          items = (itemMap['items'] as List)
              .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{'folio': e.toString()})
              .toList();
        }
        if (items.isEmpty && loteId.isNotEmpty) {
          items = _filtered
              .where((o) => (o['id_lote'] ?? o['lote'])?.toString().trim() == loteId)
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }
      }

      List<String> folios = items.map(folioDe).where((f) => f.isNotEmpty).toList();

      // Búsqueda de respaldo en SQLite si folios viene vacío
      if (folios.isEmpty) {
        final cliente = (item is Map
            ? (item['cliente'] ?? '')
            : (item is _OsGroup && item.items.isNotEmpty ? item.items.first['cliente'] : ''))?.toString().trim() ?? '';
        final fecha = (item is Map
            ? (item['fecha_servicio'] ?? item['fecha_os'] ?? item['fecha'] ?? '')
            : (item is _OsGroup && item.items.isNotEmpty
                ? (item.items.first['fecha_servicio'] ?? item.items.first['fecha_os'] ?? item.items.first['fecha'] ?? '')
                : ''))?.toString().split('T').first.trim() ?? '';
        final sqlRows = await LocalDbService.instance.obtenerFoliosPorLoteOCliente(
          loteId: loteId,
          cliente: cliente,
          fecha: fecha,
        );
        if (sqlRows.isNotEmpty) {
          items = sqlRows.map((m) => Map<String, dynamic>.from(m)).toList();
          folios = items.map(folioDe).where((f) => f.isNotEmpty).toList();
        }
      }

      if (loteId.isEmpty && folios.isNotEmpty) {
        loteId = 'LOTE-${folios.first}';
      }
      folio = loteId;

      if (folios.isEmpty && items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo identificar el lote (sin id de lote u órdenes).')),
          );
        }
        return;
      }
    } else {
      final Map<String, dynamic> osMap;
      if (item is Map) {
        osMap = Map<String, dynamic>.from(item);
      } else if (item is _OsGroup && item.items.isNotEmpty) {
        osMap = Map<String, dynamic>.from(item.items.first);
      } else {
        return;
      }
      items = [Map<String, dynamic>.from(osMap)];
      folio = ((osMap['folio_os'] ?? osMap['folio']) as String? ?? '').trim();
      loteId = '';
      if (folio.isEmpty) return;
    }

    // REGLA ESTRICTA DE LOTES: solo órdenes terminadas (firmadas/cerradas) con PDF existente.
    // Las OS pendientes o sin formato del lote se ignoran por completo (ni se citan ni se adjuntan).
    final List<Map<String, dynamic>> itemsBase =
        esLote ? await _hijasLoteDesdeSqlite(loteId, items) : items;
    final vistosFoliosEnvio = <String>{};
    final List<Map<String, dynamic>> itemsEnvio = [];
    for (final o in (esLote ? itemsBase.where((o) => tieneDocumento(o)) : itemsBase)) {
      final f = folioDe(o);
      if (f.isNotEmpty && vistosFoliosEnvio.add(f)) {
        itemsEnvio.add(o);
      }
    }
    final int omitidas = itemsBase.map(folioDe).where((f) => f.isNotEmpty).toSet().length - itemsEnvio.length;
    final List<String> foliosEnvio = itemsEnvio.map(folioDe).where((f) => f.isNotEmpty).toList();

    if (esLote && itemsEnvio.isEmpty) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 26),
                SizedBox(width: 10),
                Expanded(child: Text('Lote sin órdenes listas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              ],
            ),
            content: Text(
              'Ninguna orden de este lote está completada con PDF para enviar.\n\n'
              'Órdenes en el lote: ${itemsBase.length}',
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Entendido')),
            ],
          ),
        );
      }
      return;
    }

    final bool yaEnviado = itemsEnvio.isNotEmpty &&
        itemsEnvio.any((o) =>
            o['email_enviado'] == 1 || o['email_enviado'] == true || o['email_enviado'] == '1' || o['email_enviado'] == 'true');

    // 1. Obtener correo registrado si existe
    String correoActual = '';
    for (final it in itemsEnvio) {
      final c = (it['correo_cliente'] ?? '').toString().trim();
      if (c.isNotEmpty &&
          c.toLowerCase() != 'ivancolin1207@gmail.com' &&
          c.toLowerCase() != 'sin registrar' &&
          c.toLowerCase() != 'none' &&
          c.toLowerCase() != 'null') {
        correoActual = c;
        break;
      }
    }

    // Modal de captura si falta correo o para confirmar/editar destinatario
    final formKey = GlobalKey<FormState>();
    final emailCtrl = TextEditingController(text: correoActual);
    bool isSendingModal = false;

    // Encolado offline en SQLite (email_status = 'cola')
    Future<void> encolarLocal(String motivo, String destino) async {
      debugPrint('[ENVIO CORREO] Encolando localmente (${esLote ? 'lote $loteId' : folio}): $motivo');
      await LocalDbService.instance.encolarCorreo(
        tipo: esLote ? 'lote' : 'orden',
        referencia: esLote ? (foliosEnvio.isNotEmpty ? 'LOTE-${foliosEnvio.first}' : loteId) : folio,
        correo: destino,
        folios: foliosEnvio,
      );
      for (final it in itemsEnvio) {
        final f = folioDe(it);
        if (f.isEmpty) continue;
        await LocalDbService.instance.updateEmailStatus(f, enviado: false, status: 'cola', correo: destino);
        if (mounted) {
          context.read<SyncService>().updateLocalOrder(f, {
            'email_enviado': 0,
            'email_status': 'cola',
            'correo_cliente': destino,
          });
        }
      }
      if (mounted) {
        final foliosSet = foliosEnvio.toSet();
        setState(() {
          _all = _all.map((m) {
            final f = folioDe(m);
            if (foliosSet.contains(f) || (esLote && (m['id_lote'] ?? m['lote'])?.toString().trim() == loteId)) {
              return {...m, 'email_enviado': 0, 'email_status': 'cola', 'correo_cliente': destino};
            }
            return m;
          }).toList();
          _filtered = _filtered.map((m) {
            final f = folioDe(m);
            if (foliosSet.contains(f) || (esLote && (m['id_lote'] ?? m['lote'])?.toString().trim() == loteId)) {
              return {...m, 'email_enviado': 0, 'email_status': 'cola', 'correo_cliente': destino};
            }
            return m;
          }).toList();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFFD97706),
            content: Text('⏳ Guardado en cola offline. Se enviará al sincronizar con internet.'),
          ),
        );
        await _loadLocal();
      }
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: !isSendingModal,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return PopScope(
            canPop: !isSendingModal,
            child: AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(
                    yaEnviado ? Icons.mark_email_read_rounded : Icons.mail_outline_rounded,
                    color: const Color(0xFFB81D24),
                    size: 26,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      esLote
                          ? (yaEnviado ? 'Reenviar Lote por Correo' : 'Enviar Lote por Correo')
                          : (yaEnviado ? 'Reenviar por Correo — $folio' : 'Enviar por Correo — $folio'),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (esLote) ...[
                      Text(
                        'Se enviará un SOLO correo con ${itemsEnvio.length} reporte(s) PDF firmado(s): ${foliosEnvio.join(', ')}.'
                        '${omitidas > 0 ? '\n$omitidas orden(es) del lote sin realizar se omitirán del correo.' : ''}',
                        style: const TextStyle(fontSize: 13, height: 1.4),
                      ),
                      const SizedBox(height: 6),
                    ],
                    const Text(
                      'Se enviará desde ivancolin1207@gmail.com con CC obligatoria a recepcion@basculaspesa.com.mx',
                      style: TextStyle(fontSize: 12, color: Color(0xFF4B5563), height: 1.35),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      enabled: !isSendingModal,
                      autofocus: true,
                      validator: (val) {
                        final v = (val ?? '').trim();
                        if (v.isEmpty) return 'Ingresa el correo del cliente';
                        if (!v.contains('@') || !v.contains('.')) return 'Correo electrónico inválido';
                        if (v.toLowerCase() == 'ivancolin1207@gmail.com') {
                          return 'ivancolin1207@gmail.com es el remitente. Ingresa el correo del cliente.';
                        }
                        return null;
                      },
                      decoration: InputDecoration(
                        labelText: 'Correo del Cliente',
                        hintText: 'cliente@empresa.com',
                        prefixIcon: const Icon(Icons.alternate_email, color: Color(0xFFB81D24)),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSendingModal ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB81D24),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: isSendingModal
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(yaEnviado ? Icons.mark_email_read_rounded : Icons.send, size: 16),
                  label: Text(
                    isSendingModal
                        ? 'Enviando...'
                        : (yaEnviado
                            ? (esLote ? 'Reenviar Lote' : 'Reenviar Correo')
                            : (esLote ? 'Finalizar y Enviar Lote' : 'Enviar Ahora')),
                  ),
                  onPressed: isSendingModal
                      ? null
                      : () async {
                          if (!(formKey.currentState?.validate() ?? true)) return;
                          final destino = emailCtrl.text.trim();

                          if (esLote) {
                            final totalValidas = foliosEnvio.length;
                            final bool? confirmar = await showDialog<bool>(
                              context: ctx,
                              barrierDismissible: false,
                              builder: (cCtx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                title: const Row(
                                  children: [
                                    Icon(Icons.mark_email_read_rounded, color: Color(0xFFB81D24), size: 24),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Confirmar Envío de Lote',
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                                content: Text(
                                  'Se enviarán $totalValidas órdenes de servicio al correo $destino con copia a recepcion@basculaspesa.com.mx, ¿desea continuar?',
                                  style: const TextStyle(fontSize: 13, height: 1.4),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(cCtx).pop(false),
                                    child: const Text('Cancelar'),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFB81D24),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    onPressed: () => Navigator.of(cCtx).pop(true),
                                    child: const Text('Confirmar y Enviar'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmar != true) return;
                          }

                          setModalState(() => isSendingModal = true);
                          setState(() => _estaEnviandoEmail = true);

                          try {
                            // Marcar en SQLite email_status = 'enviando' inmediatamente
                            for (final f in foliosEnvio) {
                              await LocalDbService.instance.updateEmailStatus(f, enviado: false, status: 'enviando', correo: destino);
                            }

                            // Verificar conectividad a internet
                            final connResults = await Connectivity().checkConnectivity();
                            final isOnline = connResults.any((r) => r != ConnectivityResult.none);
                            if (!isOnline) {
                              if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                              await encolarLocal('sin conectividad', destino);
                              return;
                            }

                            if (esLote) {
                              // Un SOLO correo con la versión FINAL de cada documento del lote
                              await context.read<SyncService>().asegurarPdfsVigentesEnServidor(foliosEnvio);
                            }

                            final Map<String, dynamic> res = esLote
                                ? await ApiService.instance.enviarEmailLote(loteId, correo: destino, forzar: true, folios: foliosEnvio, timeout: const Duration(seconds: 20))
                                : await ApiService.instance.enviarEmailOrden(folio, correo: destino, forzar: true, timeout: const Duration(seconds: 20));

                            // Cerrar modal SIEMPRE al terminar
                            if (Navigator.of(ctx).canPop()) {
                              Navigator.of(ctx).pop();
                            }

                            final bool exitoEnvio = res['ok'] == true || res['status'] == 'already_sent';
                            if (!exitoEnvio) {
                              throw CorreoRechazadoException((res['motivo'] ?? res['error'] ?? 'Error desconocido').toString());
                            }

                            final List<String> confirmados = (res['folios'] is List && (res['folios'] as List).isNotEmpty)
                                ? (res['folios'] as List).map((e) => e.toString()).toSet().toList()
                                : foliosEnvio.toSet().toList();

                            final nowStr = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());

                            for (final f in confirmados) {
                              await LocalDbService.instance.actualizarEnvioCorreo(
                                folio: f,
                                enviado: 1,
                                fechaEnvio: nowStr,
                                correos: destino,
                              );
                              if (mounted) {
                                context.read<SyncService>().updateLocalOrder(f, {
                                  'email_enviado': 1,
                                  'email_status': 'enviado',
                                  'fecha_envio_email': nowStr,
                                  'correo_cliente': destino,
                                });
                              }
                            }

                            if (mounted) {
                              final confirmadosSet = confirmados.toSet();
                              setState(() {
                                _all = _all.map((m) {
                                  final f = folioDe(m);
                                  if (confirmadosSet.contains(f) || (esLote && (m['id_lote'] ?? m['lote'])?.toString().trim() == loteId)) {
                                    return {...m, 'email_enviado': 1, 'email_status': 'enviado', 'fecha_envio_email': nowStr, 'correo_cliente': destino};
                                  }
                                  return m;
                                }).toList();
                                _filtered = _filtered.map((m) {
                                  final f = folioDe(m);
                                  if (confirmadosSet.contains(f) || (esLote && (m['id_lote'] ?? m['lote'])?.toString().trim() == loteId)) {
                                    return {...m, 'email_enviado': 1, 'email_status': 'enviado', 'fecha_envio_email': nowStr, 'correo_cliente': destino};
                                  }
                                  return m;
                                }).toList();
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: const Color(0xFF2E7D32),
                                  content: Text('✓ Correo enviado con éxito a $destino' + (esLote ? ' (${confirmados.length} órdenes en lote)' : '')),
                                ),
                              );
                              await _loadLocal();
                            }
                          } on TimeoutException {
                            if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                            for (final f in foliosEnvio) {
                              await LocalDbService.instance.updateEmailStatus(f, enviado: false, status: 'cola', correo: destino);
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Tiempo de espera agotado con el servidor al enviar correo (20s).'),
                                  backgroundColor: Colors.deepOrange,
                                ),
                              );
                            }
                          } on CorreoSinConexionException catch (e) {
                            if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                            await encolarLocal(e.mensaje, destino);
                          } on CorreoEndpointNoDisponibleException catch (e) {
                            if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                            await encolarLocal(e.mensaje, destino);
                          } on CorreoRechazadoException catch (e) {
                            if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                            for (final f in foliosEnvio) {
                              await LocalDbService.instance.updateEmailStatus(f, enviado: false, status: 'cola', correo: destino);
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: Colors.redAccent,
                                  content: Text('Error al enviar: ${e.mensaje}'),
                                ),
                              );
                            }
                          } catch (e) {
                            if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                            for (final f in foliosEnvio) {
                              await LocalDbService.instance.updateEmailStatus(f, enviado: false, status: 'cola', correo: destino);
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Tiempo de espera agotado o error de red: $e'),
                                  backgroundColor: Colors.deepOrange,
                                ),
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(() => _estaEnviandoEmail = false);
                            } else {
                              _estaEnviandoEmail = false;
                            }
                          }
                        },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Órdenes hijas del lote leídas de SQLite local (PDF/estatus frescos), fusionadas con memoria.
  Future<List<Map<String, dynamic>>> _hijasLoteDesdeSqlite(
      String loteId, List<Map<String, dynamic>> enMemoria) async {
    String fol(Map m) => ((m['folio_os'] ?? m['folio'])?.toString() ?? '').trim();
    try {
      final db = await LocalDbService.instance.database;
      final foliosEnMemoria = enMemoria.map(fol).where((f) => f.isNotEmpty).toList();
      final List<Map<String, dynamic>> rows;
      if (loteId.isNotEmpty && !loteId.startsWith('grp_') && !loteId.startsWith('LOTE-') && !loteId.startsWith('solo_')) {
        rows = await db.query('ordenes_servicio', where: 'id_lote = ? OR lote = ?', whereArgs: [loteId, loteId]);
      } else if (foliosEnMemoria.isNotEmpty) {
        final qMarks = List.filled(foliosEnMemoria.length, '?').join(',');
        rows = await db.query('ordenes_servicio',
            where: 'folio_os IN ($qMarks) OR folio IN ($qMarks)',
            whereArgs: [...foliosEnMemoria, ...foliosEnMemoria]);
      } else {
        rows = [];
      }
      if (rows.isEmpty) return enMemoria.map((m) => Map<String, dynamic>.from(m)).toList();
      final porFolio = <String, Map<String, dynamic>>{for (final m in enMemoria) fol(m): Map<String, dynamic>.from(m)};
      final vistos = <String>{};
      final out = <Map<String, dynamic>>[];
      for (final r in rows) {
        final f = fol(r);
        if (f.isEmpty || !vistos.add(f)) continue;
        final merged = <String, dynamic>{...?porFolio[f]};
        r.forEach((k, v) {
          if (v != null && v.toString().isNotEmpty) merged[k] = v;
        });
        out.add(Map<String, dynamic>.from(merged));
      }
      for (final m in enMemoria) {
        final f = fol(m);
        if (f.isNotEmpty && !vistos.contains(f)) out.add(Map<String, dynamic>.from(m));
      }
      debugPrint('[ENVIO CORREO] Lote $loteId: ${out.length} órdenes hijas (SQLite: ${rows.length})');
      return out;
    } catch (e) {
      debugPrint('[ENVIO CORREO] No se pudieron leer hijas del lote $loteId en SQLite: $e');
      return enMemoria.map((m) => Map<String, dynamic>.from(m)).toList();
    }
  }

  Future<void> _manejarAccionEmail(BuildContext context, Map<String, dynamic> os) =>
      _procesarEnvioCorreo(item: Map<String, dynamic>.from(os), esLote: false);

  Future<void> _manejarEnvioCorreoOrden(Map<String, dynamic> orden) =>
      _procesarEnvioCorreo(item: Map<String, dynamic>.from(orden), esLote: false);

  Future<void> _manejarEnvioCorreoLote(dynamic lote) =>
      _procesarEnvioCorreo(item: (lote is Map) ? Map<String, dynamic>.from(lote) : lote, esLote: true);

  @override
  Widget build(BuildContext context) {
    final sync        = context.watch<SyncService>();
    final auth        = context.watch<AuthService>();
    final hideTecnico = auth.isTecnico;

    final dashboard = LayoutBuilder(
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
    );

    final u = AuthService.usuarioActual;
    final String rol = (auth.role ?? u?.rol ?? '').toString().toLowerCase();
    final String nombre = (auth.displayName.isNotEmpty ? auth.displayName : (u?.nombre ?? '')).toString().toLowerCase();
    final String user = (auth.username ?? u?.username ?? '').toString().toLowerCase();
    final bool puedeVerRepositorio = rol == 'admin' ||
        rol == 'administrador' ||
        auth.isAdmin ||
        auth.esSupervisorCalibracion ||
        nombre.contains('alan guevara') ||
        nombre.contains('ivan colin') ||
        nombre.contains('iván colín') ||
        user == 'ivancolin1207' ||
        user == 'daikki19';

    if (!puedeVerRepositorio && _vistaRepositorio) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _vistaRepositorio = false);
      });
    }
    final repoActivo = puedeVerRepositorio && _vistaRepositorio;

    final content = Scaffold(
      backgroundColor: _kBgColor,
      body: SafeArea(
        bottom: false,
        child: !puedeVerRepositorio
            ? dashboard
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _selectorVista(repoActivo),
                  Expanded(
                    child: repoActivo
                        ? const CalibracionesRepositorioView()
                        : dashboard,
                  ),
                ],
              ),
      ),
    );
    return AppShell(currentRoute: '/os', child: content);
  }

  Widget _selectorVista(bool repoActivo) {
    const metro = Color(0xFF5B3FD6);
    return LayoutBuilder(builder: (context, c) {
      final compacto = c.maxWidth < 650;
      return Container(
        padding: EdgeInsets.fromLTRB(compacto ? 12 : 24, 10, compacto ? 12 : 24, 4),
        child: Align(
          alignment: compacto ? Alignment.center : Alignment.centerLeft,
          child: SegmentedButton<bool>(
            key: const Key('os_vista_selector'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment<bool>(
                value: false,
                icon: const Text('📋'),
                label: Text(compacto ? 'Mis Órdenes' : 'Mis Órdenes Asignadas'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: const Text('📑'),
                label: Text(compacto ? 'Calibraciones' : 'Repositorio Calibraciones (Todos)'),
              ),
            ],
            selected: {repoActivo},
            onSelectionChanged: (s) => setState(() => _vistaRepositorio = s.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: const WidgetStatePropertyAll(
                TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (!states.contains(WidgetState.selected)) return Colors.white;
                return repoActivo ? metro : _kCarmineRed;
              }),
              foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected) ? Colors.white : _kTextPrim),
              side: WidgetStatePropertyAll(
                BorderSide(color: repoActivo ? metro : _kBorder),
              ),
            ),
          ),
        ),
      );
    });
  }
}

// ── Filter Isolate Model & Logic ───────────────────────────────────────────
class _FilterParams {
  final List<Map<String, dynamic>> all;
  final String periodo;
  final String modalidad;
  final String? tecnico;
  final String? estado;
  final String tipoServicio;
  final String empresa;
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
    this.tipoServicio = 'Todos los Servicios',
    this.empresa = 'Todas las Empresas',
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

  // Pre-computar IDs de lotes que coinciden con los filtros de Tipo de Servicio y Empresa
  final matchingLoteIds = <String>{};
  final bool filtrarTipo = p.tipoServicio.isNotEmpty && p.tipoServicio != 'Todos los Servicios';
  final bool filtrarEmpresa = p.empresa.isNotEmpty && p.empresa != 'Todas las Empresas';

  if (filtrarTipo || filtrarEmpresa) {
    for (final os in p.all) {
      String lid = (os['id_lote'] ?? os['lote'])?.toString().trim() ?? '';
      if (lid.isEmpty) {
        final c = (os['cliente'] as String? ?? '').trim();
        final s = (os['sucursal'] as String? ?? '').trim();
        final f = (os['fecha_servicio'] as String? ?? os['fecha_os'] as String? ?? os['fecha'] as String? ?? '').split('T').first.trim();
        if (c.isNotEmpty && f.isNotEmpty) {
          lid = 'grp_${c}_${s}_$f';
        }
      }
      if (lid.isEmpty) continue;
      final matchServicio = !filtrarTipo ||
          (os['tipo_servicio']?.toString().trim().toLowerCase() == p.tipoServicio.trim().toLowerCase());
      final matchEmpresa = !filtrarEmpresa ||
          (os['cliente']?.toString().trim().toLowerCase() == p.empresa.trim().toLowerCase());
      if (matchServicio && matchEmpresa) {
        matchingLoteIds.add(lid);
      }
    }
  }

  final filtered = p.all.where((os) {
    // 1. REGLA ESTRICTA DE AISLAMIENTO POR TÉCNICO:
    // No mostrar bajo ninguna circunstancia órdenes de otros técnicos en la vista del técnico
    if (p.isTecnico) {
      final userNorm = normalizarTexto(p.currentTecnicoNombre);
      final idTec = int.tryParse(os['id_tecnico']?.toString() ?? '');
      final myId  = p.currentTecnicoId;

      // ── Caso A: La orden tiene id_tecnico válido ──────────────────────────
      if (idTec != null && idTec > 0) {
        if (myId != null && myId > 0) {
          // Ambos IDs conocidos: comparación directa, SIN fallback a nombre.
          // Si los IDs difieren → excluir siempre.
          if (idTec != myId) return false;
          // IDs iguales → incluir; ir directo a los demás filtros.
        } else if (userNorm.isNotEmpty) {
          // No tenemos ID de usuario en sesión → comparar por nombre normalizado
          final bool esMiOrden = normalizarTexto(os['tecnico'] as String? ?? '') == userNorm ||
                                 normalizarTexto(os['tecnico_nombre'] as String? ?? '') == userNorm;
          if (!esMiOrden) {
            final tecNorm = normalizarTexto(os['tecnico'] as String? ?? os['tecnico_nombre'] as String? ?? '');
            if (tecNorm.isEmpty) return true;
            final tecParts = tecNorm.split(RegExp(r'\s+'));
            final myParts  = userNorm.split(RegExp(r'\s+'));
            // Mismo primer nombre pero apellido diferente → personas distintas
            if (tecParts.length >= 2 && myParts.length >= 2 &&
                tecParts[0] == myParts[0] && tecParts[1] != myParts[1]) return false;
            if (!tecNorm.contains(userNorm) && !userNorm.contains(tecNorm)) return false;
          }
        }
      } else {
        // ── Caso B: Orden sin id_tecnico (formatos físicos o legacy) ─────────
        if (userNorm.isNotEmpty) {
          final bool esMiOrden = normalizarTexto(os['tecnico'] as String? ?? '') == userNorm ||
                                 normalizarTexto(os['tecnico_nombre'] as String? ?? '') == userNorm;
          if (!esMiOrden) {
            final tecNorm = normalizarTexto(os['tecnico'] as String? ?? os['tecnico_nombre'] as String? ?? '');
            // Sin técnico asignado → excluir para evitar fugas entre técnicos
            if (tecNorm.isEmpty) return false;
            final tecParts = tecNorm.split(RegExp(r'\s+'));
            final myParts  = userNorm.split(RegExp(r'\s+'));
            // Mismo primer nombre pero apellido diferente → personas distintas → excluir
            if (tecParts.length >= 2 && myParts.length >= 2 &&
                tecParts[0] == myParts[0] && tecParts[1] != myParts[1]) return false;
            // Verificación por nombre completo
            if (!tecNorm.contains(userNorm) && !userNorm.contains(tecNorm)) return false;
          }
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
      final isFisico = esModalidadFisica(os['modalidad'] as String?);
      if (p.modalidad == 'Solo Físicos' && !isFisico) return false;
      if (p.modalidad == 'Solo Digitales' && isFisico) return false;
    }

    if (p.tecnico != null && p.tecnico!.isNotEmpty) {
      final tecFilter = normalizarTexto(p.tecnico!);
      final tecVal = normalizarTexto(os['tecnico'] as String? ?? os['tecnico_nombre'] as String? ?? '');
      if (!tecVal.contains(tecFilter)) return false;
    }

    if (p.estado != null && p.estado!.isNotEmpty &&
        (os['estado'] as String? ?? '') != p.estado) return false;

    // 3. Filtros por Tipo de Servicio y Empresa / Cliente (con soporte de Lotes)
    String lid = (os['id_lote'] ?? os['lote'])?.toString().trim() ?? '';
    if (lid.isEmpty) {
      final c = (os['cliente'] as String? ?? '').trim();
      final s = (os['sucursal'] as String? ?? '').trim();
      final f = (os['fecha_servicio'] as String? ?? os['fecha_os'] as String? ?? os['fecha'] as String? ?? '').split('T').first.trim();
      if (c.isNotEmpty && f.isNotEmpty) {
        lid = 'grp_${c}_${s}_$f';
      }
    }
    final perteneceALoteCoincidente = lid.isNotEmpty && matchingLoteIds.contains(lid);

    if (!perteneceALoteCoincidente) {
      if (filtrarTipo &&
          (os['tipo_servicio']?.toString().trim().toLowerCase() != p.tipoServicio.trim().toLowerCase())) {
        return false;
      }
      if (filtrarEmpresa &&
          (os['cliente']?.toString().trim().toLowerCase() != p.empresa.trim().toLowerCase())) {
        return false;
      }
    }

    if (p.query.isNotEmpty) {
      final q = normalizarTexto(p.query);
      final ok = ['folio_os', 'cliente', 'sucursal', 'tecnico', 'tipo_servicio', 'id_lote', 'lote']
          .any((k) => normalizarTexto(os[k]?.toString() ?? '').contains(q));
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
              GestureDetector(
                onLongPress: () => state._mostrarMenuSincronizacion(context),
                child: IconButton(
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
                  tooltip: sync.state == SyncState.syncing ? 'Toca para cancelar' : 'Sincronizar (mantén presionado para opciones)',
                ),
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
                    const SizedBox(width: 6),
                    _buildMobileChipDropdown(
                      label: state._filtroTipoServicio,
                      items: state._listaTiposServicio,
                      onSelected: (val) {
                        state.setState(() => state._filtroTipoServicio = val);
                        state._applyFilters();
                      },
                    ),
                    const SizedBox(width: 6),
                    _buildMobileChipDropdown(
                      label: state._filtroEmpresa,
                      items: state._listaEmpresas,
                      onSelected: (val) {
                        state.setState(() => state._filtroEmpresa = val);
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
            onCaptura: (os) => navegarCapturaSegunTipo(ctx, Map<String, dynamic>.from(os)),
          );
        }
        final os = group.items.first;
        return _MobileOsCard(
          os: os,
          onCaptura: () => navegarCapturaSegunTipo(ctx, Map<String, dynamic>.from(os)),
          onAbrirPdf: state._abrirPdf,
          onDescargarPdf: state._descargarPdfConNomenclatura,
          onRehacer: state._mostrarDialogoRehacerToma,
          onEliminarDatos: state._mostrarDialogoEliminarDatosDesdeCero,
          onSubirPdfManual: state._subirPdfManual,
          onEmail: state._manejarAccionEmail,
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
  final Function(BuildContext, Map<String, dynamic>) onEmail;

  const _MobileOsCard({
    required this.os,
    required this.onCaptura,
    required this.onAbrirPdf,
    required this.onDescargarPdf,
    required this.onRehacer,
    required this.onEliminarDatos,
    required this.onSubirPdfManual,
    required this.onEmail,
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
    final bool isFisico = esModalidadFisica(os['modalidad'] as String?);

    final String estatusRemoto = (os['estatus'] ?? os['estado'] ?? '').toString().trim();
    final bool isCerrado = pdfReal;

    final String estatusLabel = isCerrado
        ? (estatusRemoto.isNotEmpty && !estatusRemoto.toLowerCase().contains('sin formato') && !estatusRemoto.toLowerCase().contains('asignada') ? estatusRemoto : 'Cerrado')
        : (noIniciada ? '⚠️ Sin Formato' : 'Pendiente');
    final Color estatusFg = isCerrado
        ? const Color(0xFF2E7D32)
        : (noIniciada ? const Color(0xFFD97706) : const Color(0xFF2563EB));
    final Color estatusBg = isCerrado
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
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
            ),
            child: Text(
              '👤 Técnico: ${os['tecnico_nombre'] ?? os['tecnico'] ?? 'Sin asignar'}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 8),

          // Fila de Metadatos (Wrap: se reacomoda en Fold doblado sin recortes)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
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
              EmailStatusBadge(
                enviado: estadoCorreoOs(os) == 'enviado',
                enCola: estadoCorreoOs(os) == 'cola',
                correo: (os['correo_cliente'] ?? '').toString(),
                onTap: () => onEmail(context, os),
              ),
              const SizedBox(width: 6),
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
          if (isCerrado) ...[
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
                    child: Builder(
                      builder: (context) {
                        final item = os;
                        final String estCorreo = estadoCorreoOs(item);
                        final bool correoEnviado = estCorreo == 'enviado';
                        final bool enCola = estCorreo == 'cola';
                        final st = context.findAncestorStateOfType<_OsListScreenState>();
                        final bool enviando = st != null && st._estaEnviandoEmail;
                        return ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: enviando
                                ? const Color(0xFFE0E0E0)
                                : (correoEnviado ? const Color(0xFF2E7D32) : (enCola ? const Color(0xFFFFF8E1) : const Color(0xFFFFF3E0))),
                            foregroundColor: enviando
                                ? const Color(0xFF757575)
                                : (correoEnviado ? Colors.white : (enCola ? const Color(0xFFB45309) : const Color(0xFFE65100))),
                            side: BorderSide(color: enviando ? Colors.transparent : (correoEnviado ? Colors.transparent : (enCola ? const Color(0xFFF59E0B) : const Color(0xFFFFB74D)))),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          ),
                          icon: Icon(enviando ? Icons.hourglass_top_rounded : (correoEnviado ? Icons.mark_email_read : (enCola ? Icons.schedule_send : Icons.mail_outline)), size: 14),
                          label: Text(
                            enviando ? "⏳ Enviando..." : (correoEnviado ? "✓ Reenviar" : (enCola ? "⏳ En cola" : "✉ Correo")),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                          onPressed: enviando ? null : () => onEmail(context, os),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
                        '📤 Subir PDF',
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
                        '🗑️ Eliminar',
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
                  icon: const Icon(Icons.camera_alt_rounded, size: 18),
                  label: const Text(
                    '📷 Adjuntar PDF / Escaneo',
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
          if ((os['email_enviado'] == 1 || os['email_enviado'] == '1' || os['email_enviado'] == true || (os['fecha_envio_email'] != null && os['fecha_envio_email'].toString().trim().isNotEmpty)) &&
              (os['correo_cliente'] != null && os['correo_cliente'].toString().trim().isNotEmpty && os['correo_cliente'].toString().trim().toLowerCase() != 'sin registrar'))
            Padding(
              padding: const EdgeInsets.only(top: 8.0, left: 4.0),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, size: 13, color: Color(0xFF2E7D32)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      "Enviado el ${formatearFechaHoraEnvio(os['fecha_envio_email'])} a: ${os['correo_cliente']} (CC: recepcion@basculaspesa.com.mx)",
                      style: const TextStyle(fontSize: 10.5, color: Color(0xFF37474F), fontStyle: FontStyle.italic),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          first['cliente'] as String? ?? 'Cliente del Lote',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: _kTextPrim),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '👤 Técnico: ${first['tecnico_nombre'] ?? first['tecnico'] ?? 'Sin asignar'}',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF4B5563)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Builder(
                    builder: (context) {
                      final item = widget.group;
                      final String estLote = estadoCorreoLote(widget.group.items);
                      final bool loteEnviado = estLote == 'enviado';
                      final bool loteEnCola = estLote == 'cola';
                      final bool enviando = widget.state._estaEnviandoEmail;
                      return ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: enviando
                              ? const Color(0xFFE0E0E0)
                              : (loteEnviado ? const Color(0xFF2E7D32) : (loteEnCola ? const Color(0xFFFFF8E1) : const Color(0xFFFFF3E0))),
                          foregroundColor: enviando
                              ? const Color(0xFF757575)
                              : (loteEnviado ? Colors.white : (loteEnCola ? const Color(0xFFB45309) : const Color(0xFFE65100))),
                          side: BorderSide(color: enviando ? Colors.transparent : (loteEnviado ? Colors.transparent : (loteEnCola ? const Color(0xFFF59E0B) : const Color(0xFFFFB74D)))),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        ),
                        icon: Icon(enviando ? Icons.hourglass_top_rounded : (loteEnviado ? Icons.mark_email_read : (loteEnCola ? Icons.schedule_send : Icons.mail_outline)), size: 14),
                        label: Text(
                          enviando ? "⏳ Enviando..." : (loteEnviado ? "✓ Reenviar Lote" : (loteEnCola ? "⏳ En cola" : "✉ Finalizar y Enviar Lote")),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                        onPressed: enviando ? null : () => widget.state._procesarEnvioCorreo(item: item, esLote: true),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: _kCarmineRed,
                  ),
                ],
              ),
            ),
          ),
          Builder(
            builder: (context) {
              final first = widget.group.items.first;
              final bool anyEnviado = widget.group.items.any((o) =>
                  o['email_enviado'] == 1 ||
                  o['email_enviado'] == '1' ||
                  o['email_enviado'] == true ||
                  (o['fecha_envio_email'] != null && o['fecha_envio_email'].toString().trim().isNotEmpty));
              final String fechaEnvio = widget.group.items
                  .map((o) => o['fecha_envio_email'])
                  .firstWhere((f) => f != null && f.toString().trim().isNotEmpty, orElse: () => null)?.toString() ?? '';
              final String correoLote = (first['correo_cliente'] ?? '').toString().trim();
              if (!anyEnviado || correoLote.isEmpty || correoLote.toLowerCase() == 'sin registrar') {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(left: 12.0, right: 12.0, bottom: 8.0),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, size: 13, color: Color(0xFF2E7D32)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        "Enviado el ${formatearFechaHoraEnvio(fechaEnvio)} a: $correoLote (CC: recepcion@basculaspesa.com.mx)",
                        style: const TextStyle(fontSize: 10.5, color: Color(0xFF37474F), fontStyle: FontStyle.italic),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            },
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
                    onEmail: widget.state._manejarAccionEmail,
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
          onLongPressSync: () => state._mostrarMenuSincronizacion(context),
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
          periodo:        state._periodo,
          modalidad:      state._modalidad,
          tecnico:        state._tecnico,
          estado:         state._estado,
          tipoServicio:   state._filtroTipoServicio,
          empresa:        state._filtroEmpresa,
          tecnicos:       state._tecnicos,
          estados:        state._estados,
          tiposServicio:  state._listaTiposServicio,
          empresas:       state._listaEmpresas,
          searchCtrl:     state._searchCtrl,
          query:          state._query,
          hideTecnico:    hideTecnico,
          onPeriodo:      (v) { state.setState(() => state._periodo = v); state._applyFilters(); },
          onModalidad:    (v) { state.setState(() => state._modalidad = v); state._applyFilters(); },
          onTecnico:      (v) { state.setState(() => state._tecnico = v); state._applyFilters(); },
          onEstado:       (v) { state.setState(() => state._estado = v); state._applyFilters(); },
          onTipoServicio: (v) { state.setState(() => state._filtroTipoServicio = v); state._applyFilters(); },
          onEmpresa:      (v) { state.setState(() => state._filtroEmpresa = v); state._applyFilters(); },
          onSearch:       (v) { state.setState(() => state._query = v); state._applyFilters(); },
          onClear:        ()  { state._searchCtrl.clear(); state.setState(() => state._query = ''); state._applyFilters(); },
        ),
        // Table Header & Rows con Scroll Horizontal y Ancho Mínimo Garantizado
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const double minTableWidth = 720.0;
              final double effectiveWidth = constraints.maxWidth > minTableWidth
                  ? constraints.maxWidth
                  : minTableWidth;

              return Scrollbar(
                notificationPredicate: (n) => n.depth == 0,
                child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: SizedBox(
                  width: effectiveWidth,
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
                ),
              );
            },
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
            onEnviarLote: state._estaEnviandoEmail ? null : () => state._procesarEnvioCorreo(item: group, esLote: true),
            hideTecnico: hideTecnico,
            onCaptura: (os) => navegarCapturaSegunTipo(ctx, Map<String, dynamic>.from(os)),
          );
        }
        final os = group.items.first;
        return _OsRow(
          os: os,
          index: i,
          hideTecnico: hideTecnico,
          onCaptura: () => navegarCapturaSegunTipo(ctx, Map<String, dynamic>.from(os)),
          onAbrirPdf: state._abrirPdf,
          onDescargarPdf: state._descargarPdfConNomenclatura,
          onRehacer: state._mostrarDialogoRehacerToma,
          onEliminarDatos: state._mostrarDialogoEliminarDatosDesdeCero,
          onSubirPdfManual: state._subirPdfManual,
          onEmail: (ctx, os) => state._manejarEnvioCorreoOrden(os),
        );
      },
    );
  }
}

// ── Header (Tablet / Desktop) ──────────────────────────────────────────────
class _Header extends StatelessWidget {
  final SyncService sync;
  final VoidCallback onSync;
  final VoidCallback? onLongPressSync;
  final VoidCallback onRefresh;
  const _Header({
    required this.sync,
    required this.onSync,
    this.onLongPressSync,
    required this.onRefresh,
  });

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
            onLongPress: onLongPressSync,
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
  final String tipoServicio;
  final String empresa;
  final List<String> tecnicos, estados;
  final List<String> tiposServicio, empresas;
  final TextEditingController searchCtrl;
  final String query;
  final ValueChanged<String> onPeriodo;
  final ValueChanged<String> onModalidad;
  final ValueChanged<String?> onTecnico, onEstado;
  final ValueChanged<String> onTipoServicio;
  final ValueChanged<String> onEmpresa;
  final ValueChanged<String> onSearch;
  final VoidCallback onClear;
  final bool hideTecnico;

  const _FilterBar({
    required this.periodo,
    required this.modalidad,
    required this.tecnico,
    required this.estado,
    required this.tipoServicio,
    required this.empresa,
    required this.tecnicos,
    required this.estados,
    required this.tiposServicio,
    required this.empresas,
    required this.searchCtrl,
    required this.query,
    this.hideTecnico = false,
    required this.onPeriodo,
    required this.onModalidad,
    required this.onTecnico,
    required this.onEstado,
    required this.onTipoServicio,
    required this.onEmpresa,
    required this.onSearch,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kCardBg,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 1. Período
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final p in ['Hoy', 'Semana', 'Mes', 'Todo'])
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: FilterChip(
                        label: Text(
                          p,
                          style: TextStyle(
                            fontSize: 12,
                            color: periodo == p ? _kCarmineRed : _kTextSec,
                            fontWeight: periodo == p ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                        selected: periodo == p,
                        selectedColor: Colors.red.shade50,
                        checkmarkColor: _kCarmineRed,
                        side: BorderSide(color: periodo == p ? _kCarmineRed : _kBorder),
                        backgroundColor: _kCardBg,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                        onSelected: (_) => onPeriodo(p),
                      ),
                    ),
                ],
              ),
              // 2. Tipo de Servicio
              _buildDropdownFilter(
                label: 'Tipo de Servicio',
                value: tipoServicio,
                items: tiposServicio,
                onChanged: onTipoServicio,
                width: 175,
              ),
              // 3. Empresa / Cliente
              _buildDropdownFilter(
                label: 'Empresa / Cliente',
                value: empresa,
                items: empresas,
                onChanged: onEmpresa,
                width: 215,
              ),
              // 4. Modalidad
              _buildDropdownFilter(
                label: 'Modalidad',
                value: modalidad,
                items: const ['Todas las Modalidades', 'Solo Físicos', 'Solo Digitales'],
                onChanged: onModalidad,
                width: 165,
              ),
              // 5. Estado
              _buildDropdownFilter(
                label: 'Estado',
                value: estado ?? 'Todos los Estados',
                items: ['Todos los Estados', ...estados],
                onChanged: (v) => onEstado(v == 'Todos los Estados' ? null : v),
                width: 165,
              ),
              // 6. Técnico
              if (!hideTecnico)
                _buildDropdownFilter(
                  label: 'Técnico',
                  value: tecnico ?? 'Todos los Técnicos',
                  items: ['Todos los Técnicos', ...tecnicos],
                  onChanged: (v) => onTecnico(v == 'Todos los Técnicos' ? null : v),
                  width: 170,
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

  Widget _buildDropdownFilter({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String> onChanged,
    required double width,
  }) {
    final effectiveValue = items.contains(value) ? value : (items.isNotEmpty ? items.first : '');
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        value: effectiveValue.isNotEmpty ? effectiveValue : null,
        isDense: true,
        isExpanded: true,
        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: _kTextSec),
        style: const TextStyle(fontSize: 12, color: _kTextPrim, fontWeight: FontWeight.w500),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 11, color: _kTextSec, fontWeight: FontWeight.w600),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: _kBorder)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: _kBorder)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: _kCarmineRed)),
          filled: true,
          fillColor: _kCardBg,
        ),
        items: items.map((item) {
          return DropdownMenuItem<String>(
            value: item,
            child: Text(
              item,
              style: const TextStyle(fontSize: 12, color: _kTextPrim),
              overflow: TextOverflow.ellipsis,
            ),
          );
        }).toList(),
        onChanged: (val) {
          if (val != null) onChanged(val);
        },
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
      child: Row(
        children: [
          SizedBox(width: 110, child: _TH('FOLIO OS')),
          SizedBox(width: 85, child: _TH('FECHA')),
          Expanded(
            flex: 3,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 160),
              child: Text(
                'CLIENTE / SUCURSAL',
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: _kTextPrim,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          SizedBox(width: 8),
          SizedBox(width: 135, child: _TH('TIPO SERVICIO')),
          SizedBox(width: 80, child: _TH('MODALIDAD')),
          SizedBox(width: 95, child: _TH('ESTATUS')),
          SizedBox(width: 85, child: _TH('SYNC')),
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

// ─── Table Row (Tablet / Desktop - Layout Reorganizado con Barra de Acciones Inferior) ─────
class _OsRow extends StatelessWidget {
  final Map<String, dynamic> os;
  final int index;
  final VoidCallback onCaptura;
  final Function(BuildContext, Map<String, dynamic>) onAbrirPdf;
  final Function(BuildContext, Map<String, dynamic>) onDescargarPdf;
  final Function(BuildContext, Map<String, dynamic>) onRehacer;
  final Function(BuildContext, Map<String, dynamic>) onEliminarDatos;
  final Function(BuildContext, Map<String, dynamic>) onSubirPdfManual;
  final Function(BuildContext, Map<String, dynamic>) onEmail;
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
    required this.onEmail,
    this.indent = false,
    this.hideTecnico = false,
  });

  Widget _buildBtnAccion({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
    Color fg = Colors.white,
    BorderSide side = BorderSide.none,
  }) {
    return SizedBox(
      height: 29,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: fg,
          elevation: 0,
          side: side,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: const Size(0, 29),
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        icon: Icon(icon, size: 14),
        label: Text(
          label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
        onPressed: onPressed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final folioStr  = (os['folio_os'] as String? ?? os['folio'] as String? ?? '').trim();
    final modalidad = (os['modalidad'] as String? ?? 'DIGITAL').toUpperCase();
    final syncSt    = (os['sync_status'] as String? ?? '');
    final isFisico  = esModalidadFisica(os['modalidad'] as String?);
    final isEven    = index % 2 == 0;
    final String tecnicoNombre = (os['tecnico_nombre'] ?? os['tecnico'] ?? '').toString().trim();

    final bool hasDoc = _OsListScreenState.tieneDocumento(os);

    final String estatusRemoto = (os['estatus'] ?? os['estado'] ?? '').toString().trim();
    final bool isCerrado = hasDoc;

    final String estatusLabel = isCerrado
        ? (estatusRemoto.isNotEmpty && !estatusRemoto.toLowerCase().contains('sin formato') && !estatusRemoto.toLowerCase().contains('asignada') ? estatusRemoto : 'Cerrado')
        : '📋 Sin Formato';
    final Color estatusFg = isCerrado ? const Color(0xFF2E7D32) : const Color(0xFFD97706);
    final Color estatusBg = isCerrado ? const Color(0xFFE8F5E9) : const Color(0xFFFFFBEB);

    final bool isSincronizado = syncSt == 'SINCRONIZADO' ||
        syncSt == 'SINCRONIZADO_RENDER' ||
        os['is_synced'] == 1 ||
        os['is_synced'] == '1' ||
        os['sync_check_status'] == 'SUBIDA_SERVIDOR' ||
        os['sync_check_status'] == 'AUDITADA_ADMIN' ||
        os['sync_check_status'] == 'ABIERTO' ||
        (hasDoc && syncSt != 'PENDIENTE_ACTUALIZAR');

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
      decoration: BoxDecoration(
        color: isEven ? _kCardBg : const Color(0xFFFAFAFA),
        border: Border(
          bottom: const BorderSide(color: _kBorder),
          left: indent ? const BorderSide(color: Color(0xFFCBD5E1), width: 3.5) : BorderSide.none,
        ),
      ),
      padding: EdgeInsets.only(
        left: indent ? 24.0 : 16.0,
        right: 16.0,
        top: 8.0,
        bottom: 8.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Bloque 1: Datos Principales de la Orden ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // [FOLIO OS] (110px)
              SizedBox(
                width: 110,
                child: Text(
                  folioStr.isNotEmpty ? folioStr : '—',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5, color: _kCarmineRed),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // [FECHA] (85px)
              SizedBox(
                width: 85,
                child: Text(
                  fechaStr,
                  style: const TextStyle(fontSize: 11, color: _kTextPrim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // [CLIENTE / SUCURSAL] (Expanded, flex: 3 con minWidth garantizado)
              Expanded(
                flex: 3,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 160),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        os['cliente'] ?? '—',
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: _kTextPrim),
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        maxLines: 1,
                      ),
                      if ((os['sucursal'] ?? '').toString().trim().isNotEmpty)
                        Text(
                          os['sucursal'].toString().trim(),
                          style: const TextStyle(fontSize: 9.5, color: _kTextSec),
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          maxLines: 1,
                        ),
                      if (tecnicoNombre.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2.0),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.person, size: 13, color: Colors.blueAccent),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  'Técnico: $tecnicoNombre',
                                  style: const TextStyle(fontSize: 10.5, color: Colors.blueGrey, fontWeight: FontWeight.w500),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.only(top: 2.0),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.person_outline, size: 12, color: Colors.grey),
                              SizedBox(width: 3),
                              Text(
                                'Sin técnico asignado',
                                style: TextStyle(fontSize: 9.5, color: Colors.grey, fontStyle: FontStyle.italic),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // [TIPO SERVICIO] (135px)
              SizedBox(
                width: 135,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TipoServicioBadge(os: os),
                ),
              ),
              // [MODALIDAD] (80px)
              SizedBox(
                width: 80,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _Badge(
                    label: isFisico ? 'Físico' : 'Digital',
                    fg: isFisico ? const Color(0xFF7C3AED) : const Color(0xFF2563EB),
                    bg: isFisico ? const Color(0xFFF3F0FF) : const Color(0xFFEFF6FF),
                  ),
                ),
              ),
              // [ESTATUS] (95px)
              SizedBox(
                width: 95,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _Badge(
                    label: estatusLabel,
                    fg: estatusFg,
                    bg: estatusBg,
                  ),
                ),
              ),
              // [SYNC] (85px)
              SizedBox(
                width: 85,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SyncCheckBadge(
                    status: effectiveSyncStatus,
                    showLabel: true,
                  ),
                ),
              ),
            ],
          ),

          // ── Bloque 2: Divisor ligero ──
          const SizedBox(height: 6),
          const Divider(height: 1, thickness: 0.5, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 6),

          // ── Bloque 3: Barra Inferior de Acciones ──
          Padding(
            padding: const EdgeInsets.only(top: 6.0, bottom: 4.0, right: 8.0),
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6.0,    // Espacio horizontal entre botones
                runSpacing: 6.0, // Salto de línea limpio si no cabe por el sidebar
                children: [
                  if (isCerrado) ...[
                    _buildBtnAccion(
                      label: "Ver PDF",
                      icon: Icons.picture_as_pdf,
                      color: const Color(0xFF1565C0),
                      onPressed: () => onAbrirPdf(context, os),
                    ),
                    _buildBtnAccion(
                      label: "Descargar",
                      icon: Icons.download,
                      color: const Color(0xFF2E7D32),
                      onPressed: () => onDescargarPdf(context, os),
                    ),
                    _buildBtnAccion(
                      label: "Rehacer",
                      icon: Icons.replay,
                      color: const Color(0xFFEF6C00),
                      onPressed: () => onRehacer(context, os),
                    ),
                    _buildBtnAccion(
                      label: "Subir PDF",
                      icon: Icons.upload_file,
                      color: const Color(0xFF4527A0),
                      onPressed: () => onSubirPdfManual(context, os),
                    ),
                    Builder(
                      builder: (context) {
                        final item = os;
                        final String estCorreo = estadoCorreoOs(item);
                        final bool correoEnviado = estCorreo == 'enviado';
                        final bool enCola = estCorreo == 'cola';
                        final st = context.findAncestorStateOfType<_OsListScreenState>();
                        final bool enviando = st != null && st._estaEnviandoEmail;
                        return _buildBtnAccion(
                          label: enviando
                              ? "⏳ Enviando..."
                              : (correoEnviado ? "✓ Reenviar Correo" : (enCola ? "⏳ En cola (Offline)" : "✉ Enviar Correo")),
                          icon: enviando
                              ? Icons.hourglass_top_rounded
                              : (correoEnviado ? Icons.mark_email_read : (enCola ? Icons.schedule_send : Icons.mail_outline)),
                          color: enviando
                              ? const Color(0xFFE0E0E0)
                              : (correoEnviado ? const Color(0xFF2E7D32) : (enCola ? const Color(0xFFFFF8E1) : const Color(0xFFFFF3E0))),
                          fg: enviando
                              ? const Color(0xFF757575)
                              : (correoEnviado ? Colors.white : (enCola ? const Color(0xFFB45309) : const Color(0xFFE65100))),
                          side: BorderSide(color: enviando ? Colors.transparent : (correoEnviado ? Colors.transparent : (enCola ? const Color(0xFFF59E0B) : const Color(0xFFFFB74D)))),
                          onPressed: enviando ? null : () {
                            if (st != null) {
                              st._procesarEnvioCorreo(item: item, esLote: false);
                            } else {
                              onEmail(context, os);
                            }
                          },
                        );
                      },
                    ),
                    _buildBtnAccion(
                      label: "Reset",
                      icon: Icons.delete_forever,
                      color: const Color(0xFFC62828),
                      onPressed: () => onEliminarDatos(context, os),
                    ),
                  ] else ...[
                    if (isFisico) ...[
                      _buildBtnAccion(
                        label: "Adjuntar PDF / Escaneo",
                        icon: Icons.camera_alt_rounded,
                        color: const Color(0xFF7C3AED),
                        onPressed: () => context.push('/escaneo', extra: {'folio_os': os['folio_os'] ?? ''}),
                      ),
                    ] else ...[
                      _buildBtnAccion(
                        label: "Iniciar Captura",
                        icon: Icons.edit,
                        color: const Color(0xFFEF6C00),
                        onPressed: onCaptura,
                      ),
                    ],
                    _buildBtnAccion(
                      label: "Subir PDF",
                      icon: Icons.upload_file,
                      color: const Color(0xFF4527A0),
                      onPressed: () => onSubirPdfManual(context, os),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if ((os['email_enviado'] == 1 || os['email_enviado'] == '1' || os['email_enviado'] == true || (os['fecha_envio_email'] != null && os['fecha_envio_email'].toString().trim().isNotEmpty)) &&
              (os['correo_cliente'] != null && os['correo_cliente'].toString().trim().isNotEmpty && os['correo_cliente'].toString().trim().toLowerCase() != 'sin registrar'))
            Padding(
              padding: const EdgeInsets.only(top: 2.0, bottom: 4.0, left: 16.0, right: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, size: 13, color: Color(0xFF2E7D32)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      "Enviado el ${formatearFechaHoraEnvio(os['fecha_envio_email'])} a: ${os['correo_cliente']} (CC: recepcion@basculaspesa.com.mx)",
                      style: const TextStyle(fontSize: 10.5, color: Color(0xFF37474F), fontStyle: FontStyle.italic),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Tablet Lote Row (Layout Reorganizado con Botón de Correo Destacado Abajo) ─────────────
class _LoteRow extends StatefulWidget {
  final _OsGroup group;
  final void Function(Map<String, dynamic> os) onCaptura;
  final bool hideTecnico;
  final VoidCallback? onEnviarLote;
  const _LoteRow({
    required this.group,
    required this.onCaptura,
    this.hideTecnico = false,
    this.onEnviarLote,
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
    final String tecnicoNombre = (first['tecnico_nombre'] ?? first['tecnico'] ?? '').toString().trim();

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
                bottom: BorderSide(color: Color(0xFFFED7AA)),
                left: BorderSide(color: _kCarmineRed, width: 3.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Bloque 1: Datos del Lote ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 110,
                      child: Row(
                        children: [
                          Icon(_expanded ? Icons.keyboard_arrow_down : Icons.chevron_right, size: 18, color: _kCarmineRed),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(color: _kCarmineRed, borderRadius: BorderRadius.circular(4)),
                            child: Text('LOTE • $count OS', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 85,
                      child: Text(
                        (first['fecha'] as String? ?? '').split('T').first,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 160),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              first['cliente'] ?? '—',
                              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (tecnicoNombre.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2.0),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.person, size: 13, color: Colors.blueAccent),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        'Técnico: $tecnicoNombre',
                                        style: const TextStyle(fontSize: 10.5, color: Colors.blueGrey, fontWeight: FontWeight.w500),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            else
                              const Padding(
                                padding: EdgeInsets.only(top: 2.0),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.person_outline, size: 12, color: Colors.grey),
                                    SizedBox(width: 3),
                                    Text(
                                      'Sin técnico asignado',
                                      style: TextStyle(fontSize: 9.5, color: Colors.grey, fontStyle: FontStyle.italic),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(width: 135, child: Align(alignment: Alignment.centerLeft, child: TipoServicioBadge(os: first))),
                    const SizedBox(width: 80, child: Text('Lote', style: TextStyle(fontSize: 11))),
                    const SizedBox(width: 95, child: Text('Lote', style: TextStyle(fontSize: 11, color: _kCarmineRed))),
                    const SizedBox(width: 85),
                  ],
                ),

                // ── Bloque 2: Divisor ligero ──
                const SizedBox(height: 6),
                const Divider(height: 1, thickness: 0.5, color: Color(0xFFFED7AA)),
                const SizedBox(height: 6),

                // ── Bloque 3: Barra de Acciones del Lote ──
                Padding(
                  padding: const EdgeInsets.only(top: 6.0, bottom: 4.0, right: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.layers, size: 14, color: Color(0xFFC2410C)),
                          const SizedBox(width: 5),
                          Text(
                            '$count órdenes en este lote • Toca para ${_expanded ? "contraer" : "expandir"}',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF9A3412), fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                      Builder(
                        builder: (context) {
                          final item = widget.group;
                          final String estLote = estadoCorreoLote(widget.group.items);
                          final bool loteEnviado = estLote == 'enviado';
                          final bool loteEnCola = estLote == 'cola';
                          final st = context.findAncestorStateOfType<_OsListScreenState>();
                          final bool enviando = st != null && st._estaEnviandoEmail;
                          return SizedBox(
                            height: 29,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: enviando
                                    ? const Color(0xFFE0E0E0)
                                    : (loteEnviado ? const Color(0xFF2E7D32) : (loteEnCola ? const Color(0xFFFFF8E1) : const Color(0xFFFFF3E0))),
                                foregroundColor: enviando
                                    ? const Color(0xFF757575)
                                    : (loteEnviado ? Colors.white : (loteEnCola ? const Color(0xFFB45309) : const Color(0xFFE65100))),
                                side: BorderSide(color: enviando ? Colors.transparent : (loteEnviado ? Colors.transparent : (loteEnCola ? const Color(0xFFF59E0B) : const Color(0xFFFFB74D)))),
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: const Size(0, 29),
                                visualDensity: VisualDensity.compact,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                              icon: Icon(enviando ? Icons.hourglass_top_rounded : (loteEnviado ? Icons.mark_email_read : (loteEnCola ? Icons.schedule_send : Icons.mail_outline)), size: 14),
                              label: Text(
                                enviando
                                    ? "⏳ Enviando..."
                                    : (loteEnviado ? "✓ Reenviar Lote" : (loteEnCola ? "⏳ Lote en cola (Offline)" : "✉ Finalizar y Enviar Lote")),
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                              onPressed: enviando ? null : () {
                                if (widget.onEnviarLote != null) {
                                  widget.onEnviarLote!();
                                  return;
                                }
                                if (st != null) {
                                  st._procesarEnvioCorreo(item: item, esLote: true);
                                } else {
                                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                    const SnackBar(content: Text('No se pudo abrir el envío del lote. Recarga el tablero e intenta de nuevo.')),
                                  );
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (context) {
                    final first = widget.group.items.first;
                    final bool anyEnviado = widget.group.items.any((o) =>
                        o['email_enviado'] == 1 ||
                        o['email_enviado'] == '1' ||
                        o['email_enviado'] == true ||
                        (o['fecha_envio_email'] != null && o['fecha_envio_email'].toString().trim().isNotEmpty));
                    final String fechaEnvio = widget.group.items
                        .map((o) => o['fecha_envio_email'])
                        .firstWhere((f) => f != null && f.toString().trim().isNotEmpty, orElse: () => null)?.toString() ?? '';
                    final String correoLote = (first['correo_cliente'] ?? '').toString().trim();
                    if (!anyEnviado || correoLote.isEmpty || correoLote.toLowerCase() == 'sin registrar') {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 2.0, bottom: 4.0, left: 4.0, right: 8.0),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle, size: 13, color: Color(0xFF2E7D32)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              "Enviado el ${formatearFechaHoraEnvio(fechaEnvio)} a: $correoLote (CC: recepcion@basculaspesa.com.mx)",
                              style: const TextStyle(fontSize: 10.5, color: Color(0xFF37474F), fontStyle: FontStyle.italic),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
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
              onEmail: (ctx, os) => (context.findAncestorStateOfType<_OsListScreenState>())?._manejarEnvioCorreoOrden(os),
              indent: true,
            ),
      ],
    );
  }
}

// ─── Shared Helpers ─────────────────────────────────────────────────────────
class TipoServicioBadge extends StatelessWidget {
  final Map<String, dynamic> os;
  const TipoServicioBadge({super.key, required this.os});

  static int? _int(dynamic v) => v is int ? v : int.tryParse(v?.toString() ?? '');

  static String? _nombre(Map<String, dynamic> os) {
    for (final k in const ['tipo_servicio', 'tipo_servicio_nombre', 'tipo']) {
      final v = os[k]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final rules = getRules(
      id: _int(os['id_tipo_servicio']) ?? _int(os['tipo_servicio_id']),
      nombre: _nombre(os),
      folio: (os['folio_os'] ?? os['folio'])?.toString(),
    );
    final label = rules.etiquetaCorta;
    final (Color fg, Color bg) = switch (rules) {
      _ when rules.sinTipo              => (const Color(0xFFB45309), const Color(0xFFFFFBEB)), // ámbar
      _ when rules.esRemision || rules.esRevisionCeldas
                                        => (const Color(0xFF6B7280), const Color(0xFFF9FAFB)),
      _ when rules.pideCca && rules.pideDve
                                        => (const Color(0xFF3730A3), const Color(0xFFEEF2FF)), // índigo
      _ when rules.pideCca              => (const Color(0xFF1D4ED8), const Color(0xFFEFF6FF)), // azul
      _ when rules.pideDve              => (const Color(0xFF0F766E), const Color(0xFFF0FDFA)), // verde azulado
      _                                 => (const Color(0xFF4B5563), const Color(0xFFF3F4F6)), // gris (Ajuste)
    };
    return Tooltip(
      message: rules.etiquetaLarga,
      child: _Badge(label: label, fg: fg, bg: bg),
    );
  }
}

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
          style: TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w600, height: 1.2),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
}

class EmailStatusBadge extends StatelessWidget {
  final bool enviado;
  final bool enCola;
  final String correo;
  final VoidCallback onTap;

  const EmailStatusBadge({
    super.key,
    required this.enviado,
    this.enCola = false,
    required this.correo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (enviado) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF81C784), width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mark_email_read_rounded, size: 13, color: Color(0xFF2E7D32)),
              SizedBox(width: 4),
              Text(
                '✓ Enviado',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2E7D32),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFFCD34D), width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mail_outline_rounded, size: 13, color: Color(0xFFD97706)),
              SizedBox(width: 4),
              Text(
                enCola ? '⏳ En cola (Offline)' : '✉ Envío pendiente',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFB45309),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }
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

// ── Estado visual del correo (✓ Enviado / ⏳ En cola (Offline) / ✉ Enviar) ──
/// 'enviado' | 'cola' | 'ninguno'
String estadoCorreoOs(Map<String, dynamic> o) {
  final env = o['email_enviado'];
  if (env == 1 || env == true || env == '1' || env == 'true') return 'enviado';
  final st = (o['email_status'] ?? '').toString().trim().toLowerCase();
  if (st == 'cola' || st == 'pendiente') return 'cola';
  return 'ninguno';
}

/// Estado del lote considerando solo las órdenes listas (con PDF); si ninguna lo está, todas.
String estadoCorreoLote(List<Map<String, dynamic>> items) {
  final listas = items.where(_OsListScreenState.tieneDocumento).toList();
  final base = listas.isNotEmpty ? listas : items;
  if (base.isNotEmpty && base.every((o) => estadoCorreoOs(o) == 'enviado')) return 'enviado';
  if (base.any((o) => estadoCorreoOs(o) == 'cola')) return 'cola';
  return 'ninguno';
}
