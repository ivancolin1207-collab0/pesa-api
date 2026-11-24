import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Alcance heredado para bloquear automáticamente el scroll padre
/// cuando cualquier [SignatureGestureShield] descendiente recibe un trazo
/// (dedo, S Pen / stylus o ratón).
class _SigningScrollLockScope extends InheritedWidget {
  const _SigningScrollLockScope({
    required this.onSigningChanged,
    required super.child,
  });

  final ValueChanged<bool> onSigningChanged;

  static _SigningScrollLockScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_SigningScrollLockScope>();
  }

  @override
  bool updateShouldNotify(_SigningScrollLockScope oldWidget) => false;
}

/// Envuelve un `SingleChildScrollView` / `ListView` de captura para desactivar
/// su desplazamiento (`NeverScrollableScrollPhysics`) automáticamente mientras
/// el usuario firma en cualquier [SignatureGestureShield] interno, ya sea con
/// dedo o S Pen / Stylus en el Samsung Galaxy Z Fold8 Ultra.
class SigningScrollLock extends StatefulWidget {
  const SigningScrollLock({
    super.key,
    required this.builder,
    this.idlePhysics = const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    ),
  });

  final Widget Function(BuildContext context, ScrollPhysics physics, bool isSigning) builder;
  final ScrollPhysics idlePhysics;

  @override
  State<SigningScrollLock> createState() => _SigningScrollLockState();
}

class _SigningScrollLockState extends State<SigningScrollLock> {
  int _activePads = 0;

  void _handleSigningChanged(bool active) {
    final prevLocked = _activePads > 0;
    if (active) {
      _activePads++;
    } else if (_activePads > 0) {
      _activePads--;
    }
    final nowLocked = _activePads > 0;
    if (prevLocked != nowLocked && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _activePads > 0;
    final physics = locked ? const NeverScrollableScrollPhysics() : widget.idlePhysics;
    return _SigningScrollLockScope(
      onSigningChanged: _handleSigningChanged,
      child: widget.builder(context, physics, locked),
    );
  }
}

/// Aísla un canvas de firma de cualquier `Scrollable` / `PageView` / `TabBarView`
/// ancestro para que la pantalla quede 100 % fija al apoyar el dedo, el S Pen / lápiz
/// o la palma mientras se firma.
///
/// - Un [EagerGestureRecognizer] reclama la arena de gestos en el *pointer down*,
///   así ningún recognizer de scroll del padre llega a activarse.
/// - Los recognizers vertical/horizontal no-op cubren el desplazamiento en ambos ejes.
/// - `Signature` dibuja con un `Listener` de eventos crudos, por lo que el trazo
///   no se ve afectado por la arena (compatible con dedo y S Pen / Stylus).
/// - Notifica tanto a [onSigningChanged] como automáticamente a cualquier
///   [SigningScrollLock] ancestro.
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
  _SigningScrollLockScope? _scope;
  bool _notifiedActive = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = _SigningScrollLockScope.maybeOf(context);
  }

  void _setActive(bool active) {
    if (_notifiedActive == active) return;
    _notifiedActive = active;
    widget.onSigningChanged?.call(active);
    _scope?.onSigningChanged(active);
  }

  void _down(PointerDownEvent e) {
    final wasEmpty = _activePointers.isEmpty;
    _activePointers.add(e.pointer);
    if (wasEmpty) _setActive(true);
  }

  void _up(PointerEvent e) {
    if (_activePointers.remove(e.pointer) && _activePointers.isEmpty) {
      _setActive(false);
    }
  }

  @override
  void dispose() {
    if (_notifiedActive) {
      _notifiedActive = false;
      widget.onSigningChanged?.call(false);
      _scope?.onSigningChanged(false);
    }
    _activePointers.clear();
    super.dispose();
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
