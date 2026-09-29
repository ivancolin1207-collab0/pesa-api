import 'package:flutter/material.dart';

/// Modelo de metadatos para cada uno de los 4 estados de trazabilidad tipo WhatsApp.
class SyncCheckInfo {
  final String statusKey;
  final String checkSymbols;
  final int checkCount; // 1 o 2
  final Color color;
  final Color backgroundColor;
  final String label;
  final String title;
  final String description;

  const SyncCheckInfo({
    required this.statusKey,
    required this.checkSymbols,
    required this.checkCount,
    required this.color,
    required this.backgroundColor,
    required this.label,
    required this.title,
    required this.description,
  });

  static const SyncCheckInfo asignada = SyncCheckInfo(
    statusKey: 'ASIGNADA',
    checkSymbols: '✓',
    checkCount: 1,
    color: Color(0xFF8E8E93),
    backgroundColor: Color(0xFFF2F2F7),
    label: 'Asignada',
    title: '✓ Gris — Asignada en Servidor',
    description: 'Logística generó y asignó la OS en Render/PostgreSQL. La tablet del técnico aún no se ha conectado a internet para descargarla.',
  );

  static const SyncCheckInfo recibidaTablet = SyncCheckInfo(
    statusKey: 'RECIBIDA_TABLET',
    checkSymbols: '✓✓',
    checkCount: 2,
    color: Color(0xFF8E8E93),
    backgroundColor: Color(0xFFF2F2F7),
    label: 'En Tablet',
    title: '✓✓ Gris — Recibida en Tablet / Offline',
    description: 'La tablet ya sincronizó y descargó la orden a su almacenamiento local. El técnico ya realizó o está realizando la toma en campo (incluso sin internet).',
  );

  static const SyncCheckInfo subidaServidor = SyncCheckInfo(
    statusKey: 'SUBIDA_SERVIDOR',
    checkSymbols: '✓✓',
    checkCount: 2,
    color: Color(0xFF007AFF),
    backgroundColor: Color(0xFFEBF5FF),
    label: 'Enviada',
    title: '✓✓ Azul — Enviada al Servidor / Concluida',
    description: 'El técnico finalizó la orden, capturó firmas, generó el PDF y subió exitosamente el PDF y datos a Render (HTTP 200 OK). Lista para consulta.',
  );

  static const SyncCheckInfo auditadaAdmin = SyncCheckInfo(
    statusKey: 'AUDITADA_ADMIN',
    checkSymbols: '✓✓',
    checkCount: 2,
    color: Color(0xFF34C759),
    backgroundColor: Color(0xFFE8F9ED),
    label: 'Abierto',
    title: '✓✓ Verde — Abierto en Windows',
    description: 'Recepción o Administración (Iván / Recepción) abrió, descargó o confirmó la OS y PDF desde el sistema en Windows.',
  );

  static SyncCheckInfo fromStatus(String? status) {
    if (status == null) return asignada;
    final s = status.trim().toUpperCase();
    if (s == 'AUDITADA_ADMIN' || s == 'ABIERTO' || s.contains('AUDIT') || s.contains('ABIERTO') || s.contains('OPEN')) {
      return auditadaAdmin;
    }
    if (s == 'SUBIDA_SERVIDOR' || s == 'ENVIADA' || s == 'ENVIADO') {
      return subidaServidor;
    }
    if (s == 'RECIBIDA_TABLET' || s == 'EN_TABLET' || s == 'EN TABLET') {
      return recibidaTablet;
    }
    if (s == 'ASIGNADA' || s == 'ASIGNADO') {
      return asignada;
    }
    // Fallbacks si viene un estado de la orden en vez de sync_check_status
    if (s == 'COMPLETADA' || s == 'COMPLETADA_DIGITAL' || s == 'CERRADA' || s == 'CERRADO') {
      return subidaServidor;
    }
    if (s == 'EN_CAMPO' || s == 'EN_PROCESO' || s == 'PROCESO' || s == 'PENDIENTE') {
      return recibidaTablet;
    }
    return asignada;
  }
}

/// Widget visual con iconos tipo palomitas de WhatsApp (✓ Gris, ✓✓ Gris, ✓✓ Azul, ✓✓ Verde)
class SyncCheckBadge extends StatelessWidget {
  final String? status;
  final bool showLabel;
  final double iconSize;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  const SyncCheckBadge({
    super.key,
    required this.status,
    this.showLabel = true,
    this.iconSize = 14,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  });

  @override
  Widget build(BuildContext context) {
    final info = SyncCheckInfo.fromStatus(status);

    return Tooltip(
      message: '${info.title}\n${info.description}',
      preferBelow: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12, height: 1.3),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D1F),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: InkWell(
        onTap: () => _mostrarLeyendaModal(context, info),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: info.backgroundColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: info.color.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildCheckIcons(info),
              if (showLabel) ...[
                const SizedBox(width: 4),
                Text(
                  info.label,
                  style: TextStyle(
                    color: info.color,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCheckIcons(SyncCheckInfo info) {
    if (info.checkCount == 1) {
      return Icon(
        Icons.check,
        size: iconSize,
        color: info.color,
      );
    }

    // Doble palomita superpuesta compacta estilo WhatsApp
    return SizedBox(
      width: iconSize + 4,
      height: iconSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            child: Icon(Icons.check, size: iconSize, color: info.color),
          ),
          Positioned(
            left: 5,
            child: Icon(Icons.check, size: iconSize, color: info.color),
          ),
        ],
      ),
    );
  }

  static void _mostrarLeyendaModal(BuildContext context, SyncCheckInfo current) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFC7C7CC),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Row(
                  children: [
                    Icon(Icons.mark_chat_read_outlined, size: 20, color: Color(0xFF1D1D1F)),
                    SizedBox(width: 8),
                    Text(
                      'Trazabilidad de Órdenes de Servicio',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1D1D1F),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _buildModalRow(SyncCheckInfo.asignada, current.statusKey == 'ASIGNADA'),
                const Divider(height: 16, color: Color(0xFFF2F2F7)),
                _buildModalRow(SyncCheckInfo.recibidaTablet, current.statusKey == 'RECIBIDA_TABLET'),
                const Divider(height: 16, color: Color(0xFFF2F2F7)),
                _buildModalRow(SyncCheckInfo.subidaServidor, current.statusKey == 'SUBIDA_SERVIDOR'),
                const Divider(height: 16, color: Color(0xFFF2F2F7)),
                _buildModalRow(SyncCheckInfo.auditadaAdmin, current.statusKey == 'AUDITADA_ADMIN'),
              ],
            ),
          ),
        );
      },
    );
  }

  static Widget _buildModalRow(SyncCheckInfo item, bool isSelected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isSelected ? item.backgroundColor.withValues(alpha: 0.6) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: isSelected
            ? Border.all(color: item.color.withValues(alpha: 0.4), width: 1.5)
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: item.backgroundColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: item.color.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.checkCount == 1)
                  Icon(Icons.check, size: 14, color: item.color)
                else
                  SizedBox(
                    width: 18,
                    height: 14,
                    child: Stack(
                      children: [
                        Positioned(left: 0, child: Icon(Icons.check, size: 14, color: item.color)),
                        Positioned(left: 4, child: Icon(Icons.check, size: 14, color: item.color)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isSelected ? item.color : const Color(0xFF1D1D1F),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.description,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF636366),
                    height: 1.25,
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
