// lib/screens/os_list_screen.dart — Dashboard corporativo estilo escritorio PESA
// Paleta limpia: fondo #F8F9FA, blanco, rojo corporativo #C8102E
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../services/local_db_service.dart';
import '../services/sync_service.dart';
import '../widgets/app_shell.dart';
import '../widgets/captura_firma_tecnico_dialog.dart';

// ── Tokens de diseño corporativo ──────────────────────────────────────────
const _bg         = Color(0xFFF8F9FA);
const _white      = Colors.white;
const _red        = Color(0xFFC8102E);
const _textPrim   = Color(0xFF111827);
const _textSec    = Color(0xFF6B7280);
const _border     = Color(0xFFE5E7EB);
const _tableHead  = Color(0xFFF3F4F6);
const _tableText  = Color(0xFF374151);

class OsListScreen extends StatefulWidget {
  const OsListScreen({super.key});
  @override
  State<OsListScreen> createState() => _OsListScreenState();
}

class _OsListScreenState extends State<OsListScreen> {
  List<Map<String, dynamic>> _all      = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  bool _syncDialogOpen = false; // flag para cierre garantizado del spinner

  // ── Filtros ───────────────────────────────────────────────────────────────
  String  _periodo = 'Todo'; // Por defecto 'Todo' para no perder órdenes antiguas
  String  _modalidad = 'Todas las Modalidades';
  String? _tecnico;
  String? _estado;
  String  _query   = '';
  final   _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final sync = context.read<SyncService>();
    sync.startNetworkMonitor();
    sync.addListener(_onSyncChanged);

    // Si SyncService ya tiene órdenes en memoria tras el pull, usarlas de inmediato
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

    // ── 1. NO fijar _tecnico en el estado para técnicos ───────────────────
    // getOsForTecnico() en SQLite ya entrega SOLO las órdenes del técnico.
    // Si se fijara _tecnico aquí, _filterIsolate haría un segundo filtro por
    // cadena que puede descartar registros por diferencias de capitalización
    // o acentos entre el nombre en el JWT y la columna 'tecnico' en SQLite.
    // El dropdown de técnico queda disponible solo para roles admin/logística.

