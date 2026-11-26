// lib/screens/firma_screen.dart
// Captura de DOBLE firma digital (Tecnico + Ingeniero de Planta / Cliente)
// 100% offline — guarda en SQLite local, sincroniza cuando haya red.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../widgets/nombre_recibe.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:signature/signature.dart';
import 'package:open_filex/open_filex.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../services/sync_service.dart';
import '../services/pdf_service.dart';
import '../services/auth_service.dart';
import '../services/firma_tecnico_service.dart';
import '../theme/foldable_layout.dart';
import '../theme/pesa_theme.dart';
import '../widgets/cliente_correo_poka_yoke.dart';
import '../widgets/pesa_components.dart';
import '../widgets/signature_shield.dart';

class FirmaScreen extends StatefulWidget {
  final int osId;
  final Map<String, dynamic> capturaData;
  const FirmaScreen({super.key, required this.osId, required this.capturaData});

  @override
  State<FirmaScreen> createState() => _FirmaScreenState();
}

class _FirmaScreenState extends State<FirmaScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  // ── Controladores de lienzo ───────────────────────────────────────────────
  final _ctrlTecnico = SignatureController(
      penStrokeWidth: 3, penColor: const Color(0xFF1D1D1F));
  final _ctrlCliente = SignatureController(
      penStrokeWidth: 3, penColor: const Color(0xFF1D1D1F));

  // ── Campos de texto para el ingeniero/cliente ─────────────────────────────
  final _nombreIngCtrl = TextEditingController();
  final _puestoIngCtrl = TextEditingController();
  final _correoCtrl    = ClienteCorreoController();
  final _formKey        = GlobalKey<FormState>();

  bool _saving = false;

  // ── Colores del tema PESA ─────────────────────────────────────────────────
  static const _red = Color(0xFFC8102E);

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    final cli = (widget.capturaData['cliente'] ?? widget.capturaData['cliente_nombre'] ?? widget.capturaData['razon_social'] ?? '').toString().trim();
    final initialNombre = (widget.capturaData['firma_cliente_nombre'] ?? widget.capturaData['nombre_ing'] ?? '').toString().trim();
    // REGLA ESTRICTA: El campo NO debe llenarse con la razón social del cliente. Debe comenzar VACÍO.
    if (initialNombre.isNotEmpty && !esRazonSocialEmpresa(initialNombre, cli)) {
      _nombreIngCtrl.text = initialNombre;
    } else {
      _nombreIngCtrl.text = '';
    }
    final initialPuesto = (widget.capturaData['puesto_ing'] ?? '').toString().trim();
    if (initialPuesto.isNotEmpty) {
      _puestoIngCtrl.text = initialPuesto;
    }
    _correoCtrl.inicializarDesdeOrden(widget.capturaData);
    _cargarFirmasExistentes();
    _cargarContactosPlanta();
  }

  List<String> _contactosSugeridos = [];

  Future<void> _cargarContactosPlanta() async {
    final cli = (widget.capturaData['cliente'] ?? widget.capturaData['cliente_nombre'] ?? '').toString().trim();
    final pla = (widget.capturaData['direccion'] ?? widget.capturaData['sucursal'] ?? '').toString().trim();
    if (cli.isEmpty) return;
    final contacts = await LocalDbService.instance.getContactosPlanta(cliente: cli, planta: pla);
    // Filtrar para que la razón social de la empresa nunca aparezca como sugerencia de contacto
    final filtered = contacts.where((c) => !esRazonSocialEmpresa(c, cli)).toList();
    if (mounted) {
      setState(() {
        _contactosSugeridos = filtered;
        // Debe comenzar VACÍO: no autollenar con contacts.first
      });
    }
  }

  // ── Estado de firmas (Técnico y Cliente) ──────────────────────────────────
  bool    _firmaTecPrecargada = false;  // true = firma técnico cargada desde orden o perfil
  String? _firmaTecBase64Guardada;
  bool    _firmaCliPrecargada = false;  // true = firma cliente ya registrada en la orden
  String? _firmaCliBase64Guardada;

  /// Carga las firmas existentes (técnico y cliente) de la orden, BD local o perfil.
  Future<void> _cargarFirmasExistentes() async {
    // 1. Firma del Técnico — PRIORIDAD: Perfil oficial > OS actual > SQLite.
    //    La firma registrada en "Mi Firma Digital" gana sobre cualquier trazo
    //    residual guardado en la orden (evita estampar trazos accidentales).
    final auth      = context.read<AuthService>();
    final username  = auth.username ?? '';
    final idLogeado = auth.idTecnico ?? 0;
    final idOrden   = int.tryParse('${widget.capturaData['id_tecnico'] ?? ''}') ?? 0;
    final esTecnicoAsignado = idOrden <= 0 || idLogeado <= 0 || idOrden == idLogeado;

    String? firmaTec;
    if (esTecnicoAsignado) {
      final perfil = await FirmaTecnicoService.instance.getFirma(username, idTecnico: idLogeado);
      if (perfil != null && perfil.trim().length > 50) firmaTec = perfil.trim();
    }
    if (firmaTec == null) {
      final tecOs = (widget.capturaData['firma_tecnico'] ?? widget.capturaData['firma_tecnico_b64'] ?? '').toString().trim();
      if (tecOs.length > 50) firmaTec = tecOs;
    }
    if (firmaTec == null && widget.osId > 0) {
      final osRow = await LocalDbService.instance.getOs(widget.osId);
      final tecDb = (osRow?['firma_tecnico'] ?? osRow?['firma_tecnico_b64'] ?? '').toString().trim();
      if (tecDb.length > 50) firmaTec = tecDb;
    }
    if (firmaTec != null && mounted) {
      setState(() {
        _firmaTecPrecargada     = true;
        _firmaTecBase64Guardada = firmaTec;
      });
    }

    // 2. Firma del Cliente: OS actual > SQLite
    final cliOs = (widget.capturaData['firma_cliente'] ?? widget.capturaData['firma_cliente_b64'] ?? '').toString().trim();
    if (cliOs.length > 50) {
      if (mounted) {
        setState(() {
          _firmaCliPrecargada = true;
          _firmaCliBase64Guardada = cliOs;
        });
      }
    } else if (widget.osId > 0) {
      final osRow = await LocalDbService.instance.getOs(widget.osId);
      if (osRow != null) {
        await _correoCtrl.inicializarDesdeOrden({...osRow, ...widget.capturaData});
      }
      final cliDb = (osRow?['firma_cliente'] ?? osRow?['firma_cliente_b64'] ?? '').toString().trim();
      if (cliDb.length > 50 && mounted) {
        setState(() {
          _firmaCliPrecargada = true;
          _firmaCliBase64Guardada = cliDb;
        });
      }
    } else {
      final fol = (widget.capturaData['folio_os'] ?? widget.capturaData['folio'] ?? '').toString().trim();
      if (fol.isNotEmpty) {
        final osRow = await LocalDbService.instance.getOsByFolio(fol);
        if (osRow != null) {
          await _correoCtrl.inicializarDesdeOrden({...osRow, ...widget.capturaData});
        }
      }
    }
  }

  @override
  void dispose() {
    _ctrlTecnico.dispose();
    _ctrlCliente.dispose();
    _nombreIngCtrl.dispose();
    _puestoIngCtrl.dispose();
    _correoCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final folio = widget.capturaData['folio_os'] as String? ?? 'OS';
    final bool cover = isCoverScreen(context);

    return Scaffold(
      backgroundColor: PesaColors.canvas,
      appBar: AppBar(
        backgroundColor: PesaColors.surface,
        foregroundColor: PesaColors.textPrimary,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Firmas — $folio',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17, color: PesaColors.textPrimary)),
            if ((widget.capturaData['cliente'] ?? '').toString().isNotEmpty)
              Text(
                widget.capturaData['cliente'].toString(),
                style: const TextStyle(fontSize: 11.5, color: PesaColors.textSecondary),
              ),
          ],
        ),
        bottom: cover
            ? PreferredSize(
                preferredSize: const Size.fromHeight(50),
                child: Container(
                  decoration: const BoxDecoration(
                    color: PesaColors.surface,
                    border: Border(
                      top: BorderSide(color: PesaColors.divider),
                      bottom: BorderSide(color: PesaColors.border),
                    ),
                  ),
                  child: TabBar(
                    controller: _tabCtrl,
                    indicatorColor: _red,
                    indicatorWeight: 2.5,
                    labelColor: _red,
                    unselectedLabelColor: PesaColors.textSecondary,
                    labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    tabs: const [
                      Tab(
                        text: 'Firma Técnico',
                        icon: Icon(Icons.engineering_outlined, size: 18),
                      ),
                      Tab(
                        text: 'Firma Cliente',
                        icon: Icon(Icons.person_outline, size: 18),
                      ),
                    ],
                  ),
                ),
              )
            : const PreferredSize(
                preferredSize: Size.fromHeight(1),
                child: Divider(height: 1, color: PesaColors.border),
              ),
      ),
      body: SafeArea(
        top: false,
        bottom: true,
        child: Column(
          children: [
            _buildResumenBar(),
            Expanded(
              child: Form(
                key: _formKey,
                child: cover
                    ? TabBarView(
                        controller: _tabCtrl,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          _buildTabTecnico(),
                          _buildTabCliente(),
                        ],
                      )
                    : FoldableTwoPane(
                        startFraction: 0.48,
                        minStartWidth: 280,
                        maxStartWidth: 640,
                        startPane: _buildTabTecnico(),
                        endPane: _buildTabCliente(),
                      ),
              ),
            ),
            _buildActionBar(),
          ],
        ),
      ),
    );
  }

  // ── Barra de resumen corporativa ──────────────────────────────────────────

  Widget _buildResumenBar() {
    final dictamen = widget.capturaData['dictamen'] as String? ?? 'APTO';
    final isApto   = dictamen == 'APTO';
    final obsTxt   = _trunc(widget.capturaData['observaciones'] as String? ?? '', 60);
    return Container(
      decoration: const BoxDecoration(
        color: PesaColors.surface,
        border: Border(bottom: BorderSide(color: PesaColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        PesaStatusBadge(
          label: 'Dictamen: $dictamen',
          dotColor: isApto ? PesaColors.dotGreen : PesaColors.dotAmber,
        ),
        if (obsTxt.isNotEmpty) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Obs: $obsTxt',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: PesaColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ]),
    );
  }

  // ── Tab 1 — Firma del Tecnico ─────────────────────────────────────────────

  Widget _buildTabTecnico() {
    final tecnico = widget.capturaData['tecnico'] as String? ?? 'Tecnico';
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Encabezado
          Row(children: [
            const Icon(Icons.engineering, color: _red),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Firma del Tecnico Metrológico',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  Text(tecnico,
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
            // Si está precargada mostramos badge OK, si no, el estado del canvas
            _firmaTecPrecargada
                ? _badgePrecargada()
                : _firmaEstadoBadge(_ctrlTecnico),
          ]),
          const SizedBox(height: 12),

          // Si la firma ya está guardada en perfil → mostrar aviso, no canvas
          if (_firmaTecPrecargada) ...[
            Expanded(
              child: PesaCard(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const PesaStatusBadge(
                    label: 'Firma del perfil lista',
                    dotColor: PesaColors.dotGreen,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Firma del Técnico cargada desde tu perfil',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: PesaColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Se usará tu firma registrada al inicio de sesión.\n'
                    'No es necesario firmar de nuevo.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: PesaColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: () => setState(() {
                      _firmaTecPrecargada    = false;
                      _firmaTecBase64Guardada = null;
                      _ctrlTecnico.clear();
                    }),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Firmar nuevamente en esta orden'),
                  ),
                ]),
              ),
            ),
          ] else ...[
            Expanded(child: _buildCanvas(_ctrlTecnico)),
            const SizedBox(height: 10),
            _buildClearBtn(_ctrlTecnico, 'Técnico'),
          ],
        ],
      ),
    );
  }

  Widget _badgePrecargada([String texto = 'Del perfil']) {
    return PesaStatusBadge(
      label: texto,
      dotColor: PesaColors.dotGreen,
    );
  }

  // ── Tab 2 — Firma del Ingeniero / Cliente ─────────────────────────────────

  Widget _buildTabCliente() {
    final String loteId = (widget.capturaData['id_lote'] ?? widget.capturaData['lote'] ?? '').toString().trim();
    return SigningScrollLock(
      builder: (ctx, scrollPhysics, _) => LayoutBuilder(
        builder: (context, constraints) {
          final double canvasHeight = (constraints.maxHeight - 330).clamp(180.0, 320.0);
          return SingleChildScrollView(
            physics: scrollPhysics,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Encabezado
                Row(children: [
                  const Icon(Icons.person_outline, color: _red),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Firma del Ingeniero de Planta / Cliente',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  _firmaCliPrecargada
                      ? _badgePrecargada('Validada')
                      : _firmaEstadoBadge(_ctrlCliente),
                ]),
                const SizedBox(height: 12),

                // Campos de nombre y puesto (apilados en cover < 600dp, 2 cols en desplegado)
                FoldableTwoColumn(
                  firstFlex: 3,
                  secondFlex: 2,
                  horizontalGap: 10,
                  verticalGap: 10,
                  first: TextFormField(
                    controller: _nombreIngCtrl,
                    textCapitalization: TextCapitalization.words,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    decoration: const InputDecoration(
                      labelText: 'Nombre de quien recibe *',
                      hintText: 'Ing. Juan Pérez',
                      prefixIcon: Icon(Icons.badge_outlined),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    validator: validarNombreRecibe,
                  ),
                  second: TextFormField(
                    controller: _puestoIngCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Puesto / Cargo',
                      hintText: 'Jefe de Produccion',
                      prefixIcon: Icon(Icons.work_outline),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                // Chip de sugerencia de sesión de lote (si otra orden del mismo lote ya registró responsable)
                Builder(
                  builder: (context) {
                    final String? respLote = LoteSession.getUltimoResponsable(loteId);
                    final String? puestoLote = LoteSession.getUltimoPuesto(loteId);
                    if (respLote == null || respLote.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 6.0),
                      child: Row(
                        children: [
                          const Icon(Icons.layers, size: 14, color: _red),
                          const SizedBox(width: 4),
                          const Text('Responsable del Lote: ',
                              style: TextStyle(fontSize: 11, color: _red, fontWeight: FontWeight.bold)),
                          ActionChip(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: PesaColors.surfaceMuted,
                            side: const BorderSide(color: _red),
                            avatar: const Icon(Icons.touch_app, size: 13, color: _red),
                            label: Text(respLote, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: PesaColors.textPrimary)),
                            onPressed: () {
                              setState(() {
                                _nombreIngCtrl.text = respLote;
                                if (puestoLote != null && puestoLote.isNotEmpty) {
                                  _puestoIngCtrl.text = puestoLote;
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
                if (_contactosSugeridos.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.history, size: 14, color: Colors.grey),
                      const SizedBox(width: 4),
                      const Text('Contactos registrados en planta: ',
                          style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500)),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _contactosSugeridos.map((contacto) {
                              final isSelected = _nombreIngCtrl.text.trim().toLowerCase() == contacto.toLowerCase();
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ActionChip(
                                  visualDensity: VisualDensity.compact,
                                  backgroundColor: isSelected ? PesaColors.surfaceMuted : Colors.white,
                                  side: BorderSide(color: isSelected ? _red : PesaColors.borderStrong),
                                  avatar: Icon(Icons.person_outline, size: 13, color: isSelected ? _red : PesaColors.textSecondary),
                                  label: Text(contacto, style: TextStyle(fontSize: 11.5, color: isSelected ? _red : PesaColors.textPrimary, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                                  onPressed: () {
                                    setState(() {
                                      _nombreIngCtrl.text = contacto;
                                    });
                                  },
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),

                // ── CANDADO POKA-YOKE: Correo del Cliente obligatorio justo encima del pad de firma ──
                ClienteCorreoPokaYokeCard(
                  controller: _correoCtrl,
                  loteId: loteId,
                ),

                // Si la firma ya fue sincronizada previamente, mostrar estado validado
                if (_firmaCliPrecargada) ...[
                  PesaCard(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const PesaStatusBadge(
                        label: 'Firma del cliente validada',
                        dotColor: PesaColors.dotGreen,
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Firma del Cliente registrada previamente',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: PesaColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Esta orden ya cuenta con la firma del cliente sincronizada.\n'
                        'No es necesario volver a solicitarla.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: PesaColors.textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 18),
                      OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _firmaCliPrecargada     = false;
                          _firmaCliBase64Guardada = null;
                          _ctrlCliente.clear();
                        }),
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('Volver a firmar en esta orden'),
                      ),
                    ]),
                  ),
                ] else ...[
                  SizedBox(height: canvasHeight, child: _buildCanvas(_ctrlCliente)),
                  const SizedBox(height: 10),
                  _buildClearBtn(_ctrlCliente, 'Cliente'),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Widgets reutilizables ─────────────────────────────────────────────────

  Widget _buildCanvas(SignatureController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, __) => LayoutBuilder(
        builder: (context, constraints) => PesaSignatureFrame(
          height: constraints.maxHeight.isFinite && constraints.maxHeight > 120
              ? constraints.maxHeight
              : 220,
          hasSignature: ctrl.isNotEmpty,
          hintText: 'Firme sobre la línea con el lápiz o dedo',
          child: SignatureGestureShield(
            child: Signature(controller: ctrl, backgroundColor: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildClearBtn(SignatureController ctrl, String quien) {
    return OutlinedButton.icon(
      onPressed: () => setState(ctrl.clear),
      icon: const Icon(Icons.cleaning_services_outlined, size: 16),
      label: Text('Limpiar firma $quien'),
    );
  }

  Widget _firmaEstadoBadge(SignatureController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, __) => PesaStatusBadge(
        label: ctrl.isNotEmpty ? 'Lista' : 'Pendiente',
        dotColor: ctrl.isNotEmpty ? PesaColors.dotGreen : PesaColors.dotAmber,
      ),
    );
  }

  // ── Barra de accion final ─────────────────────────────────────────────────

  Widget _buildActionBar() {
    return AnimatedBuilder(
      animation: _correoCtrl,
      builder: (_, __) {
        final bool bloqueadoPorCorreo = !_correoCtrl.isValido;
        return Container(
          decoration: const BoxDecoration(
            color: PesaColors.surface,
            border: Border(top: BorderSide(color: PesaColors.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _progressChip('Técnico', _ctrlTecnico, isPrecargada: _firmaTecPrecargada),
                    _progressChip('Ing./Cliente', _ctrlCliente, isPrecargada: _firmaCliPrecargada),
                    PesaStatusBadge(
                      label: _correoCtrl.isValido ? 'Correo: Listo' : 'Correo: Pendiente',
                      dotColor: _correoCtrl.isValido ? PesaColors.dotGreen : PesaColors.dotRed,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: ClienteCorreoLockBanner(controller: _correoCtrl),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                child: SafeArea(
                  top: false,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    alignment: WrapAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.arrow_back_rounded, size: 18),
                        label: const Text('Volver a Captura'),
                        onPressed: () {
                          if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go('/os');
                          }
                        },
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: PesaColors.brand,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: PesaColors.surfaceMuted,
                          disabledForegroundColor: PesaColors.textTertiary,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : Icon(bloqueadoPorCorreo ? Icons.lock_outline_rounded : Icons.picture_as_pdf_outlined, size: 19),
                        label: const Text('Confirmar Firma y Emitir PDF',
                            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                        onPressed: (_saving || bloqueadoPorCorreo) ? null : _onFinalizar,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _progressChip(String label, SignatureController ctrl, {bool isPrecargada = false}) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, __) {
        final ok = isPrecargada || ctrl.isNotEmpty;
        return PesaStatusBadge(
          label: '$label: ${ok ? "Lista" : "Pendiente"}',
          dotColor: ok ? PesaColors.dotGreen : PesaColors.dotAmber,
        );
      },
    );
  }

  // ── Logica de finalizacion ────────────────────────────────────────────────

  Future<void> _onFinalizar() async {
    // ── CANDADO METROLÓGICO: 6 CAMPOS OBLIGATORIOS DEL INSTRUMENTO ─────────
    final d = widget.capturaData;
    final marca = (d['marca'] ?? d['equipo_marca'] ?? '').toString().trim();
    final modelo = (d['modelo'] ?? d['equipo_modelo'] ?? '').toString().trim();
    final idEquipo = (d['id_equipo'] ?? d['id_indicador'] ?? '').toString().trim();
    final capMax = (d['capacidad_max'] ?? d['cap_max'] ?? d['alcance_max'] ?? '').toString().trim();
    final divMin = (d['division_minima'] ?? d['div_min'] ?? d['div_minima'] ?? '').toString().trim();
    final ubic = (d['ubicacion'] ?? d['equipo_ubicacion'] ?? '').toString().trim();

    final List<String> faltantesInst = [];
    if (marca.isEmpty)    faltantesInst.add('Marca');
    if (modelo.isEmpty)   faltantesInst.add('Modelo');
    if (idEquipo.isEmpty) faltantesInst.add('ID Indicador / Equipo');
    if (capMax.isEmpty)   faltantesInst.add('Capacidad Máxima');
    if (divMin.isEmpty)   faltantesInst.add('División Mínima (d)');
    if (ubic.isEmpty)     faltantesInst.add('Ubicación');

    if (faltantesInst.isNotEmpty) {
      final listaStr = faltantesInst.map((f) => '• $f').join('\n');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Faltan datos del instrumento: ${faltantesInst.join(", ")}'),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ));
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Color(0xFFC8102E), size: 28),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Datos del Instrumento Incompletos',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Text(
            'Faltan datos obligatorios del instrumento:\n\n'
            '$listaStr\n\n'
            'Complétalos en la pestaña \'Instrumento\' para poder firmar y generar el documento.',
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC8102E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).pop(); // Regresa a la pantalla de captura
              },
              child: const Text('Volver a Instrumento'),
            ),
          ],
        ),
      );
      return;
    }

    // Validar firma del tecnico:
    // Si está precargada desde perfil → OK. Si no, requiere dibujo en canvas.
    if (!_firmaTecPrecargada && _ctrlTecnico.isEmpty) {
      _tabCtrl.animateTo(0);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('La firma del Técnico es obligatoria'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    // NOMBRE DE QUIEN RECIBE: ESTRICTAMENTE OBLIGATORIO (la firma del cliente es opcional).
    final String cli = (widget.capturaData['cliente'] ?? widget.capturaData['cliente_nombre'] ?? '').toString().trim();
    final String nombreRecibe = _nombreIngCtrl.text.trim();
    if (!exigirNombreRecibe(context, nombreRecibe, clienteEmpresa: cli)) {
      _tabCtrl.animateTo(1);
      // Resaltar el campo cuando la pestaña termine de construirse.
      WidgetsBinding.instance.addPostFrameCallback((_) => _formKey.currentState?.validate());
      return;
    }
    if (_formKey.currentState?.validate() == false) {
      _tabCtrl.animateTo(1);
      return;
    }

    // Registrar en memoria de lote para órdenes hermanas
    final String loteId = (widget.capturaData['id_lote'] ?? widget.capturaData['lote'] ?? '').toString().trim();
    if (loteId.isNotEmpty) {
      LoteSession.registrarResponsable(loteId, nombreRecibe, puesto: _puestoIngCtrl.text);
    }

    // CANDADO POKA-YOKE DE CORREO DEL CLIENTE (obligatorio tanto en orden individual como en lote)
    if (!_correoCtrl.isValido) {
      _tabCtrl.animateTo(1);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(kMsgPokaYokeCorreo),
        backgroundColor: PesaColors.brand,
      ));
      return;
    }

    final String folioPersist = (widget.capturaData['folio_os'] ?? widget.capturaData['folio'] ?? '').toString().trim();
    final String correoCapturado = await _correoCtrl.persistirEnOrdenYLote(
      folio: folioPersist,
      loteId: loteId,
      ordenMutable: widget.capturaData,
    );

    setState(() => _saving = true);
    String? pdfPath;

    try {
      // 1. Exportar firma tecnico → si vino precargada usar esa, si no exportar canvas
      String tecBase64 = '';
      if (_firmaTecPrecargada && _firmaTecBase64Guardada != null) {
        // Usar firma persistida del perfil
        tecBase64 = _firmaTecBase64Guardada!;
      } else {
        final auth     = context.read<AuthService>();
        final Uint8List? imgTec = await _ctrlTecnico.toPngBytes();
        tecBase64 = imgTec != null ? base64Encode(imgTec) : '';
        // Solo se registra como firma de PERFIL si el técnico aún no tiene una.
        // Un trazo hecho para esta orden NO debe reemplazar la firma oficial
        // registrada en "Mi Firma Digital" (eso se hace desde esa pantalla).
        if (tecBase64.isNotEmpty) {
          final username = auth.username ?? '';
          final idTec    = auth.idTecnico ?? 0;
          final yaTienePerfil =
              await FirmaTecnicoService.instance.tieneFirma(username, idTecnico: idTec);
          if (!yaTienePerfil) {
            if (idTec > 0) {
              FirmaTecnicoService.instance.saveAndSyncFirma(username, tecBase64, idTec)
                  .then((ok) => debugPrint('[Firma] Sync al servidor: ${ok ? "OK" : "WARN (no crítico)"}'));
            } else {
              FirmaTecnicoService.instance.saveFirma(username, tecBase64);
            }
          }
        }
      }

      // 2. Exportar firma cliente (si ya vino precargada usar esa, si no exportar canvas)
      String cliBase64 = '';
      if (_firmaCliPrecargada && _firmaCliBase64Guardada != null && _firmaCliBase64Guardada!.isNotEmpty) {
        cliBase64 = _firmaCliBase64Guardada!;
      } else if (_ctrlCliente.isNotEmpty) {
        final Uint8List? imgCli = await _ctrlCliente.toPngBytes();
        cliBase64 = imgCli != null ? base64Encode(imgCli) : '';
      }
      final folio     = widget.capturaData['folio_os'] as String? ?? '';
      final nombreIng = _nombreIngCtrl.text.trim();
      final puestoIng = _puestoIngCtrl.text.trim();

      // Guardar contacto asociado a la planta/cliente para memoria futura
      final cli = (widget.capturaData['cliente'] ?? widget.capturaData['cliente_nombre'] ?? '').toString();
      final pla = (widget.capturaData['direccion'] ?? widget.capturaData['sucursal'] ?? '').toString();
      if (nombreIng.isNotEmpty) {
        LocalDbService.instance.saveContactoPlanta(
          cliente: cli,
          planta: pla,
          nombreContacto: nombreIng,
        );
      }

      // 2. Guardar lecturas en SQLite
      final repRows  = _castList(widget.capturaData['rep_rows']);
      final excRows  = _castList(widget.capturaData['exc_rows']);
      final exacRows = _castList(widget.capturaData['exac_rows']);

      // 2.1 Actualizar fecha real de ejecución al finalizar servicio (OS)
      final String fechaEjecucionHoy = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final String fechaCierreIso = DateTime.now().toIso8601String();

      final osData = (widget.osId > 0 ? await LocalDbService.instance.getOs(widget.osId) : null)
          ?? (folio.isNotEmpty ? await LocalDbService.instance.getOsByFolio(folio) : null)
          ?? {};

      final ordenMutable = <String, dynamic>{
        ...osData,
        ...widget.capturaData,
        'folio_os':      folio,
        'observaciones': widget.capturaData['observaciones'] ?? '',
        'dictamen':      widget.capturaData['dictamen'] ?? 'APTO',
        'nombre_ing':    nombreIng,
        'puesto_ing':    puestoIng,
        'firma_cliente_nombre': nombreIng,
        'correo_cliente': correoCapturado.isNotEmpty ? correoCapturado : (osData['correo_cliente'] ?? ''),
        'correo_destino': correoCapturado.isNotEmpty ? correoCapturado : (osData['correo_destino'] ?? osData['correo_cliente'] ?? ''),
        'sin_correo_cliente': _correoCtrl.sinCorreoCliente,
        'motivo_sin_correo': _correoCtrl.motivoSinCorreoEfectivo,
        'email_enviado': 0,
      };
      ordenMutable['fecha_creacion_logistica'] = ordenMutable['fecha_creacion_logistica'] ?? ordenMutable['fecha'];
      ordenMutable['fecha'] = fechaEjecucionHoy;
      ordenMutable['fecha_servicio'] = fechaEjecucionHoy;
      ordenMutable['fecha_cierre'] = fechaCierreIso;
      final enrichedOs = ordenMutable;

      await LocalDbService.instance.actualizarFechaEjecucionAlFinalizar(
        folio,
        fechaEjecucionHoy,
        localId: widget.osId,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: ordenMutable['fecha_creacion_logistica']?.toString(),
      );

      // 3. Guardar ambas firmas + nombre/puesto del ingeniero + correo_cliente + fecha de ejecución
      await LocalDbService.instance.saveFirmas(
        localId:        widget.osId,
        folio:          folio,
        firmaTecBase64: tecBase64,
        firmaCliBase64: cliBase64,
        nombreIng:      nombreIng,
        puestoIng:      puestoIng,
        correoCliente:  correoCapturado.isNotEmpty ? correoCapturado : null,
        fechaEjecucion: fechaEjecucionHoy,
        fechaCierre:    fechaCierreIso,
        fechaCreacionLogistica: ordenMutable['fecha_creacion_logistica']?.toString(),
      );

      // 4. Generar PDF con ambas firmas, nombre del responsable y fecha real de ejecución

      if ((enrichedOs['direccion'] == null || enrichedOs['direccion'].toString().trim().isEmpty || enrichedOs['direccion'] == '-') &&
          (enrichedOs['sucursal'] == null || enrichedOs['sucursal'].toString().trim().isEmpty || enrichedOs['sucursal'] == '-')) {
        final cli = (enrichedOs['cliente'] ?? enrichedOs['cliente_nombre'] ?? '').toString();
        final histDir = await LocalDbService.instance.getDireccionCliente(cli);
        if (histDir != null && histDir.isNotEmpty) {
          enrichedOs['direccion'] = histDir;
          enrichedOs['sucursal'] = histDir;
        }
      }

      await LocalDbService.instance.saveLecturas(
        localId:       widget.osId,
        repRows:       repRows,
        excRows:       excRows,
        exacRows:      exacRows,
        observaciones: widget.capturaData['observaciones'] as String? ?? '',
        dictamen:      widget.capturaData['dictamen'] as String?,
        firmaClienteNombre: nombreIng,
        instrumentData: enrichedOs,
        unidadMedida:  (enrichedOs['unidad_medida'] ?? 'kg').toString(),
      );

      pdfPath = await PdfService.instance.generarPdfFinal(
        osData:         enrichedOs,
        repRows:        repRows,
        excRows:        excRows,
        exacRows:       exacRows,
        firmaTecBase64: tecBase64.isNotEmpty ? tecBase64 : null,
        firmaCliBase64: cliBase64.isNotEmpty ? cliBase64 : null,
      );

      // 5. Leer binario del PDF y guardar Base64 + path en SQLite
      final pdfFile = File(pdfPath);
      String? pdfB64;
      if (await pdfFile.exists()) {
        try {
          final pdfBytes = await pdfFile.readAsBytes();
          pdfB64 = base64Encode(pdfBytes);
        } catch (_) {}
      }

      final connResults = await Connectivity().checkConnectivity();
      final isOnline = connResults.any((r) => r != ConnectivityResult.none);

      await LocalDbService.instance.savePdfPath(
        widget.osId,
        pdfPath,
        folio: folio,
        pdfB64: pdfB64,
        isOnline: isOnline,
        uploadOk: false,
        fechaEjecucion: fechaEjecucionHoy,
        fechaCierre: fechaCierreIso,
        fechaCreacionLogistica: ordenMutable['fecha_creacion_logistica']?.toString(),
      );

      // 5.1 Eliminar el borrador local correspondiente al completar la orden
      await LocalDbService.instance.deleteDraft(folio);

      // 5.2 Actualizar estado en memoria reactivo en SyncService
      if (mounted) {
        context.read<SyncService>().updateLocalOrder(folio, {
          'fecha': fechaEjecucionHoy,
          'fecha_servicio': fechaEjecucionHoy,
          'fecha_cierre': fechaCierreIso,
          'pdf_path_local': pdfPath,
          'estado': 'COMPLETADA_DIGITAL',
          'estatus': 'Cerrado',
          'sync_check_status': 'PENDIENTE_SUBIDA',
          'sync_status': 'Pendiente',
          'needs_push': 1,
        });
      }

      // 6. Subida inmediata a Render si hay conexion (Wi-Fi o red movil)
      bool fueSincronizado = false;
      try {
        final uploadPayload = <String, dynamic>{
          ...enrichedOs,
          ...extraerMetaCorreoOrden(enrichedOs),
          'fecha': fechaEjecucionHoy,
          'fecha_servicio': fechaEjecucionHoy,
          'fecha_cierre': fechaCierreIso,
          'rep_rows': repRows,
          'exc_rows': excRows,
          'exac_rows': exacRows,
          'firma_tecnico': tecBase64,
          'firma_cliente': cliBase64,
        };

        if (isOnline) {
          debugPrint('[Firma] Red detectada -> Subiendo PDF de inmediato a Render para $folio...');
          if (pdfFile.existsSync()) {
            final uploadOk = await ApiService.instance.uploadPdf(
              folio,
              pdfFile,
              osId: widget.osId,
              data: uploadPayload,
            );
            if (uploadOk) {
              fueSincronizado = true;
              await LocalDbService.instance.savePdfPath(
                widget.osId,
                pdfPath,
                folio: folio,
                pdfB64: pdfB64,
                isOnline: true,
                uploadOk: true,
                fechaEjecucion: fechaEjecucionHoy,
                fechaCierre: fechaCierreIso,
                fechaCreacionLogistica: ordenMutable['fecha_creacion_logistica']?.toString(),
              );
              await LocalDbService.instance.updateOsSyncCheckStatus(
                folio,
                'SUBIDA_SERVIDOR',
                isSynced: 1,
                pdfSubido: 1,
              );
              await LocalDbService.instance.markOsSincronizada(
                widget.osId,
                ((enrichedOs['sync_version'] as int? ?? 0) + 1),
                folio: folio,
              );
              if (correoCapturado.isNotEmpty) {
                await LocalDbService.instance.updateEmailStatus(
                  folio,
                  enviado: true,
                  correo: correoCapturado,
                );
              }
              if (mounted) {
                context.read<SyncService>().updateLocalOrder(folio, {
                  'fecha': fechaEjecucionHoy,
                  'fecha_servicio': fechaEjecucionHoy,
                  'fecha_cierre': fechaCierreIso,
                  'pdf_path_local': pdfPath,
                  'estado': 'COMPLETADA_DIGITAL',
                  'estatus': 'Cerrado',
                  'sync_check_status': 'SUBIDA_SERVIDOR',
                  'sync_status': 'Enviada',
                  'needs_push': 0,
                  'is_synced': 1,
                  'pdf_subido': 1,
                  'correo_cliente': correoCapturado,
                  'email_enviado': 1,
                });
              }
              debugPrint('[Firma] ✅ Orden $folio sincronizada en SQLite y en Render');
            }
          }
          if (mounted) {
            context.read<SyncService>().performSync();
          }
        } else {
          debugPrint('[Firma] Sin red -> Sync quedara pendiente para cuando conecte a Wi-Fi');
        }
      } catch (syncErr) {
        debugPrint('[Firma] Error en sync automatico al generar PDF: $syncErr');
      }

      // 7. Dialogo de exito
      if (mounted) {
        if (fueSincronizado) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.cloud_done, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('Orden y PDF sincronizados con el servidor'),
                ],
              ),
              backgroundColor: Color(0xFF2E7D32),
              duration: Duration(seconds: 4),
            ),
          );
        }

        final localPdfPath = pdfPath;
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            icon: const Icon(Icons.check_circle, color: Colors.green, size: 52),
            title: const Text('Servicio Finalizado',
                style: TextStyle(fontWeight: FontWeight.w800)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('El servicio $folio fue guardado correctamente.'),
                if (nombreIng.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.person, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text('Recibio: $nombreIng',
                        style: const TextStyle(fontSize: 12)),
                  ]),
                  if (puestoIng.isNotEmpty)
                    Text('   $puestoIng',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
                const SizedBox(height: 12),
                if (fueSincronizado)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF81C784)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.cloud_done, color: Color(0xFF2E7D32), size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Orden y PDF sincronizados con el servidor',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1B5E20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const Text(
                    'Los datos se sincronizaran automaticamente al '
                    'detectar conexion con el servidor.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  if (mounted) context.go('/os');
                },
                child: const Text('Volver a Mis Ordenes'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.picture_as_pdf, size: 18),
                label: const Text('Ver PDF'),
                onPressed: () async {
                  if (localPdfPath.isNotEmpty && File(localPdfPath).existsSync()) {
                    try {
                      final res = await OpenFilex.open(localPdfPath);
                      if (res.type == ResultType.noAppToOpen || res.type == ResultType.error) {
                        if (context.mounted) {
                          context.push('/pdf-viewer', extra: {
                            'pdfPath': localPdfPath,
                            'pdfBytes': File(localPdfPath).readAsBytesSync(),
                            'folio': folio,
                          });
                        }
                      }
                    } catch (_) {
                      if (context.mounted) {
                        context.push('/pdf-viewer', extra: {
                          'pdfPath': localPdfPath,
                          'pdfBytes': File(localPdfPath).readAsBytesSync(),
                          'folio': folio,
                        });
                      }
                    }
                  } else if (context.mounted) {
                    context.push('/pdf-viewer', extra: {
                      'pdfPath': localPdfPath,
                      'pdfBytes': File(localPdfPath).readAsBytesSync(),
                      'folio': folio,
                    });
                  }
                },
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error al finalizar: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<Map<String, dynamic>> _castList(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw.cast<Map<String, dynamic>>();
    return [];
  }

  String _trunc(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}\u2026';
}
