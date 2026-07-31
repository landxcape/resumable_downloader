import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the mobile developer transfer lab navigation', (
    tester,
  ) async {
    await tester.pumpWidget(const MainApp());

    expect(find.text('Transfers'), findsWidgets);
    expect(find.text('Presets'), findsOneWidget);
    expect(find.text('Configuration'), findsOneWidget);

    await tester.tap(find.text('Presets'));
    await tester.pumpAndSettle();

    expect(find.text('Multipart fixture'), findsOneWidget);
  });

  testWidgets('queues a URL without using disposed sheet controllers', (
    tester,
  ) async {
    await tester.pumpWidget(const MainApp());

    await tester.tap(find.text('Add URL'));
    await tester.pumpAndSettle();
    expect(find.text('normal'), findsOneWidget);
    expect(find.text('foreground'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Download URL'),
      'https://example.com/archive.bin',
    );
    await tester.tap(find.text('Queue download'));
    await tester.pumpAndSettle();

    expect(find.text('archive.bin'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offers a scoped multi-file operation preset', (tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.tap(find.text('Presets'));
    await tester.pumpAndSettle();

    expect(find.text('Start scoped batch'), findsOneWidget);
  });
}
