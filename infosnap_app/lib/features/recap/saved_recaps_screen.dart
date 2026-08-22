// ignore_for_file: deprecated_member_use
/// Profile sub-screen listing all recaps the user has bookmarked.
/// Tapping a row opens the full mosaic view backed by the stored payload.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/responsive.dart';
import 'recap_api.dart';
import 'recap_models.dart';
import 'recap_screen.dart';

final _savedListProvider =
    FutureProvider.autoDispose<List<SavedRecapSummary>>((ref) async {
  return RecapApi().listSaved();
});

class SavedRecapsScreen extends ConsumerWidget {
  const SavedRecapsScreen({super.key});

  static const Color _bg = Color(0xFF0A0A0F);
  static const Color _surface = Color(0xFF14141B);
  static const Color _ink = Color(0xFFF5F5F7);
  static const Color _inkMuted = Color(0xFFA0A0AA);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_savedListProvider);
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        foregroundColor: _ink,
        title: Text('Saved recaps'),
      ),
      body: async.when(
        loading: () => Center(child: CircularProgressIndicator(color: _ink)),
        error: (e, _) => Center(
          child: Padding(
            padding: EdgeInsets.all(Responsive.pp(24)),
            child: Text('Could not load saved recaps\n$e',
                textAlign: TextAlign.center,
                style: TextStyle(color: _inkMuted)),
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: EdgeInsets.all(Responsive.pp(32)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('🔖', style: TextStyle(fontSize: Responsive.sp(56))),
                    SizedBox(height: Responsive.wp(16)),
                    Text('No saved recaps yet',
                        style: TextStyle(
                            color: _ink,
                            fontSize: Responsive.sp(17),
                            fontWeight: FontWeight.w600)),
                    SizedBox(height: Responsive.wp(6)),
                    Text(
                      'Tap the bookmark on any recap to save it here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _inkMuted,
                          fontSize: Responsive.sp(13),
                          height: 1.4),
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_savedListProvider),
            child: ListView.separated(
              padding: EdgeInsets.fromLTRB(
                Responsive.pp(16),
                Responsive.pp(8),
                Responsive.pp(16),
                Responsive.pp(24),
              ),
              itemCount: items.length,
              separatorBuilder: (_, __) => SizedBox(height: Responsive.wp(10)),
              itemBuilder: (_, i) => _SavedTile(
                item: items[i],
                onTap: () => _openSaved(context, items[i]),
                onDelete: () => _delete(context, ref, items[i]),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openSaved(BuildContext context, SavedRecapSummary item) async {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => Center(child: CircularProgressIndicator(color: _ink)),
    );
    final payload = await RecapApi().getSaved(item.id);
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss loader
    if (payload == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open recap')),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RecapScreen(prebuilt: payload),
    ));
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, SavedRecapSummary item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _surface,
        insetPadding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(20),
          vertical: Responsive.pp(24),
        ),
        title: Text(
          'Delete this recap?',
          style: TextStyle(color: _ink, fontSize: Responsive.sp(18)),
        ),
        content: Text(
            '"${item.title ?? 'this recap'}" will be removed from your profile.',
            style: TextStyle(color: _inkMuted, fontSize: Responsive.sp(14))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(_, false),
            child:
                Text('Cancel', style: TextStyle(fontSize: Responsive.sp(14))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(_, true),
            child: Text(
              'Delete',
              style: TextStyle(
                  color: const Color(0xFFEF4444), fontSize: Responsive.sp(14)),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await RecapApi().deleteSaved(item.id);
    if (done) {
      ref.invalidate(_savedListProvider);
    }
  }
}

class _SavedTile extends StatelessWidget {
  final SavedRecapSummary item;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _SavedTile(
      {required this.item, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF14141B),
      borderRadius: BorderRadius.circular(Responsive.wp(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(Responsive.wp(14)),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(Responsive.pp(10)),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(Responsive.wp(10)),
                child: SizedBox(
                  width: Responsive.wp(64),
                  height: Responsive.wp(64),
                  child: item.coverThumb != null && item.coverThumb!.isNotEmpty
                      ? Image.network(item.coverThumb!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Container(color: Colors.white12))
                      : Container(
                          color: Colors.white12,
                          child: Icon(Icons.collections_bookmark_outlined,
                              color: Colors.white38, size: Responsive.sp(24)),
                        ),
                ),
              ),
              SizedBox(width: Responsive.wp(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title ?? 'Recap',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: const Color(0xFFF5F5F7),
                            fontWeight: FontWeight.w600,
                            fontSize: Responsive.sp(14))),
                    SizedBox(height: Responsive.wp(4)),
                    Text(
                      '${item.period.label} · ${item.totalNotes} snaps',
                      style: TextStyle(
                          color: const Color(0xFFA0A0AA),
                          fontSize: Responsive.sp(12)),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.more_horiz,
                    color: const Color(0xFFA0A0AA), size: Responsive.sp(24)),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
