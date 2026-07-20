import 'package:example/main.dart';
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
}
