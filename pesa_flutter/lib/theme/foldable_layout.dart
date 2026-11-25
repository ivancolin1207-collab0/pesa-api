// lib/theme/foldable_layout.dart
// Utilidades adaptativas y conciencia de bisagra para Samsung Galaxy Z Fold8 Ultra
// Sistema de Diseño Corporativo Minimalista — Básculas PESA
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;
import 'package:flutter/material.dart';
import 'pesa_theme.dart';

/// Breakpoints calibrados para Samsung Galaxy Z Fold8 Ultra:
/// - Pantalla externa plegada (~360–440dp): < 600dp → modo compacto 1 columna
/// - Pantalla interna desplegada (~720–900dp): >= 600dp → Master–Detail / 2 columnas
/// - Tablets amplias / modo escritorio: >= 960dp → sidebar expandido opcional
const double kFoldableCoverBreakpoint = 600.0;
const double kFoldableWideBreakpoint = 960.0;
const double kFoldableDialogMaxWidth = 520.0;

/// True cuando la app corre en pantalla externa plegada o smartphone angosto (< 600dp).
bool isCoverScreen(BuildContext context) =>
    MediaQuery.sizeOf(context).width < kFoldableCoverBreakpoint;

/// True cuando la app corre en pantalla interna desplegada del Z Fold o tablet (>= 600dp).
bool isUnfoldedScreen(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kFoldableCoverBreakpoint;

/// True cuando hay ancho amplio de tablet / escritorio (>= 960dp).
bool isWideScreen(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kFoldableWideBreakpoint;

/// Devuelve los límites físicos de una bisagra o pliegue vertical activo
/// (`DisplayFeatureType.hinge` o `DisplayFeatureType.fold`) si divide la pantalla
/// en panel izquierdo y panel derecho.
Rect? verticalHingeBounds(BuildContext context) {
  final media = MediaQuery.of(context);
  final size = media.size;
  if (size.width < kFoldableCoverBreakpoint) return null;

  for (final DisplayFeature feature in media.displayFeatures) {
    final isFoldOrHinge = feature.type == DisplayFeatureType.hinge ||
        feature.type == DisplayFeatureType.fold;
    if (!isFoldOrHinge) continue;
    final rect = feature.bounds;
    // Bisagra vertical: altura mayor que anchura y centrada dentro de la pantalla
    if (rect.height > rect.width &&
        rect.left >= 180 &&
        rect.right <= size.width - 180) {
      return rect;
    }
  }
  return null;
}

/// Devuelve los límites físicos de una bisagra horizontal (modo Flex / mesa) si existe.
Rect? horizontalHingeBounds(BuildContext context) {
  final media = MediaQuery.of(context);
  final size = media.size;
  for (final DisplayFeature feature in media.displayFeatures) {
    final isFoldOrHinge = feature.type == DisplayFeatureType.hinge ||
        feature.type == DisplayFeatureType.fold;
    if (!isFoldOrHinge) continue;
    final rect = feature.bounds;
    if (rect.width > rect.height &&
        rect.top >= 120 &&
        rect.bottom <= size.height - 120) {
      return rect;
    }
  }
  return null;
}

/// Padding horizontal corporativo según estado plegado / desplegado (16dp móvil, 20dp desplegado).
double foldableHorizontalPadding(BuildContext context) =>
    isCoverScreen(context) ? 16.0 : 20.0;

/// Contenedor Master–Detail con conciencia real de bisagra para Z Fold.
///
/// - En pantalla externa (< 600dp): muestra [startPane] (o [endPane] si [showEndOnCover]).
/// - En pantalla desplegada (>= 600dp):
///   * Si el dispositivo reporta una bisagra vertical (`DisplayFeature`), alinea
///     [startPane] a la izquierda del pliegue, deja el espacio de la bisagra con un
///     divisor neutro de 1px `#E5E7EB` y coloca [endPane] a la derecha.
///   * Si no hay bisagra reportada (o en tablet), divide según [startFraction]
///     con un divisor vertical limpio de 1px `#E5E7EB`.
class FoldableTwoPane extends StatelessWidget {
  final Widget startPane;
  final Widget endPane;
  final double startFraction;
  final double minStartWidth;
  final double maxStartWidth;
  final bool showDivider;
  final bool showEndOnCover;
  final double paneGap;

  const FoldableTwoPane({
    super.key,
    required this.startPane,
    required this.endPane,
    this.startFraction = 0.42,
    this.minStartWidth = 280,
    this.maxStartWidth = 460,
    this.showDivider = true,
    this.showEndOnCover = false,
    this.paneGap = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (isCoverScreen(context)) {
      return showEndOnCover ? endPane : startPane;
    }

    final hinge = verticalHingeBounds(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        if (!totalWidth.isFinite || totalWidth < kFoldableCoverBreakpoint) {
          return showEndOnCover ? endPane : startPane;
        }

        double leftWidth;
        double centerGap;

        if (hinge != null && hinge.left >= minStartWidth && (totalWidth - hinge.right) >= 240) {
          // Respetar físicamente el pliegue para no partir textos ni botones.
          leftWidth = hinge.left;
          centerGap = math.max(hinge.width, paneGap > 0 ? paneGap : 12.0);
        } else {
          leftWidth = (totalWidth * startFraction).clamp(
            minStartWidth,
            math.min(maxStartWidth, totalWidth * 0.52),
          );
          centerGap = paneGap > 0 ? paneGap : (showDivider ? 1.0 : 0.0);
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: leftWidth, child: startPane),
            if (centerGap > 0)
              SizedBox(
                width: centerGap,
                child: showDivider
                    ? const Center(
                        child: VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: PesaColors.border,
                        ),
                      )
                    : null,
              ),
            Expanded(child: endPane),
          ],
        );
      },
    );
  }
}