    // ── 2. Verificación INMEDIATA de firma (sin depender de red) ───────
    // Primero revisa localmente; si la sesión está offline o el servidor
    // falla, igual fuerza la captura de firma si no existe localmente.
    if (isTecnico && mounted) {
      final username  = auth.username ?? '';
      final nombre    = auth.nombreCompleto ?? username;
      final idTec     = auth.idTecnico ?? 0;

      bool tieneFirmaLocal = false;
      try {
        // Verificar SOLO en almacenamiento local (instantáneo, sin red)
        tieneFirmaLocal = await FirmaTecnicoService.instance.tieneFirma(username);
      } catch (e) {
        debugPrint('[Dashboard] Error verificando firma local: $e');
      }

      if (!tieneFirmaLocal && mounted) {
        debugPrint('[Dashboard] Técnico sin firma local → mostrando diálogo bloqueante');
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => PopScope(
            canPop: false, // Flutter 3.x+ replacement for WillPopScope
            child: CapturFirmaTecnicoDialog(
              username:       username,
              nombreCompleto: nombre,
              idTecnico:      idTec,
            ),
          ),
        );
      }
    }

    // ── 3. Disparar sincronización con visibilidad de error real ───────
    if (mounted) await _sincronizarOrdenesServidor();
  }

  /// Cierra el dialog de progreso de forma segura, usando el contexto
  /// del propio widget (no el del builder del dialog) para evitar el
  /// problema de dialogCtx no inicializado cuando se cierra antes del
  /// primer frame renderizado.
  void _closeSyncDialog() {
    if (!_syncDialogOpen) return;
    _syncDialogOpen = false;
    if (mounted && Navigator.canPop(context)) {
      Navigator.of(context, rootNavigator: false).pop();
    }
  }

  Future<void> _sincronizarOrdenesServidor() async {
    if (!mounted) return;
    if (_syncDialogOpen) return; // Evitar doble apertura

    // ── Abrir spinner con flag de control ────────────────────────────────
    _syncDialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (_) => const AlertDialog(
        title: Text('Sincronizando...'),
        content: SizedBox(
          height: 88,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFFC8102E)),
              SizedBox(height: 16),
              Text('Descargando órdenes del servidor Render...',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );

    String? errorMsg;
    String? errorDetail;

    try {
      debugPrint('[Sync] Iniciando sincronización con timeout de 30s...');

      // ── SIEMPRE forzar pull completo desde 2000-01-01 ─────────────────────
      // El servidor filtra por sync_at >= since. Las órdenes con sync_at=NULL
      // quedan EXCLUIDAS si since > 1970. Resetear garantiza que se descarguen
      // TODAS las órdenes del técnico en cada sync manual.
      await LocalDbService.instance.setLastSyncTime(DateTime(2000));
      debugPrint('[Sync] lastSync reseteado a 2000-01-01 → pull completo garantizado');

      // TIMEOUT ESTRICTO: si performSync no responde en 30s → TimeoutException
      await context
          .read<SyncService>()
          .performSync()
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw TimeoutException(
                'El servidor Render no respondió en 30 segundos.\n'
                'Puede estar en "cold start" (espera ~1 min) o sin internet.',
              );
            },
          );

      // Si SyncService ya tiene órdenes en memoria del pull HTTP 200, asignarlas directamente:
      final sync = context.read<SyncService>();
      if (sync.orders.isNotEmpty && mounted) {
        setState(() {
          _all = List<Map<String, dynamic>>.from(sync.orders);
          _loading = false;
        });
        await _applyFilters();
      } else {
        await _loadLocal();
      }

      // Determinar resultado
      if (mounted) {
        if (sync.state == SyncState.error) {
          errorMsg = 'Error de Sincronización';
          errorDetail = sync.message.isNotEmpty
              ? sync.message
              : 'Error desconocido al conectar con el servidor.';
        }
      }
    } on TimeoutException catch (e) {
      debugPrint('[Sync] ⏱ TIMEOUT: $e');
      errorMsg = 'Tiempo de Espera Agotado';
      errorDetail = e.message ?? e.toString();
      // Cargar datos locales aunque haya timeout — pueden existir órdenes previas
      if (mounted) await _loadLocal();
    } catch (e, st) {
      debugPrint('[Sync] ❌ ERROR: $e\n$st');
      errorMsg = 'Error de Conexión';
      errorDetail = e.toString();
      // Cargar datos locales aunque haya error — pueden existir órdenes previas
      if (mounted) await _loadLocal();
    } finally {
      // ── CIERRE GARANTIZADO DEL DIALOG ──────────────────────────────────
      // Se ejecuta SIEMPRE: éxito, error o timeout.
      _closeSyncDialog();
    }

    if (!mounted) return;

    // ── Resultado: error ────────────────────────────────────────────────
    if (errorMsg != null) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(children: [
            const Icon(Icons.wifi_off, color: Color(0xFFC8102E), size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(errorMsg!, style: const TextStyle(fontSize: 15))),
          ]),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: SelectableText(
                    errorDetail ?? 'Sin detalles',
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '• Verifica que la tablet tenga Wi-Fi activo\n'
                  '• Render puede tardar ~30s en despertar (cold start)\n'
                  '• Si persiste, cierra sesión y vuelve a entrar',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC8102E),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _sincronizarOrdenesServidor();
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
      return;
    }

    // ── Resultado: éxito ─────────────────────────────────────────────────
    final totalOS = _all.length;
    final syncMsg = context.read<SyncService>().statusMessage;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          totalOS > 0
              ? 'Sincronizado — $totalOS órdenes cargadas'
              : syncMsg.isNotEmpty
                  ? syncMsg
                  : 'Sincronizado. Sin órdenes activas.',
        ),
        backgroundColor:
            totalOS > 0 ? Colors.green.shade700 : Colors.orange.shade700,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  void dispose() {
    context.read<SyncService>().removeListener(_onSyncChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSyncChanged() {
    final sync = context.read<SyncService>();
    debugPrint('[Dashboard] _onSyncChanged: state=${sync.state}, orders=${sync.orders.length}');
    // Si SyncService recibió las órdenes tras el pull HTTP 200, asignarlas directamente:
    if (sync.orders.isNotEmpty && mounted) {
      setState(() {
        _all = List<Map<String, dynamic>>.from(sync.orders);
        _loading = false;
      });
      _applyFilters();
    } else if (sync.state == SyncState.success || sync.state == SyncState.error) {
      _loadLocal();
    }
  }


  Future<void> _loadLocal() async {
    final sync = context.read<SyncService>();
    // Prioridad 1: si SyncService ya tiene órdenes en memoria del pull, mantenerlas visibles
    if (sync.orders.isNotEmpty && _all.isEmpty) {
      if (mounted) {
        setState(() {
          _all = List<Map<String, dynamic>>.from(sync.orders);
          _loading = false;
        });
        await _applyFilters();
      }
    } else if (_all.isEmpty) {
      if (mounted) setState(() => _loading = true);
    }

    try {
      final list = await LocalDbService.instance.getAllOs();
      if (mounted) {
        if (list.isNotEmpty) {
          setState(() { _all = list; _loading = false; });
          await _applyFilters();
        } else if (sync.orders.isNotEmpty) {
          setState(() { _all = List<Map<String, dynamic>>.from(sync.orders); _loading = false; });
          await _applyFilters();
        } else {
          setState(() { _all = []; _loading = false; });
        }
      }
    } catch (e) {
      debugPrint('[Dashboard] Error en _loadLocal: $e');
      if (mounted) {
        if (sync.orders.isNotEmpty) {
          setState(() { _all = List<Map<String, dynamic>>.from(sync.orders); _loading = false; });
          await _applyFilters();
        } else {
          setState(() { _all = []; _loading = false; });
        }
      }
    }
  }

  Future<void> _applyFilters() async {
    final now = DateTime.now();
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
    );

    // Para listas grandes usar isolate (no congela el hilo UI)
    final List<Map<String, dynamic>> result = _all.length > 20
        ? await compute(_filterIsolate, params)
        : _filterIsolate(params);

    if (mounted) setState(() => _filtered = result);
  }

  // ── KPIs ─────────────────────────────────────────────────────────────────
  int get _kpiTotal   => _filtered.length;

  int get _kpiProceso => _filtered.where((o) {
    final e = (o['estado'] as String? ?? '').trim().toUpperCase();
    final isCerrada = e == 'CERRADA' ||
        e == 'CERRADO' ||
        e == 'COMPLETADA' ||
        e == 'COMPLETADA_DIGITAL' ||
        e == 'FIRMADA';
    final isCancelada = e == 'CANCELADA' || e == 'CANCELADO';
    return !isCerrada && !isCancelada;
  }).length;

  int get _kpiCerrado => _filtered.where((o) {
    final e = (o['estado'] as String? ?? '').trim().toUpperCase();
    return e == 'CERRADA' ||
        e == 'CERRADO' ||
        e == 'COMPLETADA' ||
        e == 'COMPLETADA_DIGITAL' ||
        e == 'FIRMADA';
  }).length;

  int get _kpiFisico  => _filtered.where((o) {
    final m = (o['modalidad'] as String? ?? '').trim().toUpperCase();
    return m.contains('FISIC') || m.contains('FÍSIC');
  }).length;

  List<String> get _tecnicos => _all
      .map((o) => o['tecnico'] as String? ?? '').where((t) => t.isNotEmpty)
      .toSet().toList()..sort();
  List<String> get _estados => _all
      .map((o) => o['estado'] as String? ?? '').where((e) => e.isNotEmpty)
      .toSet().toList()..sort();

  // ── Agrupación por lotes ───────────────────────────────────────────────────
  /// Agrupa las OS por id_lote. Las OS sin lote forman grupos individuales.
  List<_OsGroup> _groupByLote(List<Map<String, dynamic>> list) {
    final Map<String, List<Map<String, dynamic>>> buckets = {};
    for (final os in list) {
      final lote = (os['id_lote'] as String?) ??
          (os['lote'] as String?) ?? '';
      final key = lote.isNotEmpty ? lote : 'solo_${os['folio_os'] ?? os['local_id']}';
      buckets.putIfAbsent(key, () => []).add(os);
    }
    return buckets.entries.map((e) {
      final isLote = !e.key.startsWith('solo_') && e.value.length > 1;
      return _OsGroup(loteKey: e.key, items: e.value, isLote: isLote);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final sync   = context.watch<SyncService>();
    final auth   = context.watch<AuthService>();
    final hideTecnico = auth.isTecnico;
    final bottom = MediaQuery.of(context).viewPadding.bottom;

    final content = Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          _Header(sync: sync, onSync: () => context.read<SyncService>().performSync(),
              onRefresh: _loadLocal),
          _KpiBar(total: _kpiTotal, proceso: _kpiProceso,
              cerrado: _kpiCerrado, fisico: _kpiFisico),
          _FilterBar(
            periodo:  _periodo,
            modalidad: _modalidad,
            tecnico: _tecnico,
            estado: _estado,
            tecnicos: _tecnicos,
            estados: _estados,
            searchCtrl: _searchCtrl,
            query: _query,
            hideTecnico: hideTecnico,
            onPeriodo:   (v) { setState(() => _periodo = v); _applyFilters(); },
            onModalidad: (v) { setState(() => _modalidad = v); _applyFilters(); },
            onTecnico:   (v) { setState(() => _tecnico = v); _applyFilters(); },
            onEstado:    (v) { setState(() => _estado  = v); _applyFilters(); },
            onSearch:    (v) { setState(() => _query   = v); _applyFilters(); },
            onClear:     ()  { _searchCtrl.clear(); setState(() => _query = ''); _applyFilters(); },
          ),
          _TableHeader(hideTecnico: hideTecnico),
          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _red))
            : _filtered.isEmpty
                ? _EmptyState(onSync: () => context.read<SyncService>().performSync())
                : _buildGroupedList(context, hideTecnico),
          ),
          SizedBox(height: bottom > 0 ? bottom : 8),
        ]),
      ),
    );
    return AppShell(currentRoute: '/os', child: content);
  }

  Widget _buildGroupedList(BuildContext context, bool hideTecnico) {
    final groups = _groupByLote(_filtered);

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
        );
      },
    );
  }
} // fin _OsListScreenState

