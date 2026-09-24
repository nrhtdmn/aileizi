import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('parent smoke test renders app shell', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Aileİzi')),
      ),
    );

    expect(find.text('Aileİzi'), findsOneWidget);
  });
}
