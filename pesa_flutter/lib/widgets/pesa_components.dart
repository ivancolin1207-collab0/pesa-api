// lib/widgets/pesa_components.dart
// Componentes reutilizables del Sistema de Diseño Básculas PESA (Claro & Apple Dark)
import 'package:flutter/material.dart';
import '../theme/pesa_theme.dart';

/// Tarjeta corporativa limpia (adaptada a Claro `#FFFFFF` y Oscuro `#1C1C1E`).
class PesaCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? borderColor;
  final double borderWidth;
  final VoidCallback? onTap;

  const PesaCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.borderColor,
    this.borderWidth = 1,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(
        color: borderColor ?? c.border,
        width: borderWidth,
      ),
    );
    final card = Material(
      color: c.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap != null
          ? InkWell(
              onTap: onTap,
              child: Padding(padding: padding, child: child),
            )
          : Padding(padding: padding, child: child),
    );
    return margin != null ? Padding(padding: margin!, child: card) : card;
  }
}

/// Punto semántico circular discreto (6dp) para estados de red, orden y sincronización.
class PesaSemanticDot extends StatelessWidget {
  final Color color;
  final double size;

  const PesaSemanticDot({
    super.key,
    required this.color,
    this.size = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Badge neutro (`#F2F2F7` en Claro / `#2C2C2E` en Oscuro) con punto semántico opcional de 6dp.
class PesaStatusBadge extends StatelessWidget {
  final String label;
  final Color? dotColor;
  final Color? textColor;
  final bool isCancelled;
  final EdgeInsetsGeometry padding;

  const PesaStatusBadge({
    super.key,
    required this.label,
    this.dotColor,
    this.textColor,
    this.isCancelled = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
  });

  factory PesaStatusBadge.fromEstado(String estado) {
    final e = estado.trim().toLowerCase();
    Color dot = PesaColors.dotNeutral;
    bool cancelled = false;
    if (e.contains('cerrad') ||
        e.contains('complet') ||
        e.contains('escan') ||
        e.contains('finaliz') ||
        e.contains('firmad') ||
        e.contains('enviad') ||
        e.contains('sincron')) {
      dot = PesaColors.dotGreen;
    } else if (e.contains('proceso') || e.contains('tablet') || e.contains('offline')) {
      dot = PesaColors.dotAmber;
    } else if (e.contains('pend') || e.contains('cancel') || e.contains('asign')) {
      dot = PesaColors.dotRed;
      if (e.contains('cancel')) cancelled = true;
    }
    return PesaStatusBadge(label: estado, dotColor: dot, isCancelled: cancelled);
  }

  Color _adaptDot(PesaPalette c, Color raw) {
    if (!c.isDark) return raw;
    if (raw == PesaColors.dotGreen) return c.dotGreen;
    if (raw == PesaColors.dotAmber) return c.dotAmber;
    if (raw == PesaColors.dotRed || raw == PesaColors.brand) return c.dotRed;
    if (raw == PesaColors.dotNeutral) return c.dotNeutral;
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    Color resolvedText = c.textPrimary;
    if (isCancelled) {
      resolvedText = c.brandAccent;
    } else if (textColor != null) {
      if (c.isDark && textColor == PesaColors.textPrimary) {
        resolvedText = c.textPrimary;
      } else if (c.isDark && textColor == PesaColors.brand) {
        resolvedText = c.brandAccent;
      } else {
        resolvedText = textColor!;
      }
    }

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            PesaSemanticDot(color: _adaptDot(c, dotColor!), size: 6),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: resolvedText,
            ),
          ),
        ],
      ),
    );
  }
}

/// Botón primario corporativo (#C8102E, mínimo 48dp de alto para ergonomía en campo).
class PesaPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final bool expand;

  const PesaPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.loading = false,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = loading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18),
                const SizedBox(width: 8),
              ],
              Text(label),
            ],
          );

    final btn = ElevatedButton(
      onPressed: loading ? null : onPressed,
      child: child,
    );
    return expand ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// Botón secundario corporativo (adaptado a Claro y Oscuro, 48dp).
class PesaSecondaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool expand;

  const PesaSecondaryButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final btn = OutlinedButton(
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18),
            const SizedBox(width: 8),
          ],
          Text(label),
        ],
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// Selector segmentado ergonómico (mínimo 44-48dp) ideal para Automático|Claro|Oscuro o B|R|M|N/A.
class PesaSegmentedSelector<T> extends StatelessWidget {
  final List<T> options;
  final T? selected;
  final String Function(T) labelBuilder;
  final ValueChanged<T> onChanged;