// ── Modelo para compute() ────────────────────────────────────────────────────
class _FilterParams {
  final List<Map<String, dynamic>> all;
  final String periodo;
  final String modalidad;
  final String? tecnico;
  final String? estado;
  final String query;
  final int nowYear, nowMonth, nowDay;
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

/// Función top-level requerida por compute() — corre en isolate separado
List<Map<String, dynamic>> _filterIsolate(_FilterParams p) {
  final now = DateTime(p.nowYear, p.nowMonth, p.nowDay);
  final filtered = p.all.where((os) {
    // 1. Filtro por Período (Fecha)
    if (p.periodo != 'Todo') {
      final fechaStr = os['fecha'] as String? ?? '';
      if (fechaStr.isNotEmpty) {
        final f = _parseFecha(fechaStr);
        if (f != null) {
          if (p.periodo == 'Hoy'    && !(f.year == now.year && f.month == now.month && f.day == now.day)) return false;
          if (p.periodo == 'Semana' && now.difference(f).inDays.abs() > 7) return false;
          if (p.periodo == 'Mes'    && (f.month != now.month || f.year != now.year)) return false;
        }
      }
    }

    // 2. Filtro por Modalidad (Todas las Modalidades / Solo Físicos / Solo Digitales)
    if (p.modalidad.isNotEmpty && p.modalidad != 'Todas las Modalidades') {
      final m = (os['modalidad'] as String? ?? '').trim().toUpperCase();
      final isFisico = m.contains('FISIC') || m.contains('FÍSIC');
      if (p.modalidad == 'Solo Físicos' && !isFisico) return false;
      if (p.modalidad == 'Solo Digitales' && isFisico) return false;
    }

    // 3. Filtro por Técnico (para admin/logística)
    if (p.tecnico != null && p.tecnico!.isNotEmpty &&
        !(os['tecnico'] as String? ?? '').toLowerCase().contains(p.tecnico!.toLowerCase())) return false;

    // 4. Filtro por Estado
    if (p.estado != null && p.estado!.isNotEmpty &&
        (os['estado'] as String? ?? '') != p.estado) return false;

    // 5. Búsqueda por texto (query)
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
// Header
// ═══════════════════════════════════════════════════════════════════════════
class _Header extends StatelessWidget {
  final SyncService sync;
  final VoidCallback onSync;
  final VoidCallback onRefresh;
  const _Header({required this.sync, required this.onSync, required this.onRefresh});

  void _showNuevoDocDialog(BuildContext context) {
    context.push('/nuevo-doc');
  }

  @override
  Widget build(BuildContext context) {
    // ── LayoutBuilder garantiza que el Row tenga ancho real ──────────────────
    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 600;
      return Container(
        width: double.infinity,
        color: _white,
        padding: EdgeInsets.fromLTRB(16, isNarrow ? 12 : 10, 12, 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _border)),
        ),
        child: Row(children: [
          // Logo PESA
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: _red, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.scale, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          // Títulos — Expanded para que tomen el ancho disponible
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('Resumen Operativo de Servicios',
                    style: TextStyle(color: _textPrim, fontWeight: FontWeight.w800, fontSize: 15),
                    overflow: TextOverflow.ellipsis),
                Text('Órdenes de Servicio, Revisiones e Inventarios',
                    style: TextStyle(color: _textSec, fontSize: 10),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          // Sync badge
          _SyncChip(sync: sync),
          const SizedBox(width: 6),
          // Botón Sincronizar
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _textPrim,
              side: const BorderSide(color: _border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            onPressed: sync.state == SyncState.syncing ? null : onSync,
            icon: sync.state == SyncState.syncing
                ? const SizedBox(width: 13, height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _red))
                : const Icon(Icons.sync, size: 15),
            label: const Text('Sincronizar', style: TextStyle(fontSize: 11)),
          ),
          const SizedBox(width: 4),
          // Botón Actualizar
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: _textPrim,
              side: const BorderSide(color: _border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              minimumSize: Size.zero,
            ),
            onPressed: onRefresh,
            child: const Icon(Icons.refresh, size: 16),
          ),
          // Botón + Nuevo Documento — oculto para técnicos de campo
          Builder(builder: (ctx) {
            final isTecnico = ctx.watch<AuthService>().isTecnico;
            if (isTecnico) return const SizedBox.shrink();
            return Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(width: 4),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  foregroundColor: _white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                onPressed: () => _showNuevoDocDialog(context),
                icon: const Icon(Icons.add, size: 14),
                label: const Text('+ Nuevo Documento',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ]);
          }),
        ]),
      );
    });
  }
}

