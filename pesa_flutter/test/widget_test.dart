// Reemplaza la plantilla obsoleta "Counter increments" (la app no tiene
// contador). Verifica que el canvas de firma bloquea el scroll del padre.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pesa_tablet/widgets/signature_shield.dart';

void main() {
  testWidgets('SignatureGestureShield bloquea el scroll al firmar',
      (WidgetTester tester) async {
    final controller = ScrollController();
    final cambios = <bool>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          controller: controller,
          children: [
            const SizedBox(height: 200),
            SignatureGestureShield(
              onSigningChanged: cambios.add,
              child: Container(
                key: const Key('canvas'),
                height: 300,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 2000),
          ],
        ),
      ),
    ));

    // Arrastre vertical sobre el canvas → el ListView NO debe desplazarse.
    await tester.drag(find.byKey(const Key('canvas')), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(controller.offset, 0.0);
    expect(cambios, [true, false]);

    // Arrastre fuera del canvas → el scroll sigue funcionando normalmente.
    await tester.dragFrom(const Offset(400, 100), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
  });
}
