import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:acceso/main.dart';

void main() {
  testWidgets('Login screen smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that the login screen title and description are present.
    expect(find.text('CONTROL DE ACCESO'), findsOneWidget);
    expect(find.text('Ingresa tu clave asignada para iniciar el turno'), findsOneWidget);

    // Verify that the password field and submit button exist.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('INICIAR TURNO'), findsOneWidget);
  });
}