// ── Sync chip ─────────────────────────────────────────────────────────────
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
        return _chip(Colors.orange.shade50, Colors.orange.shade700,
            sync.message.isNotEmpty ? sync.message : '⚠ Error');
      case SyncState.offline:
        return _chip(Colors.grey.shade100, Colors.grey.shade600, '📵 Sin conexión');
      default:
        return _chip(Colors.grey.shade100, Colors.grey.shade600, 'Listo');
    }
  }
  Widget _chip(Color bg, Color fg, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: bg, borderRadius: BorderRadius.circular(20),
      border: Border.all(color: fg.withOpacity(0.3)),
    ),
    child: Text(label, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// KPI Bar
// ═══════════════════════════════════════════════════════════════════════════
class _KpiBar extends StatelessWidget {
  final int total, proceso, cerrado, fisico;
  const _KpiBar({required this.total, required this.proceso,
      required this.cerrado, required this.fisico});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: _white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(children: [
        _KpiCard(label: 'TOTAL PERIODO',    value: total,
            sub: '${total == 1 ? "1 orden" : "$total órdenes"} en el periodo seleccionado',
            color: const Color(0xFF16A34A)),
        const SizedBox(width: 12),
        _KpiCard(label: 'EN PROCESO',       value: proceso,
            sub: 'órdenes pendientes de cerrar',   color: const Color(0xFFC8102E)),
        const SizedBox(width: 12),
        _KpiCard(label: 'CERRADOS',         value: cerrado,
            sub: 'Total cerradas',                 color: const Color(0xFF2563EB)),
        const SizedBox(width: 12),
        _KpiCard(label: 'FORMATOS FÍSICOS', value: fisico,
            sub: 'órdenes en formato físico',      color: const Color(0xFF7C3AED)),
      ]),
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label, sub;
  final int    value;
  final Color  color;
  const _KpiCard({required this.label, required this.value,
      required this.sub, required this.color});
  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _border),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
          blurRadius: 6, offset: const Offset(0, 2))],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(
          color: _textSec, fontSize: 10, fontWeight: FontWeight.w600,
          letterSpacing: 0.6)),
      const SizedBox(height: 6),
      Text(value.toString(), style: TextStyle(
          color: color, fontSize: 32, fontWeight: FontWeight.w800,
          height: 1.0)),
      const SizedBox(height: 4),
      Text(sub, style: const TextStyle(color: _textSec, fontSize: 10)),
    ]),
  ));
}

