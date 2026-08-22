import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ProviderScope renders a basic app shell',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: Text('InfoSnap')),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('InfoSnap'), findsOneWidget);
  });
}