/// Par adaptativo de widgets: 1 columna apilada en pantalla externa (< 600dp)
/// y 2 columnas iguales lado a lado en pantalla desplegada (>= 600dp).
/// Si hay bisagra vertical activa, aplica una separación mínima segura de 20dp.
class FoldableTwoColumn extends StatelessWidget {
  final Widget first;
  final Widget second;
  final double horizontalGap;
  final double verticalGap;
  final CrossAxisAlignment rowCrossAxisAlignment;
  final int firstFlex;
  final int secondFlex;

  const FoldableTwoColumn({
    super.key,
    required this.first,
    required this.second,
    this.horizontalGap = 12,
    this.verticalGap = 12,
    this.rowCrossAxisAlignment = CrossAxisAlignment.start,
    this.firstFlex = 1,
    this.secondFlex = 1,
  });

  @override
  Widget build(BuildContext context) {
    if (isCoverScreen(context)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          first,
          SizedBox(height: verticalGap),
          second,
        ],
      );
    }

    final hinge = verticalHingeBounds(context);
    final gap = hinge != null ? math.max(horizontalGap, math.max(hinge.width, 16.0)) : horizontalGap;

    return Row(
      crossAxisAlignment: rowCrossAxisAlignment,
      children: [
        Expanded(flex: firstFlex, child: first),
        SizedBox(width: gap),
        Expanded(flex: secondFlex, child: second),
      ],
    );
  }
}

/// Rejilla adaptativa para formularios y bloques de captura.
/// - Pantalla externa (< 600dp): 1 columna vertical ergonómica.
/// - Pantalla desplegada (>= 600dp): [unfoldedColumns] columnas equilibradas.
class FoldableFormGrid extends StatelessWidget {
  final List<Widget> children;
  final int unfoldedColumns;
  final double spacing;
  final double runSpacing;

  const FoldableFormGrid({
    super.key,
    required this.children,
    this.unfoldedColumns = 2,
    this.spacing = 12,
    this.runSpacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    final cols = isCoverScreen(context) ? 1 : unfoldedColumns.clamp(1, 4);
    if (cols == 1) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: runSpacing),
            children[i],
          ],
        ],
      );
    }

    final hinge = verticalHingeBounds(context);
    final effectiveSpacing = (cols == 2 && hinge != null)
        ? math.max(spacing, math.max(hinge.width, 16.0))
        : spacing;

    final rows = <Widget>[];
    for (int i = 0; i < children.length; i += cols) {
      final slice = children.sublist(i, math.min(i + cols, children.length));
      if (rows.isNotEmpty) rows.add(SizedBox(height: runSpacing));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int c = 0; c < cols; c++) ...[
              if (c > 0) SizedBox(width: effectiveSpacing),
              Expanded(
                child: c < slice.length ? slice[c] : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// Diálogo corporativo limitado a [kFoldableDialogMaxWidth] (520dp) para que
/// nunca se estire ni quede partido de forma incómoda en pantallas desplegadas.
Future<T?> showFoldableDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  double maxWidth = kFoldableDialogMaxWidth,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: builder(ctx),
      ),
    ),
  );
}

/// BottomSheet corporativo limitado a [kFoldableDialogMaxWidth] (520dp)
/// con bordes superiores redondeados 16dp y fondo blanco puro `#FFFFFF`.
Future<T?> showFoldableBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  double maxWidth = kFoldableDialogMaxWidth,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: PesaColors.surface,
    constraints: BoxConstraints(maxWidth: maxWidth),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      side: BorderSide(color: PesaColors.border),
    ),
    builder: builder,
  );
}