// ═══════════════════════════════════════════════════════════════════════════
// Filter Bar
// ═══════════════════════════════════════════════════════════════════════════
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
      color: _white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Column(children: [
        // Fila 1: Chips período + dropdowns
        Row(children: [
          for (final p in ['Hoy', 'Semana', 'Mes', 'Todo'])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(p, style: TextStyle(
                    fontSize: 12,
                    color: periodo == p ? _red : _textSec,
                    fontWeight: periodo == p ? FontWeight.w700 : FontWeight.w400)),
                selected: periodo == p,
                selectedColor: Colors.red.shade50,
                checkmarkColor: _red,
                side: BorderSide(color: periodo == p ? _red : _border),
                backgroundColor: _white,
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
        ]),
        const SizedBox(height: 8),
        // Fila 2: Búsqueda
        SizedBox(
          height: 36,
          child: TextField(
            controller: searchCtrl,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Buscar por folio, cliente, sucursal o técnico...',
              hintStyle: const TextStyle(color: _textSec, fontSize: 12),
              prefixIcon: const Icon(Icons.search, size: 16, color: _textSec),
              suffixIcon: query.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.close, size: 14),
                      onPressed: onClear)
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _red),
              ),
              filled: true,
              fillColor: _white,
            ),
            onChanged: onSearch,
          ),
        ),
      ]),
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
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(6),
        color: _white,
      ),
      child: DropdownButton<String>(
        value: value,
        isDense: true,
        underline: const SizedBox(),
        style: const TextStyle(fontSize: 12, color: _textPrim),
        items: const [
          DropdownMenuItem(
            value: 'Todas las Modalidades',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.layers_outlined, size: 14, color: _textSec),
                SizedBox(width: 6),
                Text('Todas las Modalidades',
                    style: TextStyle(fontSize: 12, color: _textPrim, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          DropdownMenuItem(
            value: 'Solo Físicos',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.description_outlined, size: 14, color: Color(0xFF7C3AED)),
                SizedBox(width: 6),
                Text('Solo Físicos',
                    style: TextStyle(fontSize: 12, color: Color(0xFF7C3AED), fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          DropdownMenuItem(
            value: 'Solo Digitales',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.devices_outlined, size: 14, color: Color(0xFF2563EB)),
                SizedBox(width: 6),
                Text('Solo Digitales',
                    style: TextStyle(fontSize: 12, color: Color(0xFF2563EB), fontWeight: FontWeight.w600)),
              ],
            ),
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
  const _DropdownFilter({required this.hint, required this.value,
      required this.items, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(6),
        color: _white,
      ),
      child: DropdownButton<String>(
        value: value,
        hint: Text(hint, style: const TextStyle(fontSize: 12, color: _textSec)),
        isDense: true,
        underline: const SizedBox(),
        style: const TextStyle(fontSize: 12, color: _textPrim),
        items: [
          DropdownMenuItem<String>(value: null,
              child: Text(hint, style: const TextStyle(color: _textSec))),
          ...items.map((t) => DropdownMenuItem<String>(value: t, child: Text(t))),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Table Header
// ═══════════════════════════════════════════════════════════════════════════
class _TableHeader extends StatelessWidget {
  final bool hideTecnico;
  const _TableHeader({this.hideTecnico = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _tableHead,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(children: [
        const _TH('FOLIO OS',           flex: 2),
        const _TH('FECHA',              flex: 2),
        const _TH('CLIENTE / SUCURSAL', flex: 4),
        if (!hideTecnico)
          const _TH('TÉCNICO',          flex: 3),
        const _TH('TIPO SERVICIO',      flex: 3),
        const _TH('MODALIDAD',          flex: 2),
        const _TH('ESTATUS',            flex: 2),
        const _TH('SYNC',               flex: 2),
        const _TH('ACCIONES',           flex: 3),
      ]),
    );
  }
}

class _TH extends StatelessWidget {
  final String label;
  final int    flex;
  const _TH(this.label, {required this.flex});
  @override
  Widget build(BuildContext context) => Expanded(
    flex: flex,
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
        color: _tableText,
        letterSpacing: 0.5,
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// OS Row
// ═══════════════════════════════════════════════════════════════════════════
class _OsRow extends StatelessWidget {
  final Map<String, dynamic> os;
  final int index;
  final VoidCallback onCaptura;
  final bool indent;
  final bool hideTecnico;

  const _OsRow({
    required this.os,
    required this.index,
    required this.onCaptura,
    this.indent = false,
    this.hideTecnico = false,
  });

  @override
  Widget build(BuildContext context) {
    final estado    = (os['estado']    as String? ?? 'PROCESO').toUpperCase();
    final modalidad = (os['modalidad'] as String? ?? 'DIGITAL').toUpperCase();
    final syncSt    = (os['sync_status'] as String? ?? '');
    final isFisico  = modalidad.contains('FISIC');
    final isEven    = index % 2 == 0;

    final Color estadoFg = switch (estado) {
      'COMPLETADA' || 'FIRMADA' || 'CERRADO'
      || 'COMPLETADA_DIGITAL' || 'COMPLETADA_FISICA' => Colors.green.shade700,
      'PROCESO'   => const Color(0xFFC8102E),
      'CANCELADA' => Colors.grey.shade600,
      _           => Colors.grey.shade600,
    };

    final bool isCerrado = {'COMPLETADA', 'FIRMADA', 'CERRADO',
        'COMPLETADA_DIGITAL', 'COMPLETADA_FISICA'}.contains(estado);

    final String estadoLabel = switch (estado) {
      'COMPLETADA' || 'COMPLETADA_DIGITAL'
      || 'COMPLETADA_FISICA' => 'Cerrado',
      'FIRMADA'   => 'Firmado',
      'CERRADO'   => 'Cerrado',
      'PROCESO'   => 'Proceso',
      'CANCELADA' => 'Cancelado',
      _           => _cap(estado),
    };

    final bool isSincronizado = syncSt == 'SINCRONIZADO' ||
        syncSt == 'SINCRONIZADO_RENDER' ||
        (isCerrado && syncSt != 'PENDIENTE_ACTUALIZAR');

    final fechaStr = _formatFecha(os['fecha'] as String?);

    return Container(
      color: isEven ? _white : const Color(0xFFFAFAFA),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(children: [
        // FOLIO OS (flex 2) - alineado a la izquierda
        Expanded(
          flex: 2,
          child: Padding(
            padding: EdgeInsets.only(left: indent ? 14.0 : 0.0),
            child: Row(
              children: [
                if (indent)
                  const Padding(
                    padding: EdgeInsets.only(right: 3),
                    child: Icon(Icons.subdirectory_arrow_right, size: 13, color: _textSec),
                  ),
                Expanded(
                  child: Text(
                    os['folio_os'] ?? '—',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: Color(0xFFC8102E),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),

        // FECHA (flex 2) - YYYY-MM-DD
        Expanded(
          flex: 2,
          child: Text(
            fechaStr,
            style: const TextStyle(fontSize: 11, color: _textPrim),
            overflow: TextOverflow.ellipsis,
          ),
        ),

        // CLIENTE / SUCURSAL (flex 4)
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                os['cliente'] ?? '—',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _textPrim),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              if ((os['sucursal'] ?? '').toString().isNotEmpty)
                Text(
                  os['sucursal']!.toString(),
                  style: const TextStyle(fontSize: 10, color: _textSec),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
            ],
          ),
        ),

        // TÉCNICO (flex 3) - oculto para rol técnico
        if (!hideTecnico)
          Expanded(
            flex: 3,
            child: Text(
              os['tecnico'] ?? '—',
              style: const TextStyle(fontSize: 11, color: _textPrim),
              overflow: TextOverflow.ellipsis,
            ),
          ),

        // TIPO SERVICIO (flex 3)
        Expanded(
          flex: 3,
          child: Text(
            os['tipo_servicio'] ?? '—',
            style: const TextStyle(fontSize: 11, color: _textSec),
            overflow: TextOverflow.ellipsis,
          ),
        ),

        // MODALIDAD (flex 2)
        Expanded(
          flex: 2,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _Badge(
              label: isFisico ? 'Físico' : 'Digital',
              fg: isFisico ? const Color(0xFF7C3AED) : const Color(0xFF2563EB),
              bg: isFisico ? const Color(0xFFF3F0FF) : const Color(0xFFEFF6FF),
            ),
          ),
        ),

        // ESTATUS (flex 2)
        Expanded(
          flex: 2,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _Badge(
              label: estadoLabel,
              fg: estadoFg,
              bg: estadoFg.withValues(alpha: 0.08),
            ),
          ),
        ),

        // SYNC (flex 2)
        Expanded(
          flex: 2,
          child: Align(
            alignment: Alignment.centerLeft,
            child: isSincronizado
                ? _Badge(label: 'Sincronizado', fg: Colors.green.shade700, bg: Colors.green.shade50)
                : _Badge(label: 'Pendiente', fg: Colors.orange.shade700, bg: Colors.orange.shade50),
          ),
        ),

        // ACCIONES (flex 3)
        Expanded(
          flex: 3,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isFisico)
                _ActionBtn(
                  label: 'Adjuntar',
                  icon: Icons.document_scanner_outlined,
                  fg: _white,
                  bg: const Color(0xFF7C3AED),
                  onTap: () {
                    final ctx = context;
                    if (ctx.mounted) {
                      ctx.push('/escaneo', extra: {'folio_os': os['folio_os'] ?? ''});
                    }
                  },
                )
              else if (isCerrado)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ActionBtn(
                      label: 'Ver PDF',
                      icon: Icons.picture_as_pdf_outlined,
                      fg: _white,
                      bg: const Color(0xFF2563EB),
                      onTap: () async {
                        final folio = os['folio_os'] as String? ?? '';
                        final ctx = context;
                        final localPath = os['pdf_path_local'] as String? ?? '';
                        if (localPath.isNotEmpty && await File(localPath).exists()) {
                          await OpenFilex.open(localPath);
                          return;
                        }
                        try {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(
                                content: Text('Descargando PDF oficial...'),
                                duration: Duration(seconds: 2),
                                backgroundColor: Color(0xFF2563EB),
                              ),
                            );
                          }
                          final path = await ApiService.instance.downloadPdf('/api/ordenes/$folio/pdf');
                          await OpenFilex.open(path);
                        } catch (e) {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text('PDF no disponible: ${e.toString().replaceAll('HttpException: ', '')}'),
                                backgroundColor: Colors.red.shade700,
                              ),
                            );
                          }
                        }
                      },
                    ),
                    const SizedBox(width: 4),
                    _ActionBtn(
                      label: 'Editar',
                      icon: Icons.edit_outlined,
                      fg: _white,
                      bg: const Color(0xFF16A34A),
                      onTap: onCaptura,
                    ),
                  ],
                )
              else
                _ActionBtn(
                  label: 'Llenar OS',
                  icon: Icons.edit_note_outlined,
                  fg: _white,
                  bg: const Color(0xFF16A34A),
                  onTap: onCaptura,
                ),
            ],
          ),
        ),
      ]),
    );
  }

  String _formatFecha(String? f) {
    if (f == null || f.isEmpty) return '—';
    final clean = f.split('T').first.split(' ').first;
    return clean.isNotEmpty ? clean : '—';
  }

  String _cap(String s) => s.isEmpty ? s : s[0] + s.substring(1).toLowerCase();
} // fin _OsRow

