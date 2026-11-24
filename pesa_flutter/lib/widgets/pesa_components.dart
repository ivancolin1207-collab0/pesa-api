// lib/widgets/pesa_components.dart
// Componentes reutilizables del Sistema de Diseño Básculas PESA (Android / Tablet)
import 'package:flutter/material.dart';
import '../theme/pesa_theme.dart';

/// Tarjeta corporativa limpia (#FFFFFF, radio 12dp, borde 1dp #E5E7EB, sin sombras fuertes).
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
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: borderColor ?? PesaColors.border,
        width: borderWidth,
      ),
    );
    final card = Material(
      color: PesaColors.surface,
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

/// Badge neutro (#F8FAFC, borde #CBD5E1, texto #111827) con punto semántico opcional de 6dp.
class PesaStatusBadge extends StatelessWidget {
  final String label;
  final Color? dotColor;
  final Color? textColor;
  final EdgeInsetsGeometry padding;

  const PesaStatusBadge({
    super.key,
    required this.label,
    this.dotColor,
    this.textColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
  });

  factory PesaStatusBadge.fromEstado(String estado) {
    final e = estado.trim().toLowerCase();
    Color dot = PesaColors.dotNeutral;
    Color txt = PesaColors.textPrimary;
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
      if (e.contains('cancel')) txt = PesaColors.brand;
    }
    return PesaStatusBadge(label: estado, dotColor: dot, textColor: txt);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: PesaColors.surfaceMuted,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PesaColors.borderStrong, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            PesaSemanticDot(color: dotColor!, size: 6),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: textColor ?? PesaColors.textPrimary,
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

/// Botón secundario corporativo (#FFFFFF, borde #CBD5E1, texto #111827, 48dp).
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

/// Selector segmentado ergonómico (mínimo 44-48dp) ideal para B|R|M|N/A o Cumple|No cumple.
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
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: PesaColors.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PesaColors.border),
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
                  color: isSel ? PesaColors.brand : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  labelBuilder(opt),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w600,
                    color: isSel ? Colors.white : PesaColors.textPrimary,
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
                color: PesaColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: PesaColors.border),
              ),
              child: Icon(icon, size: 26, color: PesaColors.textSecondary),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: PesaColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: PesaColors.textSecondary,
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
    final safeTotal = totalSteps <= 0 ? 1 : totalSteps;
    final ratio = (currentStep / safeTotal).clamp(0.0, 1.0);
    return Container(
      color: PesaColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                stepLabel ?? 'Paso $currentStep de $safeTotal',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: PesaColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '${(ratio * 100).round()}%',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: PesaColors.textSecondary,
                  fontFeatures: [FontFeature.tabularFigures()],
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
              backgroundColor: PesaColors.border,
              valueColor: const AlwaysStoppedAnimation<Color>(PesaColors.brand),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: PesaColors.surfaceMuted,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PesaColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PesaSemanticDot(
            color: saving ? PesaColors.dotAmber : PesaColors.dotGreen,
            size: 6,
          ),
          const SizedBox(width: 6),
          Text(
            saving
                ? 'Guardando…'
                : (savedTimeLabel != null
                    ? 'Borrador $savedTimeLabel'
                    : 'Borrador guardado'),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: PesaColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra de progreso de lote ("X de Y completadas") para tarjetas y filas de lote.
class PesaBatchProgressBar extends StatelessWidget {
  final int completed;
  final int total;

  const PesaBatchProgressBar({
    super.key,
    required this.completed,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final safeTotal = total <= 0 ? 1 : total;
    final ratio = (completed / safeTotal).clamp(0.0, 1.0);
    final allDone = completed >= total && total > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            PesaSemanticDot(
              color: allDone
                  ? PesaColors.dotGreen
                  : (completed > 0 ? PesaColors.dotAmber : PesaColors.dotRed),
              size: 6,
            ),
            const SizedBox(width: 6),
            Text(
              '$completed de $total completadas',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: PesaColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()],
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
            backgroundColor: PesaColors.border,
            valueColor: AlwaysStoppedAnimation<Color>(
              allDone ? PesaColors.dotGreen : PesaColors.brand,
            ),
          ),
        ),
      ],
    );
  }
}

/// Marco limpio para pad de firma táctil con borde punteado y línea guía horizontal.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CustomPaint(
          foregroundPainter: _DashedBorderPainter(
            color: hasSignature ? PesaColors.borderStrong : PesaColors.borderStrong,
            radius: 10,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: height,
              color: PesaColors.surface,
              child: Stack(
                children: [
                  Positioned.fill(child: child),
                  // Línea guía horizontal sutil para firmar cómodamente
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 34,
                    child: IgnorePointer(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(height: 1, color: PesaColors.border),
                          const SizedBox(height: 4),
                          Text(
                            hintText,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: PesaColors.textTertiary,
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
                foregroundColor: PesaColors.textSecondary,
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
