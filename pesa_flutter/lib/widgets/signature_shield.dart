import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Aísla un canvas de firma de cualquier `Scrollable` / `PageView` / `TabBarView`
/// ancestro para que la pantalla quede 100 % fija al apoyar el dedo, el lápiz
/// o la palma mientras se firma.
///
/// - Un [EagerGestureRecognizer] reclama la arena de gestos en el *pointer down*,
///   así ningún recognizer de scroll del padre llega a activarse.
/// - Los recognizers vertical/horizontal no-op cubren el caso del snippet clásico
///   (`onVerticalDragUpdate: (_) {}` / `onHorizontalDragUpdate: (_) {}`).
/// - `Signature` dibuja con un `Listener` de eventos crudos, por lo que el trazo
///   no se ve afectado por la arena.
/// - [onSigningChanged] permite al padre cambiar su `physics` a
///   `NeverScrollableScrollPhysics` mientras hay un dedo/lápiz sobre el canvas.
class SignatureGestureShield extends StatefulWidget {
  const SignatureGestureShield({
    super.key,
    required this.child,
    this.onSigningChanged,
  });

  final Widget child;
  final ValueChanged<bool>? onSigningChanged;

  @override
  State<SignatureGestureShield> createState() => _SignatureGestureShieldState();
}

class _SignatureGestureShieldState extends State<SignatureGestureShield> {
  final Set<int> _activePointers = <int>{};

  void _down(PointerDownEvent e) {
    final wasEmpty = _activePointers.isEmpty;
    _activePointers.add(e.pointer);
    if (wasEmpty) widget.onSigningChanged?.call(true);
  }

  void _up(PointerEvent e) {
    if (_activePointers.remove(e.pointer) && _activePointers.isEmpty) {
      widget.onSigningChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          EagerGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
            () => EagerGestureRecognizer(),
            (EagerGestureRecognizer _) {},
          ),
          VerticalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer(),
            (VerticalDragGestureRecognizer r) => r.onUpdate = (_) {},
          ),
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(),
            (HorizontalDragGestureRecognizer r) => r.onUpdate = (_) {},
          ),
        },
        child: widget.child,
      ),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(IntProperty('activePointers', _activePointers.length));
  }
}