// ── Badge ─────────────────────────────────────────────────────────────────
class _Badge extends StatelessWidget {
  final String label;
  final Color  fg, bg;
  const _Badge({required this.label, required this.fg, required this.bg});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: TextStyle(fontSize: 10, color: fg,
        fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
  );
}

// ── Action Button ─────────────────────────────────────────────────────────
class _ActionBtn extends StatelessWidget {
  final String label; final IconData icon;
  final Color fg, bg; final VoidCallback onTap;
  const _ActionBtn({required this.label, required this.icon,
      required this.fg, required this.bg, required this.onTap});
  @override
  Widget build(BuildContext context) => ElevatedButton.icon(
    style: ElevatedButton.styleFrom(
      backgroundColor: bg, foregroundColor: fg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      elevation: 0,
    ),
    onPressed: onTap,
    icon: Icon(icon, size: 12),
    label: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// Empty State
// ═══════════════════════════════════════════════════════════════════════════
class _EmptyState extends StatelessWidget {
  final VoidCallback onSync;
  const _EmptyState({required this.onSync});
  @override
  Widget build(BuildContext context) => Center(child: Column(
      mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.assignment_outlined, size: 72, color: Colors.grey.shade300),
    const SizedBox(height: 16),
    const Text('No hay registros para este período',
        style: TextStyle(fontSize: 16, color: _textSec)),
    const SizedBox(height: 4),
    const Text('Sincroniza para descargar las órdenes del servidor',
        style: TextStyle(fontSize: 12, color: _textSec)),
    const SizedBox(height: 16),
    ElevatedButton.icon(
      onPressed: onSync,
      icon: const Icon(Icons.sync),
      label: const Text('Sincronizar con servidor'),
      style: ElevatedButton.styleFrom(
        backgroundColor: _red, foregroundColor: _white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  ]));
}

// ════════════════════════════════════════════════════════════════════════════
// Modelo de grupo de OS
// ════════════════════════════════════════════════════════════════════════════
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

// ════════════════════════════════════════════════════════════════════════════
// Fila de Lote — acordeón desplegable
// ════════════════════════════════════════════════════════════════════════════
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

  String get _rangoLabel {
    final items = [...widget.group.items];
    items.sort((a, b) {
      int _num(Map<String, dynamic> o) {
        final f = o['folio_os'] as String? ?? '';
        final m = RegExp(r'\d+').allMatches(f);
        return m.isEmpty ? 0 : int.tryParse(m.last.group(0)!) ?? 0;
      }
      return _num(a).compareTo(_num(b));
    });
    final folios = items
        .map((o) => o['folio_os'] as String? ?? '')
        .where((f) => f.isNotEmpty)
        .toList();
    if (folios.isEmpty) return widget.group.loteKey;
    final count = folios.length;
    if (count == 1) return '${folios.first} (1 OS)';
    return '${folios.first} al ${folios.last} ($count OS)';
  }

  List<Map<String, dynamic>> get _sortedItems {
    final items = [...widget.group.items];
    items.sort((a, b) {
      int _num(Map<String, dynamic> o) {
        final f = o['folio_os'] as String? ?? '';
        final m = RegExp(r'\d+').allMatches(f);
        return m.isEmpty ? 0 : int.tryParse(m.last.group(0)!) ?? 0;
      }
      return _num(a).compareTo(_num(b));
    });
    return items;
  }

  String _formatFecha(String? f) {
    if (f == null || f.isEmpty) return '—';
    final clean = f.split('T').first.split(' ').first;
    return clean.isNotEmpty ? clean : '—';
  }

  @override
  Widget build(BuildContext context) {
    final first   = widget.group.items.first;
    final count   = _sortedItems.length;
    final estado  = (first['estado'] as String? ?? 'PROCESO').toUpperCase();
    final modal   = (first['modalidad'] as String? ?? 'FISICO').toUpperCase();
    final isFis   = modal.contains('FISIC');
    final pdfUrl  = first['pdf_url'] as String?;

    final Color estFg = switch (estado) {
      'COMPLETADA' || 'FIRMADA' || 'CERRADO' => Colors.green.shade700,
      'PROCESO' => const Color(0xFFC8102E),
      _ => Colors.grey.shade600,
    };

    final fechaStr = _formatFecha(first['fecha'] as String?);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          color: const Color(0xFFFFF7ED),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: _border),
              left: const BorderSide(color: Color(0xFFC8102E), width: 3),
            ),
          ),
          child: Row(children: [
            // FOLIO / LOTE (flex 2)
            Expanded(
              flex: 2,
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.chevron_right, size: 18, color: Color(0xFFC8102E)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFC8102E),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'LOTE · $count OS',
                            style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _rangoLabel,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 10.5, color: Color(0xFFC8102E)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // FECHA (flex 2)
            Expanded(
              flex: 2,
              child: Text(
                fechaStr,
                style: const TextStyle(fontSize: 11, color: _textPrim),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // CLIENTE / SUCURSAL (flex 4)
            Expanded(
              flex: 4,
              child: Text(
                first['cliente'] ?? '—',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _textPrim),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // TÉCNICO (flex 3) - solo si !hideTecnico
            if (!widget.hideTecnico)
              Expanded(
                flex: 3,
                child: Text(
                  first['tecnico'] ?? '—',
                  style: const TextStyle(fontSize: 11, color: _textPrim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),

            // TIPO SERVICIO (flex 3)
            Expanded(
              flex: 3,
              child: Text(
                first['tipo_servicio'] ?? '—',
                style: const TextStyle(fontSize: 11, color: _textSec),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // MODALIDAD (flex 2)
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _Badge(
                  label: isFis ? 'Físico · $count OS' : 'Digital · $count OS',
                  fg: isFis ? const Color(0xFF7C3AED) : const Color(0xFF2563EB),
                  bg: isFis ? const Color(0xFFF3F0FF) : const Color(0xFFEFF6FF),
                ),
              ),
            ),

            // ESTATUS (flex 2)
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _Badge(
                  label: estado[0] + estado.substring(1).toLowerCase(),
                  fg: estFg,
                  bg: estFg.withOpacity(0.08),
                ),
              ),
            ),

            // SYNC (flex 2)
            const Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _Badge(
                  label: 'Sincronizado',
                  fg: Colors.green,
                  bg: Color(0xFFDCFCE7),
                ),
              ),
            ),

            // ACCIONES (flex 3)
            Expanded(
              flex: 3,
              child: pdfUrl != null && pdfUrl.isNotEmpty
                  ? ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4B5563),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        elevation: 0,
                      ),
                      onPressed: () => _openPdfLote(context, pdfUrl),
                      icon: const Icon(Icons.picture_as_pdf_outlined, size: 12),
                      label: const Text('Ver Lote (PDF)', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                    )
                  : const SizedBox(),
            ),
          ]),
        ),
      ),

      // OS hijas del lote
      if (_expanded)
        for (int i = 0; i < _sortedItems.length; i++)
          Container(
            color: const Color(0xFFFEF9F0),
            child: _OsRow(
              os: _sortedItems[i],
              index: i,
              onCaptura: () => widget.onCaptura(_sortedItems[i]),
              indent: true,
              hideTecnico: widget.hideTecnico,
            ),
          ),
    ]);
  }

  void _openPdfLote(BuildContext context, String pdfUrl) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: _red),
          SizedBox(width: 16),
          Text('Descargando PDF del Lote...'),
        ]),
      ),
    );
    try {
      final localPath = await ApiService.instance.downloadPdf(pdfUrl);
      if (context.mounted) Navigator.of(context).pop();
      await OpenFilex.open(localPath);
    } catch (e) {
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'),
              backgroundColor: Colors.red.shade700),
        );
      }
    }
  }
}