  const PesaSegmentedSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.labelBuilder,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: options.map((opt) {
          final isSel = opt == selected;
          return Expanded(
            child: InkWell(
              onTap: () => onChanged(opt),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                constraints: const BoxConstraints(minHeight: 42),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                decoration: BoxDecoration(
                  color: isSel ? c.brand : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  labelBuilder(opt),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w600,
                    color: isSel ? Colors.white : c.textPrimary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Estado vacío amigable con mensaje claro y acción sugerida.
class PesaEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const PesaEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: c.surface,
                shape: BoxShape.circle,
                border: Border.all(color: c.border),
              ),
              child: Icon(icon, size: 26, color: c.textSecondary),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: c.textSecondary,
                height: 1.4,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              PesaSecondaryButton(
                label: actionLabel!,
                icon: Icons.refresh_rounded,
                onPressed: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Indicador de progreso lineal por pasos para flujos de captura.
class PesaStepProgressBar extends StatelessWidget {
  final int currentStep; // 1-based
  final int totalSteps;
  final String? stepLabel;

  const PesaStepProgressBar({
    super.key,
    required this.currentStep,
    required this.totalSteps,
    this.stepLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final safeTotal = totalSteps <= 0 ? 1 : totalSteps;
    final ratio = (currentStep / safeTotal).clamp(0.0, 1.0);
    return Container(
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                stepLabel ?? 'Paso $currentStep de $safeTotal',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '${(ratio * 100).round()}%',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 4,
              backgroundColor: c.border,
              valueColor: AlwaysStoppedAnimation<Color>(c.brandAccent),
            ),
          ),
        ],
      ),
    );
  }
}

/// Indicador discreto en barra superior: "Borrador guardado" / "Guardando..."
class PesaDraftIndicator extends StatelessWidget {
  final bool saving;
  final String? savedTimeLabel;

  const PesaDraftIndicator({
    super.key,
    this.saving = false,
    this.savedTimeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PesaSemanticDot(
            color: saving ? c.dotAmber : c.dotGreen,
            size: 6,
          ),
          const SizedBox(width: 6),
          Text(
            saving
                ? 'Guardando…'
                : (savedTimeLabel != null
                    ? 'Borrador $savedTimeLabel'
                    : 'Borrador guardado'),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra de progreso de lote ("X de Y activas listas · Z no utilizada") para tarjetas y filas de lote.
class PesaBatchProgressBar extends StatelessWidget {
  final int completed;
  final int total;
  final int cancelled;

  const PesaBatchProgressBar({
    super.key,
    required this.completed,
    required this.total,
    this.cancelled = 0,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    final int activeTotal = (total - cancelled) < 0 ? 0 : (total - cancelled);
    final int safeDenom = activeTotal <= 0 ? 1 : activeTotal;
    final double ratio = activeTotal == 0 ? 0.0 : (completed / safeDenom).clamp(0.0, 1.0);
    final bool allDone = activeTotal > 0 && completed >= activeTotal;
    final String labelTxt = cancelled > 0
        ? '$completed de $activeTotal activas listas · $cancelled no utilizada${cancelled == 1 ? '' : 's'}'
        : '$completed de $total completadas';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            PesaSemanticDot(
              color: activeTotal == 0
                  ? c.dotNeutral
                  : (allDone
                      ? c.dotGreen
                      : (completed > 0 ? c.dotAmber : c.dotRed)),
              size: 6,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                labelTxt,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 4,
            backgroundColor: c.border,
            valueColor: AlwaysStoppedAnimation<Color>(
              allDone ? c.dotGreen : c.brandAccent,
            ),
          ),
        ),
      ],
    );
  }
}

/// Marco blindado para pad de firma táctil: SIEMPRE fondo blanco `#FFFFFF` + línea guía
/// clara para garantizar contraste total de la tinta negra `#000000` incluso en Modo Nocturno.
class PesaSignatureFrame extends StatelessWidget {
  final Widget child;
  final String hintText;
  final double height;
  final bool hasSignature;
  final VoidCallback? onClear;

  const PesaSignatureFrame({
    super.key,
    required this.child,
    this.hintText = 'Firme sobre la línea guía',
    this.height = 176,
    this.hasSignature = false,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final c = PesaColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CustomPaint(
          foregroundPainter: _DashedBorderPainter(
            color: hasSignature ? c.brandAccent : c.borderStrong,
            radius: 10,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: height,
              color: PesaColors.signatureCanvas, // BLINDAJE OBLIGATORIO: #FFFFFF siempre
              child: Stack(
                children: [
                  Positioned.fill(child: child),
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 34,
                    child: IgnorePointer(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(height: 1, color: const Color(0xFFE5E5EA)),
                          const SizedBox(height: 4),
                          Text(
                            hintText,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFF8E8E93),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (onClear != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.cleaning_services_outlined, size: 16),
              label: const Text('Limpiar firma'),
              style: TextButton.styleFrom(
                foregroundColor: c.textSecondary,
                minimumSize: const Size(48, 40),
              ),
            ),
          ),
      ],
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedBorderPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.6, 0.6, size.width - 1.2, size.height - 1.2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dashWidth = 6.0;
    const dashSpace = 4.0;
    for (final metric in path.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
