import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infosnap_app/core/services/api_service.dart';
import 'package:infosnap_app/features/notes/note_detail_screen.dart';

void main() {
  testWidgets('NoteDetailScreen renders key sections for a provided note',
      (WidgetTester tester) async {
    final note = Note(
      id: 'note-123',
      title: 'My Graduation Day',
      contentType: 'image',
      sourceUrl: 'https://example.com/original',
      sourceDomain: 'example.com',
      createdAt: DateTime(2026, 5, 1),
      tags: const ['memory', 'photo'],
      contentPreview:
          'A graduation photo with family. Captured during ceremony celebrations.',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: NoteDetailScreen(
          noteId: note.id,
          note: note,
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('My Graduation Day'), findsOneWidget);
    expect(find.text('Key Highlights'), findsOneWidget);
    expect(find.text('View Original'), findsOneWidget);
  });
}
