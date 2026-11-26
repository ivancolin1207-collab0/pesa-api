// lib/widgets/cliente_correo_poka_yoke.dart
// Candado "a prueba de errores" (poka-yoke) para captura obligatoria de correo del cliente
// justo encima del pad de firma en los 7 formatos digitales (OS, OSOB, OSOCC, RMA, RE, LP, LV),
// con chips monocromáticos de correos frecuentes y arrastre automático en todo el lote.

import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/local_db_service.dart';
import '../theme/pesa_theme.dart';
import 'nombre_recibe.dart';

const String kDestinoSoloRecepcion = 'PENDIENTE (Solo recepción)';
const String kMsgPokaYokeCorreo = 'Ingresa o selecciona el correo del cliente antes de finalizar';

final RegExp kEmailPokaYokeRegExp = RegExp(
  r'^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$',
);

/// Valida uno o múltiples correos separados por coma o punto y coma.
/// Rechaza el remitente institucional (ivancolin1207@gmail.com) y textos genéricos.
bool esCorreoClienteValido(String? raw) {
  if (raw == null) return false;
  final s = raw.trim();
  if (s.isEmpty) return false;
  final partes = s
      .split(RegExp(r'[,;]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (partes.isEmpty) return false;
  for (final p in partes) {
    final low = p.toLowerCase();
    if (low == 'ivancolin1207@gmail.com' ||
        low == 'cliente' ||
        low == 'sin registrar' ||
        low.startsWith('pendiente')) {
      return false;
    }
    if (!kEmailPokaYokeRegExp.hasMatch(p)) {
      return false;
    }
  }
  return true;
}

/// Normaliza una cadena de correo(s) válidos separados por ", ".
String normalizarCorreosCliente(String raw) {
  final vistos = <String>{};
  final salida = <String>[];
  for (final p in raw.split(RegExp(r'[,;]+'))) {
    final c = p.trim();
    if (c.isEmpty) continue;
    if (vistos.add(c.toLowerCase())) {
      salida.add(c);
    }
  }
  return salida.join(', ');
}

/// Controlador reactivo para el bloque Poka-Yoke de Correo del Cliente.
class ClienteCorreoController extends ChangeNotifier {
  final TextEditingController emailTextCtrl = TextEditingController();
  final TextEditingController otroMotivoCtrl = TextEditingController();

  static const List<String> motivosRapidosSinCorreo = [
    'Cliente sin correo en planta',
    'Política de seguridad del cliente',
    'Entrega vía asesor comercial',
    'Otro motivo',
  ];

  bool _sinCorreoCliente = false;
  String _motivoSeleccionado = motivosRapidosSinCorreo.first;
  bool _esOpcional = false;
  bool _heredadoDeLote = false;
  bool _precargadoDeOficina = false;
  List<String> _correosFrecuentes = [];

  ClienteCorreoController({bool esOpcional = false}) : _esOpcional = esOpcional {
    emailTextCtrl.addListener(notifyListeners);
    otroMotivoCtrl.addListener(notifyListeners);
  }

  bool get sinCorreoCliente => _sinCorreoCliente;
  String get motivoSeleccionado => _motivoSeleccionado;
  bool get esOpcional => _esOpcional;
  bool get heredadoDeLote => _heredadoDeLote;
  bool get precargadoDeOficina => _precargadoDeOficina;
  List<String> get correosFrecuentes => List.unmodifiable(_correosFrecuentes);

  set esOpcional(bool value) {
    if (_esOpcional != value) {
      _esOpcional = value;
      notifyListeners();
    }
  }

  void setSinCorreoCliente(bool value) {
    if (_sinCorreoCliente != value) {
      _sinCorreoCliente = value;
      notifyListeners();
    }
  }

  void setMotivoSeleccionado(String motivo) {
    if (_motivoSeleccionado != motivo) {
      _motivoSeleccionado = motivo;
      notifyListeners();
    }
  }

  void seleccionarCorreoChip(String correo) {
    _sinCorreoCliente = false;
    emailTextCtrl.text = correo.trim();
    emailTextCtrl.selection = TextSelection.fromPosition(
      TextPosition(offset: emailTextCtrl.text.length),
    );
    notifyListeners();
  }

  String get motivoSinCorreoEfectivo {
    if (!_sinCorreoCliente) return '';
    if (_motivoSeleccionado == 'Otro motivo') {
      return otroMotivoCtrl.text.trim();
    }
    return _motivoSeleccionado.trim();
  }

  bool get tieneCorreoValido => esCorreoClienteValido(emailTextCtrl.text);

  /// True cuando el botón de confirmar/finalizar firma puede habilitarse.
  bool get isValido {
    if (_esOpcional) {
      final txt = emailTextCtrl.text.trim();
      return txt.isEmpty || tieneCorreoValido || _sinCorreoCliente;
    }
    if (_sinCorreoCliente) {
      return motivoSinCorreoEfectivo.length >= 3;
    }
    return tieneCorreoValido;
  }

  /// Valor limpio que debe guardarse en `correo_destino` y `correo_cliente`.
  String get correoParaGuardar {
    if (_sinCorreoCliente) {
      return kDestinoSoloRecepcion;
    }
    final txt = emailTextCtrl.text.trim();
    if (txt.isEmpty) return '';
    return normalizarCorreosCliente(txt);
  }

  /// Inicializa precarga inteligente desde:
  /// 1) Sesión activa del lote (`LoteSession`),
  /// 2) Orden actual / hermanos del lote en SQLite / precarga de oficina Windows,
  /// 3) Catálogo local de clientes/sucursales + endpoint `/api/clientes/{id}/correos`.
  Future<void> inicializarDesdeOrden(Map<String, dynamic> orden) async {
    final String loteId = (orden['id_lote'] ?? orden['lote'] ?? orden['lote_id'] ?? '').toString().trim();
    final int? clienteId = int.tryParse('${orden['id_cliente'] ?? orden['cliente_id'] ?? ''}');
    final int? sucursalId = int.tryParse('${orden['sucursal_id'] ?? orden['id_sucursal'] ?? ''}');
    final String clienteNom = (orden['cliente'] ?? orden['cliente_nombre'] ?? orden['razon_social'] ?? '').toString().trim();
    final String sucursalNom = (orden['sucursal'] ?? orden['direccion'] ?? '').toString().trim();
    final String folio = (orden['folio_os'] ?? orden['folio'] ?? '').toString().trim();

    // 1. Revisar memoria en vivo del lote
    if (loteId.isNotEmpty) {
      final loteSinCorreo = LoteSession.getSinCorreo(loteId);
      final loteCorreo = LoteSession.getUltimoCorreo(loteId);
      if (loteSinCorreo) {
        _sinCorreoCliente = true;
        final mot = LoteSession.getMotivoSinCorreo(loteId) ?? '';
        if (mot.isNotEmpty && !motivosRapidosSinCorreo.contains(mot)) {
          _motivoSeleccionado = 'Otro motivo';
          otroMotivoCtrl.text = mot;
        } else if (mot.isNotEmpty) {
          _motivoSeleccionado = mot;
        }
        _heredadoDeLote = true;
      } else if (loteCorreo != null && esCorreoClienteValido(loteCorreo)) {
        emailTextCtrl.text = loteCorreo;
        _heredadoDeLote = true;
      }
    }

    // 2. Revisar correo precargado en la propia orden o JSON técnico (oficina Windows)
    if (emailTextCtrl.text.trim().isEmpty && !_sinCorreoCliente) {
      String candOrden = '';
      for (final k in const ['correo_destino', 'correo_cliente', 'email_cliente']) {
        final v = (orden[k] ?? '').toString().trim();
        if (v.isNotEmpty) {
          candOrden = v;
          break;
        }
      }
      if (candOrden.isEmpty && orden['datos_tecnicos_json'] != null) {
        try {
          final rawDt = orden['datos_tecnicos_json'];
          final parsed = rawDt is String ? jsonDecode(rawDt) : rawDt;
          if (parsed is Map) {
            candOrden = (parsed['correo_destino'] ?? parsed['correo_cliente'] ?? '').toString().trim();
          }
        } catch (_) {}
      }
      if (candOrden.toUpperCase().startsWith('PENDIENTE')) {
        _sinCorreoCliente = true;
      } else if (esCorreoClienteValido(candOrden)) {
        emailTextCtrl.text = normalizarCorreosCliente(candOrden);
        _precargadoDeOficina = true;
      }
    }

    // 3. Revisar órdenes hermanas del mismo lote en SQLite si aún está vacío
    if (emailTextCtrl.text.trim().isEmpty && !_sinCorreoCliente && (loteId.isNotEmpty || folio.isNotEmpty)) {
      final heredadoDb = await LocalDbService.instance.obtenerCorreoHeredadoLote(
        folio: folio,
        loteId: loteId,
      );
      if (heredadoDb != null) {
        final corrH = (heredadoDb['correo'] ?? '').toString().trim();
        final sinC = heredadoDb['sin_correo'] == true;
        if (sinC || corrH.toUpperCase().startsWith('PENDIENTE')) {
          _sinCorreoCliente = true;
          final motH = (heredadoDb['motivo'] ?? '').toString().trim();
          if (motH.isNotEmpty) {
            if (motivosRapidosSinCorreo.contains(motH)) {
              _motivoSeleccionado = motH;
            } else {
              _motivoSeleccionado = 'Otro motivo';
              otroMotivoCtrl.text = motH;
            }
          }
          _heredadoDeLote = true;
        } else if (esCorreoClienteValido(corrH)) {
          emailTextCtrl.text = normalizarCorreosCliente(corrH);
          _heredadoDeLote = true;
        }
      }
    }

    // 4. Cargar chips frecuentes locales (SQLite: cliente + sucursal + historial)
    final frecuentesLocal = await LocalDbService.instance.getCorreosFrecuentesCliente(
      clienteId: clienteId,
      clienteNombre: clienteNom,
      sucursalId: sucursalId,
      sucursalNombre: sucursalNom,
    );
    _fusionarFrecuentes(frecuentesLocal);
    notifyListeners();

    // 5. Enriquecer desde API en segundo plano (sin bloquear UI) si hay conexión
    if ((clienteId != null && clienteId > 0) || clienteNom.isNotEmpty) {
      try {
        final remotos = await ApiService.instance.getCorreosFrecuentesCliente(
          clienteId ?? 0,
          sucursalId: sucursalId,
          clienteNombre: clienteNom,
        );
        if (remotos.isNotEmpty) {
          _fusionarFrecuentes(remotos);
          notifyListeners();
        }
      } catch (_) {}
    }
  }

  void _fusionarFrecuentes(List<String> nuevos) {
    final vistos = _correosFrecuentes.map((e) => e.toLowerCase()).toSet();
    for (final raw in nuevos) {
      for (final part in raw.split(RegExp(r'[,;]+'))) {
        final c = part.trim();
        if (esCorreoClienteValido(c) && vistos.add(c.toLowerCase()) && _correosFrecuentes.length < 8) {
          _correosFrecuentes.add(c);
        }
      }
    }
  }

  /// Guarda el correo validado (o la excepción "Solo recepción" + motivo) en la orden actual
  /// y lo propaga automáticamente a todo el lote activo en `LoteSession` + SQLite.
  Future<String> persistirEnOrdenYLote({
    required String folio,
    String? loteId,
    Map<String, dynamic>? ordenMutable,
  }) async {
    final destino = correoParaGuardar;
    final sinC = _sinCorreoCliente;
    final motivo = motivoSinCorreoEfectivo;

    if (ordenMutable != null) {
      if (destino.isNotEmpty) {
        ordenMutable['correo_cliente'] = destino;
        ordenMutable['correo_destino'] = destino;
      }
      ordenMutable['sin_correo_cliente'] = sinC;
      if (motivo.isNotEmpty) {
        ordenMutable['motivo_sin_correo'] = motivo;
      }
    }

    if (loteId != null && loteId.trim().isNotEmpty && destino.isNotEmpty) {
      LoteSession.registrarCorreo(
        loteId.trim(),
        destino,
        sinCorreo: sinC,
        motivoSinCorreo: motivo,
      );
    }

    if (folio.trim().isNotEmpty && destino.isNotEmpty) {
      await LocalDbService.instance.guardarCorreoEnOrdenYLote(
        folio: folio.trim(),
        loteId: loteId,
        correo: destino,
        sinCorreoCliente: sinC,
        motivoSinCorreo: motivo,
      );
    }
    return destino;
  }

  @override
  void dispose() {
    emailTextCtrl.dispose();
    otroMotivoCtrl.dispose();
    super.dispose();
  }
}

/// Bloque limpio estilo Apple minimalista PESA para colocar justo encima del pad de firma del cliente.
class ClienteCorreoPokaYokeCard extends StatelessWidget {
  final ClienteCorreoController controller;
  final String? loteId;
  final EdgeInsetsGeometry margin;

  const ClienteCorreoPokaYokeCard({
    super.key,
    required this.controller,
    this.loteId,
    this.margin = const EdgeInsets.only(bottom: 10),
  });

  @override
  Widget build(BuildContext context) {
    final bool perteneceALote = loteId != null && loteId!.trim().isNotEmpty;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final txt = controller.emailTextCtrl.text.trim();
        final bool valido = controller.isValido;
        final bool mostrarErrorFormato = !controller.sinCorreoCliente && txt.isNotEmpty && !controller.tieneCorreoValido;

        return Container(
          margin: margin,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: PesaColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: valido ? PesaColors.border : PesaColors.brand.withValues(alpha: 0.45),
              width: valido ? 1.0 : 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Cabecera del bloque
              Row(
                children: [
                  Icon(
                    valido ? Icons.check_circle_rounded : Icons.mail_outline_rounded,
                    size: 17,
                    color: valido ? PesaColors.dotGreen : PesaColors.brand,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      controller.esOpcional
                          ? 'Correo del Cliente (opcional en modo Stock)'
                          : 'Correo del Cliente para envío de reporte *',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: PesaColors.textPrimary,
                      ),
                    ),
                  ),
                  if (controller.heredadoDeLote && !controller.sinCorreoCliente && controller.tieneCorreoValido)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: PesaColors.surfaceMuted,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: PesaColors.borderStrong),
                      ),
                      child: const Text(
                        'Heredado del lote',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: PesaColors.textSecondary),
                      ),
                    )
                  else if (controller.precargadoDeOficina && !controller.sinCorreoCliente && controller.tieneCorreoValido)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: PesaColors.surfaceMuted,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: PesaColors.borderStrong),
                      ),
                      child: const Text(
                        'Precargado en oficina',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: PesaColors.textSecondary),
                      ),
                    ),
                ],
              ),

              // Chips monocromáticos de 1 toque con correos frecuentes del cliente
              if (!controller.sinCorreoCliente && controller.correosFrecuentes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: controller.correosFrecuentes.map((correo) {
                    final seleccionado = txt.toLowerCase() == correo.toLowerCase();
                    return InkWell(
                      borderRadius: BorderRadius.circular(7),
                      onTap: () => controller.seleccionarCorreoChip(correo),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                          color: seleccionado ? PesaColors.textPrimary : PesaColors.surfaceMuted,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: seleccionado ? PesaColors.textPrimary : PesaColors.borderStrong,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              seleccionado ? Icons.check_rounded : Icons.alternate_email_rounded,
                              size: 12,
                              color: seleccionado ? Colors.white : PesaColors.textSecondary,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                correo,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: seleccionado ? Colors.white : PesaColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],

              if (!controller.sinCorreoCliente) ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: controller.emailTextCtrl,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: PesaColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'cliente@empresa.com (puedes separar varios con coma)',
                    hintStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: PesaColors.textTertiary),
                    prefixIcon: const Icon(Icons.alternate_email_rounded, size: 18, color: PesaColors.textSecondary),
                    suffixIcon: txt.isNotEmpty
                        ? IconButton(
                            tooltip: 'Limpiar correo',
                            icon: const Icon(Icons.close_rounded, size: 17, color: PesaColors.textSecondary),
                            onPressed: () => controller.emailTextCtrl.clear(),
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    errorText: mostrarErrorFormato
                        ? 'Ingresa un correo electrónico válido (ej. nombre@empresa.com)'
                        : null,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  perteneceALote
                      ? 'CC automático: recepcion@basculaspesa.com.mx · Se aplicará a todo este lote.'
                      : 'CC automático: recepcion@basculaspesa.com.mx',
                  style: const TextStyle(fontSize: 11, color: PesaColors.textSecondary),
                ),
              ],

              if (!controller.esOpcional) ...[
                const SizedBox(height: 6),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => controller.setSinCorreoCliente(!controller.sinCorreoCliente),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: controller.sinCorreoCliente,
                            activeColor: PesaColors.textPrimary,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            onChanged: (v) => controller.setSinCorreoCliente(v ?? false),
                          ),
                        ),
                        const SizedBox(width: 7),
                        const Expanded(
                          child: Text(
                            'El cliente no proporciona correo (enviar solo a recepción)',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: PesaColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              if (controller.sinCorreoCliente) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: PesaColors.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: PesaColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Selecciona el motivo para respaldo en recepción *',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: PesaColors.textPrimary),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: ClienteCorreoController.motivosRapidosSinCorreo.map((m) {
                          final sel = controller.motivoSeleccionado == m;
                          return ChoiceChip(
                            label: Text(
                              m,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: sel ? Colors.white : PesaColors.textPrimary,
                              ),
                            ),
                            selected: sel,
                            selectedColor: PesaColors.textPrimary,
                            backgroundColor: Colors.white,
                            side: BorderSide(color: sel ? PesaColors.textPrimary : PesaColors.borderStrong),
                            visualDensity: VisualDensity.compact,
                            showCheckmark: false,
                            onSelected: (_) => controller.setMotivoSeleccionado(m),
                          );
                        }).toList(),
                      ),
                      if (controller.motivoSeleccionado == 'Otro motivo') ...[
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: controller.otroMotivoCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Describe brevemente el motivo *',
                            hintText: 'Ej. Autorizado entregar impreso en caseta',
                            isDense: true,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              if (!valido) ...[
                const SizedBox(height: 6),
                Row(
                  children: const [
                    Icon(Icons.info_outline_rounded, size: 14, color: PesaColors.brand),
                    SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        kMsgPokaYokeCorreo,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: PesaColors.brand,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Aviso compacto encima de la barra inferior cuando el candado poka-yoke sigue bloqueado.
class ClienteCorreoLockBanner extends StatelessWidget {
  final ClienteCorreoController controller;

  const ClienteCorreoLockBanner({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        if (controller.isValido) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.lock_outline_rounded, size: 14, color: PesaColors.brand),
              SizedBox(width: 5),
              Flexible(
                child: Text(
                  kMsgPokaYokeCorreo,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: PesaColors.brand,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
