import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../../core/theme/app_colors.dart';
import '../../core/config/app_config.dart';
import '../../core/utils/responsive.dart';
import '../../core/widgets/hexagon_background.dart';
import '../../core/services/api_service.dart';
import '../../core/services/auth_service.dart';

/// Chat message model
class ChatMessage {
  final String role; // 'user' or 'assistant'
  final String content;
  final List<SearchResult>? sources;
  final bool isLoading;
  final String? error;
  final SearchDeeper? searchDeeper;
  final ResultPagination? resultPagination;
  final String? queryType; // 'question' or 'keyword'
  final String? originalQuery; // Stored for search deeper

  ChatMessage({
    required this.role,
    required this.content,
    this.sources,
    this.isLoading = false,
    this.error,
    this.searchDeeper,
    this.resultPagination,
    this.queryType,
    this.originalQuery,
  });
}

/// Search result from RAG
class SearchResult {
  final String noteId;
  final String title;
  final String? tag;
  final String? fileType;
  final String? originalFilename;
  final String? viewUrl;
  final String? sourceUrl;
  final String? socialSource;
  final String? snippet; // Preview text from chunk_content
  final String? description; // User-provided caption / note text
  /// Stable 1-based citation index emitted by the worker's vector_search
  /// tool. Same note keeps the same index across refinement calls so
  /// carousel positions match the planner's inline [N] markers.
  final int? citationIndex;

  SearchResult({
    required this.noteId,
    required this.title,
    this.tag,
    this.fileType,
    this.originalFilename,
    this.viewUrl,
    this.sourceUrl,
    this.socialSource,
    this.snippet,
    this.description,
    this.citationIndex,
  });

  /// Generic auto-titles produced for social posts when there's no real title
  /// (e.g. "Instagram Post", "LinkedIn Post", "Tweet"). When the title looks
  /// generic, prefer the user's description / first line of content so the
  /// chip in chat shows something meaningful.
  static final RegExp _genericSocialTitleRe = RegExp(
    r'^\s*(?:'
    r'instagram(?:\s+(?:reel|post|story|video))?'
    r'|linkedin(?:\s+(?:post|update|article))?'
    r'|tweet|twitter(?:\s+(?:post|tweet))?'
    r'|reddit(?:\s+(?:post|comment))?'
    r'|facebook(?:\s+(?:post|story))?'
    r'|youtube(?:\s+(?:video|short))?'
    r'|untitled'
    r')\s*$',
    caseSensitive: false,
  );

  /// Title actually shown in the UI. Falls back to description / snippet
  /// first line when the raw title is empty or a generic auto-title.
  String get displayTitle {
    final raw = title.trim();
    final generic = raw.isEmpty || _genericSocialTitleRe.hasMatch(raw);
    if (!generic) return raw;
    final fallback =
        _firstMeaningfulLine(description) ?? _firstMeaningfulLine(snippet);
    if (fallback != null && fallback.isNotEmpty) {
      // Keep the auto-title as a small prefix so the platform is still visible.
      if (raw.isNotEmpty && raw.toLowerCase() != 'untitled') {
        return '$raw — $fallback';
      }
      return fallback;
    }
    return raw.isEmpty ? 'Untitled' : raw;
  }

  static String? _firstMeaningfulLine(String? s) {
    if (s == null) return null;
    final cleaned = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return null;
    // Cap to ~100 chars so chips stay reasonable.
    return cleaned.length > 100 ? '${cleaned.substring(0, 97)}…' : cleaned;
  }

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      noteId: json['note_id'] ?? '',
      title: json['title'] ?? 'Untitled',
      tag: json['tag'],
      fileType: json['file_type'],
      originalFilename: json['original_filename'],
      viewUrl: json['view_url'],
      sourceUrl: json['source_url'] ??
          json['sourceUrl'] ??
          json['metadata']?['source_url'] ??
          json['metadata']?['social']?['source_url'],
      socialSource: json['social_source'] ??
          json['socialSource'] ??
          json['metadata']?['social']?['source'] ??
          json['metadata']?['social']?['source_app'],
      snippet:
          json['chunk_content'] ?? json['snippet'] ?? json['content_preview'],
      description: json['description'],
      citationIndex: json['citation_index'] is num
          ? (json['citation_index'] as num).toInt()
          : null,
    );
  }
}

/// "Search deeper" data — tells the client which note_ids to exclude on the next call
class SearchDeeper {
  final bool available;
  final List<String> excludeNoteIds;
  final String message;

  SearchDeeper({
    required this.available,
    required this.excludeNoteIds,
    required this.message,
  });

  factory SearchDeeper.fromJson(Map<String, dynamic> json) {
    return SearchDeeper(
      available: json['available'] ?? false,
      excludeNoteIds: (json['exclude_note_ids'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      message: json['message'] ?? '',
    );
  }
}

/// Remaining cards from the same completed retrieval. Unlike Search Deeper,
/// paging these cards does not perform another backend search.
class ResultPagination {
  final int pageSize;
  final List<SearchResult> remainingSources;

  ResultPagination({required this.pageSize, required this.remainingSources});

  factory ResultPagination.fromJson(Map<String, dynamic> json) {
    return ResultPagination(
      pageSize: json['page_size'] as int? ?? 10,
      remainingSources: (json['remaining_results'] as List<dynamic>? ?? [])
          .map((item) => SearchResult.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Chat state provider
final chatMessagesProvider =
    StateNotifierProvider<ChatNotifier, List<ChatMessage>>((ref) {
  return ChatNotifier();
});

class ChatNotifier extends StateNotifier<List<ChatMessage>> {
  ChatNotifier() : super([]);

  void addUserMessage(String content) {
    state = [...state, ChatMessage(role: 'user', content: content)];
  }

  void addLoadingMessage() {
    state = [
      ...state,
      ChatMessage(role: 'assistant', content: '', isLoading: true)
    ];
  }

  void updateLastMessage(
    String content, {
    List<SearchResult>? sources,
    String? error,
    SearchDeeper? searchDeeper,
    ResultPagination? resultPagination,
    String? queryType,
    String? originalQuery,
  }) {
    if (state.isEmpty) return;
    final messages = [...state];
    messages[messages.length - 1] = ChatMessage(
      role: 'assistant',
      content: content,
      sources: sources,
      error: error,
      searchDeeper: searchDeeper,
      resultPagination: resultPagination,
      queryType: queryType,
      originalQuery: originalQuery,
    );
    state = messages;
  }

  /// Add search deeper results as a new message and remove button from previous message

  /// Clear all searchDeeper buttons from all messages
  void clearAllSearchDeeper() {
    final messages = state.map((msg) {
      if (msg.searchDeeper != null) {
        return ChatMessage(
          role: msg.role,
          content: msg.content,
          sources: msg.sources,
          error: msg.error,
          searchDeeper: null,
          resultPagination: msg.resultPagination,
          isLoading: msg.isLoading,
          queryType: msg.queryType,
          originalQuery: msg.originalQuery,
        );
      }
      return msg;
    }).toList();
    state = messages;
  }

  void addSearchDeeperResults({
    required List<SearchResult> newSources,
    SearchDeeper? searchDeeper,
    required String originalQuery,
  }) {
    if (state.isEmpty) return;
    final messages = [...state];
    final lastMsg = messages[messages.length - 1];
    if (lastMsg.role != 'assistant') return;

    // Remove "Search Deeper" button from the previous message
    messages[messages.length - 1] = ChatMessage(
      role: 'assistant',
      content: lastMsg.content,
      sources: lastMsg.sources,
      searchDeeper: null, // clear the button
      queryType: lastMsg.queryType,
      originalQuery: lastMsg.originalQuery,
    );

    // Add new message with the deeper results
    if (newSources.isEmpty) {
      messages.add(ChatMessage(
        role: 'assistant',
        content:
            'No more results found for "$originalQuery". Try rephrasing your query for different results.',
        sources: [],
        searchDeeper: null,
        queryType: lastMsg.queryType,
        originalQuery: originalQuery,
      ));
    } else {
      final resultCount = newSources.length;
      messages.add(ChatMessage(
        role: 'assistant',
        content:
            'Found $resultCount more result${resultCount != 1 ? 's' : ''} for "$originalQuery":',
        sources: newSources,
        searchDeeper: searchDeeper,
        queryType: lastMsg.queryType,
        originalQuery: originalQuery,
      ));
    }

    state = messages;
  }

  void clear() {
    state = [];
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  final String? initialQuery;
  final List<String> initialTags;
  final String? anchoredNoteId;
  final String? anchoredNoteTitle;
  const ChatScreen({
    super.key,
    this.initialQuery,
    this.initialTags = const [],
    this.anchoredNoteId,
    this.anchoredNoteTitle,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;
  final Set<String> _selectedTags = {}; // Empty means "All"
  List<String> _availableTags = [];
  bool _tagsLoading = false;
  bool _showOverflowTags = false;

  /// One horizontal ScrollController per bot message that has a source
  /// carousel. Lets citation chips inside the answer scroll to the tapped
  /// card. Keyed by identity of the message so multi-turn chats keep
  /// their own carousel positions.
  final Map<int, ScrollController> _carouselCtrls = {};
  ScrollController _carouselCtrlFor(ChatMessage m) =>
      _carouselCtrls.putIfAbsent(identityHashCode(m), () => ScrollController());

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    for (final c in _carouselCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.anchoredNoteId != null) {
      // Defer reset to avoid mutating provider state during widget build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(chatMessagesProvider.notifier).clear();
      });
    }
    // Pre-select tags if passed from navigation
    if (widget.initialTags.isNotEmpty && widget.anchoredNoteId == null) {
      _selectedTags.addAll(widget.initialTags);
    }
    if (widget.anchoredNoteId == null) {
      _loadTags();
    }
    // Auto-send only when initialQuery is set AND we are NOT in anchored (snap context) mode
    if (widget.initialQuery != null &&
        widget.initialQuery!.isNotEmpty &&
        widget.anchoredNoteId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(chatMessagesProvider.notifier).clear();
        _controller.text = widget.initialQuery!;
        _sendMessage();
      });
    }
  }

  Future<void> _loadTags({bool forceRefresh = false}) async {
    setState(() => _tagsLoading = true);
    try {
      final tags = await ApiService().fetchTags(forceRefresh: forceRefresh);
      if (mounted) {
        setState(() {
          _availableTags = tags;
          _tagsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _tagsLoading = false);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final message = _controller.text.trim();
    if (message.isEmpty || _isSending) return;

    HapticFeedback.lightImpact();
    _controller.clear();
    setState(() => _isSending = true);

    // Check if this is the first message (fresh chat = new session)
    final isNewSession = ref.read(chatMessagesProvider).isEmpty;

    // Add user message
    ref.read(chatMessagesProvider.notifier).clearAllSearchDeeper();
    ref.read(chatMessagesProvider.notifier).addUserMessage(message);
    _scrollToBottom();

    // Add loading message
    ref.read(chatMessagesProvider.notifier).addLoadingMessage();
    _scrollToBottom();

    try {
      // In anchored mode, rely on explicit note_id scoping (not title-prefix heuristics).
      final effectiveQuery = message;

      // Call RAG search API
      final token = Supabase.instance.client.auth.currentSession?.accessToken;
      if (token == null) {
        ref.read(chatMessagesProvider.notifier).updateLastMessage(
              'Please sign in to use chat.',
              error: 'Not authenticated',
            );
        setState(() => _isSending = false);
        return;
      }

      final response = await http.post(
        Uri.parse(AppConfig.activeSearchUrl),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'query': effectiveQuery,
          'client_source': 'flutter',
          if (widget.anchoredNoteId != null) 'note_id': widget.anchoredNoteId,
          if (widget.anchoredNoteId == null && _selectedTags.isNotEmpty)
            'tag_filter': _selectedTags.toList(),
          if (isNewSession) 'new_session': true,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        var answer = data['answer'] as String? ?? '';
        final results = (data['results'] as List<dynamic>?)
            ?.map((r) => SearchResult.fromJson(r as Map<String, dynamic>))
            .toList();

        // Parse search_deeper data for "Search Deeper" feature
        SearchDeeper? searchDeeper;
        if (data['search_deeper'] != null) {
          searchDeeper = SearchDeeper.fromJson(
              data['search_deeper'] as Map<String, dynamic>);
        }
        ResultPagination? resultPagination;
        if (data['result_pagination'] != null) {
          resultPagination = ResultPagination.fromJson(
              data['result_pagination'] as Map<String, dynamic>);
        }

        // Parse query type (question vs keyword)
        final queryType = data['query_type'] as String?;
        final effectiveQuery = _extractEffectiveQuery(data) ?? message;

        // Strip "📎 Documents found:" section from answer (shown as source chips instead)
        final docFoundIdx = answer.indexOf('**📎 Documents found:**');
        if (docFoundIdx != -1) {
          answer = answer.substring(0, docFoundIdx).trimRight();
        }

        // Friendly message when no answer but sources exist
        if (answer.isEmpty || answer == 'No answer found.') {
          if (results != null && results.isNotEmpty) {
            answer =
                'I found ${results.length} relevant document${results.length > 1 ? 's' : ''} for your query:';
          } else {
            answer = 'No results found. Try rephrasing your question.';
          }
        }

        ref.read(chatMessagesProvider.notifier).updateLastMessage(
              answer,
              sources: results,
              searchDeeper: searchDeeper,
              resultPagination: resultPagination,
              queryType: queryType,
              originalQuery: effectiveQuery,
            );
      } else {
        final quotaMessage = _quotaErrorMessage(response.body);
        ref.read(chatMessagesProvider.notifier).updateLastMessage(
              quotaMessage ??
                  'Sorry, I couldn\'t process your request. Please try again.',
              error: quotaMessage != null
                  ? 'quota_limit'
                  : 'Error ${response.statusCode}',
            );
      }
    } catch (e) {
      ref.read(chatMessagesProvider.notifier).updateLastMessage(
            'Connection error. Please check your internet and try again.',
            error: e.toString(),
          );
    }

    setState(() => _isSending = false);
    _scrollToBottom();
  }

  /// Load more results by re-calling main search with exclude_note_ids
  bool _isLoadingMore = false;

  Future<void> _loadMoreResults(ChatMessage lastMessage) async {
    final searchDeeper = lastMessage.searchDeeper;
    if (searchDeeper == null || !searchDeeper.available || _isLoadingMore)
      return;

    HapticFeedback.lightImpact();
    setState(() => _isLoadingMore = true);

    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken;
      if (token == null) {
        setState(() => _isLoadingMore = false);
        return;
      }

      final requestBody = {
        'query': lastMessage.originalQuery ?? '',
        'client_source': 'flutter',
        'exclude_note_ids': searchDeeper.excludeNoteIds,
        if (widget.anchoredNoteId != null) 'note_id': widget.anchoredNoteId,
        if (widget.anchoredNoteId == null && _selectedTags.isNotEmpty)
          'tag_filter': _selectedTags.toList(),
      };
      debugPrint(
          'Search deeper request: exclude_note_ids count=${searchDeeper.excludeNoteIds.length}, ids=${searchDeeper.excludeNoteIds}');

      final response = await http.post(
        Uri.parse(AppConfig.activeSearchUrl),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: json.encode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final newResults = (data['results'] as List<dynamic>?)
                ?.map((r) => SearchResult.fromJson(r as Map<String, dynamic>))
                .toList() ??
            [];

        // Parse new search_deeper data
        SearchDeeper? newSearchDeeper;
        if (data['search_deeper'] != null) {
          newSearchDeeper = SearchDeeper.fromJson(
              data['search_deeper'] as Map<String, dynamic>);
        }

        // Add deeper results as a new message
        ref.read(chatMessagesProvider.notifier).addSearchDeeperResults(
              newSources: newResults,
              searchDeeper: newSearchDeeper,
              originalQuery: _extractEffectiveQuery(data) ??
                  lastMessage.originalQuery ??
                  '',
            );

        _scrollToBottom();
      } else {
        final quotaMessage = _quotaErrorMessage(response.body);
        if (quotaMessage != null) {
          ref.read(chatMessagesProvider.notifier).addSearchDeeperResults(
            newSources: const [],
            searchDeeper: null,
            originalQuery: lastMessage.originalQuery ?? '',
          );
          ref.read(chatMessagesProvider.notifier).updateLastMessage(
                quotaMessage,
                error: 'quota_limit',
              );
        }
      }
    } catch (e) {
      debugPrint('Search deeper error: $e');
    }

    setState(() => _isLoadingMore = false);
  }

  String? _extractEffectiveQuery(Map<String, dynamic> data) {
    final direct = data['effective_query'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct.trim();
    }

    final resolved = data['resolved_query'];
    if (resolved is String && resolved.trim().isNotEmpty) {
      return resolved.trim();
    }

    final metadata = data['metadata'];
    if (metadata is Map<String, dynamic>) {
      final spellCheck = metadata['spell_check'];
      if (spellCheck is Map<String, dynamic>) {
        final rewritten = spellCheck['query_rewritten'];
        if (rewritten is String && rewritten.trim().isNotEmpty) {
          return rewritten.trim();
        }
      }
    }

    return null;
  }

  String? _quotaErrorMessage(String body) {
    try {
      final data = json.decode(body);
      if (data is! Map<String, dynamic>) return null;
      final code = data['code']?.toString();
      if (code != 'MONTHLY_SNAPBOT_LIMIT_REACHED') return null;
      final used = data['used']?.toString() ?? '-';
      final limit = data['limit']?.toString() ?? '-';
      final resetAt = _formatQuotaReset(data['reset_at']?.toString());
      return 'You have reached your monthly SnapBot search limit ($used/$limit). It will reset $resetAt.';
    } catch (_) {
      return null;
    }
  }

  String _formatQuotaReset(String? value) {
    if (value == null || value.isEmpty) return 'next month';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return 'on $value';
    final local = parsed.toLocal();
    return 'on ${local.day}/${local.month}/${local.year} at ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatMessagesProvider);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          const Positioned.fill(child: SoftGridBackground()),
          SafeArea(
            child: Column(
              children: [
                _buildSnapBotHeader(theme),
                // Context banner when opened from a specific snap
                if (widget.anchoredNoteTitle != null &&
                    widget.anchoredNoteTitle!.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                        horizontal: Responsive.pp(16),
                        vertical: Responsive.pp(10)),
                    color: AppColors.primary.withOpacity(0.12),
                    child: Row(
                      children: [
                        Icon(Icons.attach_file_rounded,
                            size: Responsive.sp(14), color: AppColors.primary),
                        SizedBox(width: Responsive.wp(6)),
                        Expanded(
                          child: Text(
                            'Asking about: ${widget.anchoredNoteTitle}',
                            style: GoogleFonts.inter(
                              fontSize: Responsive.sp(12),
                              fontWeight: FontWeight.w500,
                              color: AppColors.primary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: messages.isEmpty
                      ? _buildWelcomeState()
                      : ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.all(Responsive.pp(14)),
                          itemCount: messages.length,
                          itemBuilder: (context, index) {
                            final msg = messages[index];
                            if (msg.role == 'user') {
                              return _buildUserMessage(msg.content,
                                  delay:
                                      index == messages.length - 1 ? 0 : null);
                            } else {
                              return _buildBotMessage(msg,
                                  delay: index == messages.length - 1
                                      ? 100
                                      : null);
                            }
                          },
                        ),
                ),
                if (widget.anchoredNoteId == null) _buildTagChips(),
                _buildInputArea(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapBotHeader(ThemeData theme) {
    return Container(
      margin: EdgeInsets.fromLTRB(
        Responsive.pp(12),
        Responsive.pp(8),
        Responsive.pp(12),
        Responsive.pp(8),
      ),
      padding: EdgeInsets.fromLTRB(
        Responsive.pp(14),
        Responsive.pp(12),
        Responsive.pp(8),
        Responsive.pp(12),
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFEDE9FE),
            Color(0xFFE0F2FE),
            Color(0xFFFFE4D6),
          ],
        ),
        borderRadius: BorderRadius.circular(Responsive.wp(22)),
        border: Border.all(color: Colors.white.withOpacity(0.6)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF8B5CF6).withOpacity(0.14),
            blurRadius: Responsive.wp(20),
            offset: Offset(0, Responsive.wp(8)),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: Responsive.wp(40),
            height: Responsive.wp(40),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF8B5CF6), Color(0xFF06B6D4)],
              ),
              borderRadius: BorderRadius.circular(Responsive.wp(12)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF8B5CF6).withOpacity(0.25),
                  blurRadius: Responsive.wp(8),
                  offset: Offset(0, Responsive.wp(3)),
                ),
              ],
            ),
            child: Icon(
              Icons.auto_awesome_rounded,
              size: Responsive.sp(20),
              color: Colors.white,
            ),
          ),
          SizedBox(width: Responsive.wp(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SnapBot',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: Responsive.sp(22),
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F172A),
                    height: 1.1,
                  ),
                ),
                SizedBox(height: Responsive.wp(2)),
                Text(
                  'Ask anything about your snaps',
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(12),
                    color: const Color(0xFF475569),
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _showSnapBotHelpDialog,
            icon: Icon(Icons.help_outline_rounded,
                size: Responsive.sp(20), color: const Color(0xFF0F172A)),
            tooltip: 'Help',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: () {
              ref.read(chatMessagesProvider.notifier).clear();
            },
            icon: Icon(Icons.delete_outline,
                size: Responsive.sp(20), color: const Color(0xFF0F172A)),
            tooltip: 'Clear chat',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  void _showSnapBotHelpDialog() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Responsive.wp(20)),
        ),
        insetPadding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(22),
          vertical: Responsive.pp(24),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(Responsive.pp(18)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: Responsive.wp(38),
                    height: Responsive.wp(38),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(Responsive.wp(12)),
                    ),
                    child: Icon(Icons.auto_awesome_rounded,
                        color: AppColors.primary, size: Responsive.sp(20)),
                  ),
                  SizedBox(width: Responsive.wp(10)),
                  Expanded(
                    child: Text(
                      'SnapBot search tips',
                      style: GoogleFonts.spaceGrotesk(
                        color: theme.colorScheme.onSurface,
                        fontSize: Responsive.sp(18),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              SizedBox(height: Responsive.wp(10)),
              Text(
                'Type what you remember, review matching sources, then narrow results with tags or search deeper when needed.',
                style: GoogleFonts.inter(
                  color: theme.colorScheme.onSurface.withOpacity(0.72),
                  fontSize: Responsive.sp(12),
                  height: 1.45,
                ),
              ),
              SizedBox(height: Responsive.wp(14)),
              _SnapBotHelpImageCard(isDark: isDark),
              SizedBox(height: Responsive.wp(16)),
              _SnapBotHelpBullet(
                icon: Icons.chat_bubble_outline_rounded,
                title: 'Ask naturally',
                body:
                    'Search like you would describe the memory: "places to eat", "website design ideas", or "that pasta reel I saved".',
              ),
              _SnapBotHelpBullet(
                icon: Icons.filter_alt_outlined,
                title: 'Filter by tag',
                body:
                    'Use Filter by Tag to limit SnapBot to one area, such as food, work, recipes, or travel.',
              ),
              _SnapBotHelpBullet(
                icon: Icons.travel_explore_rounded,
                title: 'Search deeper',
                body:
                    'Use Search Deeper when results are related but you want SnapBot to look harder across more saved snaps.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWelcomeState() {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(Responsive.pp(Responsive.isNarrow ? 16 : 32)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: Responsive.wp(64),
              height: Responsive.wp(64),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF22B573), Color(0xFF15803D)],
                ),
                borderRadius: BorderRadius.circular(Responsive.wp(16)),
              ),
              child: Icon(
                Icons.auto_awesome,
                size: Responsive.sp(32),
                color: Colors.white,
              ),
            ).animate().fadeIn().scale(begin: Offset(0.8, 0.8)),
            SizedBox(height: Responsive.wp(20)),
            Text(
              widget.anchoredNoteId != null
                  ? 'Ask about this snap'
                  : 'Ask SnapBot',
              style: GoogleFonts.spaceGrotesk(
                fontSize: Responsive.sp(24),
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ).animate().fadeIn(delay: 100.ms),
            SizedBox(height: Responsive.wp(6)),
            Text(
              widget.anchoredNoteId != null
                  ? 'Answers come only from this one document.'
                  : 'I can search through your saved notes\nand answer questions about them.',
              style: GoogleFonts.inter(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
                fontSize: Responsive.sp(14),
              ),
              textAlign: TextAlign.center,
            ).animate().fadeIn(delay: 200.ms),
            SizedBox(height: Responsive.wp(24)),
            // Tips section
            Container(
              constraints: BoxConstraints(maxWidth: Responsive.wp(400)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb_outline,
                          size: Responsive.sp(14),
                          color: theme.colorScheme.onSurface.withOpacity(0.5)),
                      SizedBox(width: Responsive.wp(6)),
                      Text(
                        'Tips',
                        style: GoogleFonts.inter(
                          fontSize: Responsive.sp(13),
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: Responsive.wp(8)),
                  if (widget.anchoredNoteId != null) ...[
                    _buildTipCard(
                        '📝', 'Summarize', 'Try: "Summarize this document"'),
                    SizedBox(height: Responsive.wp(5)),
                    _buildTipCard(
                        '🔑', 'Key points', 'Try: "What are the key points?"'),
                    SizedBox(height: Responsive.wp(5)),
                    _buildTipCard('❓', 'Ask anything',
                        'Ask any question grounded in this snap only'),
                  ] else ...[
                    _buildTipCard('🔍', 'Search',
                        'Ask natural questions like "Show me my github invoice"'),
                    SizedBox(height: Responsive.wp(5)),
                    _buildTipCard('🏷️', 'Filter by tag',
                        'Use tag filters to narrow results to a specific category'),
                    SizedBox(height: Responsive.wp(5)),
                    _buildTipCard('🔎', 'Search Deeper',
                        'Click "Search Deeper" below results to find more matching documents'),
                  ],
                ],
              ),
            ).animate().fadeIn(delay: 300.ms),
          ],
        ),
      ),
    );
  }

  Widget _buildTipCard(String emoji, String title, String description) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(10), vertical: Responsive.pp(8)),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1F2937)
            : AppColors.primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(Responsive.wp(8)),
        border: Border.all(
          color: isDark
              ? const Color(0xFF374151)
              : AppColors.primary.withOpacity(0.15),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: TextStyle(fontSize: Responsive.sp(14))),
          SizedBox(width: Responsive.wp(8)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(12),
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: Responsive.wp(2)),
                Text(
                  description,
                  style: GoogleFonts.inter(
                    fontSize: Responsive.sp(11),
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionChip(String text) {
    return ActionChip(
      label: Text(text, style: GoogleFonts.inter(fontSize: Responsive.sp(12))),
      onPressed: () {
        _controller.text = text;
        _sendMessage();
      },
      backgroundColor: AppColors.primary.withOpacity(0.1),
      side: BorderSide(color: AppColors.primary.withOpacity(0.3)),
    );
  }

  Widget _buildBotMessage(ChatMessage msg, {int? delay}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasSources =
        !msg.isLoading && msg.sources != null && msg.sources!.isNotEmpty;
    Widget content;

    if (msg.isLoading) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: Responsive.wp(16),
            height: Responsive.wp(16),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
          SizedBox(width: Responsive.wp(12)),
          Flexible(
            child: Text(
              'Searching... Hang in there....',
              style: GoogleFonts.inter(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
                fontSize: Responsive.sp(13),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasSources)
            _buildAuroraHero(msg, theme, isDark)
          else
            MarkdownBody(
              data: msg.content,
              selectable: true,
              styleSheet: _botMarkdownSheet(theme),
              onTapLink: (text, href, title) {
                if (href != null) {
                  launchUrl(Uri.parse(href),
                      mode: LaunchMode.externalApplication);
                }
              },
            ),
          if (hasSources) ...[
            SizedBox(height: Responsive.wp(10)),
            _buildSourcesSection(msg.sources!,
                searchDeeper: msg.searchDeeper,
                resultPagination: msg.resultPagination,
                message: msg,
                animate: delay != null),
          ],
          if (msg.error != null) ...[
            SizedBox(height: Responsive.wp(8)),
            if (msg.error == 'quota_limit')
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => context.go('/settings'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    padding: EdgeInsets.symmetric(
                      horizontal: Responsive.pp(10),
                      vertical: Responsive.pp(6),
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    Icons.person_outline_rounded,
                    size: Responsive.sp(16),
                  ),
                  label: Text(
                    'Open Profile',
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(12),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )
            else
              Text(
                msg.error!,
                style: GoogleFonts.inter(
                    color: Colors.red.shade400, fontSize: Responsive.sp(11)),
              ),
          ],
        ],
      );
    }

    final widget = Padding(
      padding: EdgeInsets.only(
          bottom: Responsive.pp(12),
          right: MediaQuery.of(context).size.width * 0.08),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: Responsive.wp(26),
            height: Responsive.wp(26),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(Responsive.wp(6)),
            ),
            child: Icon(Icons.auto_awesome,
                size: Responsive.sp(13), color: Colors.white),
          ),
          SizedBox(width: Responsive.wp(6)),
          Expanded(
            child: hasSources
                ? content
                : Container(
                    padding: EdgeInsets.all(Responsive.pp(12)),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.only(
                        topRight: Radius.circular(Responsive.wp(16)),
                        bottomLeft: Radius.circular(Responsive.wp(16)),
                        bottomRight: Radius.circular(Responsive.wp(16)),
                      ),
                      border: Border.all(
                          color: isDark
                              ? const Color(0xFF374151)
                              : AppColors.borderLight),
                    ),
                    child: content,
                  ),
          ),
        ],
      ),
    );

    return delay != null
        ? widget.animate().fadeIn(delay: delay.ms).slideY(begin: 0.1)
        : widget;
  }

  /// Extracts the set of `[N]` citation numbers that appear in a planner
  /// answer body (`"foo [3] bar [7]"` → `{3, 7}`). Used to decide which
  /// carousel cards should show their numbered badge — one citation
  /// concept instead of two.
  Set<int> _extractCitedNumbers(String content) {
    if (content.isEmpty) return const <int>{};
    return RegExp(r'\[(\d+)\]')
        .allMatches(content)
        .map((m) => int.tryParse(m.group(1)!))
        .whereType<int>()
        .toSet();
  }

  Widget _buildSourcesSection(List<SearchResult> sources,
      {SearchDeeper? searchDeeper,
      ResultPagination? resultPagination,
      ChatMessage? message,
      bool animate = false}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final canSearchDeeper = searchDeeper?.available ?? false;
    // Perplexity-style: one numbered horizontal carousel of ALL sources
    // (first-page results + paginated pool), so citation chips inside the
    // answer resolve 1:1 to positions in this list.
    final extraSources = resultPagination?.remainingSources ?? const [];
    final all = <SearchResult>[...sources, ...extraSources];
    final total = all.length;

    final ctrl =
        message != null ? _carouselCtrlFor(message) : ScrollController();

    // F3: derive the set of card numbers the answer text actually cites
    // ("[3]", "[7]" → {3, 7}). Only cards in this set get the numbered
    // badge overlay on the carousel — one visual "citation" concept
    // instead of two. When the answer has no [N] tokens at all (e.g. a
    // list_notes warm summary), the set is empty and no badges show.
    final citedNumbers = _extractCitedNumbers(message?.content ?? '');

    Widget card(int i) {
      final c = _buildCarouselCard(all[i], i, theme, isDark, citedNumbers);
      return animate
          ? c.animate().fadeIn(delay: (150 + i * 40).ms).slideY(begin: 0.08)
          : c;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('Sources', '$total', theme),
        SizedBox(height: Responsive.wp(6)),
        SizedBox(
          height: Responsive.wp(230),
          child: ListView.separated(
            controller: ctrl,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: Responsive.wp(1)),
            itemCount: all.length,
            separatorBuilder: (_, __) => SizedBox(width: Responsive.wp(8)),
            itemBuilder: (context, i) => card(i),
          ),
        ),
        if (canSearchDeeper && message != null) ...[
          SizedBox(height: Responsive.wp(10)),
          _buildSearchDeeperButton(message),
        ],
      ],
    );
  }

  /// Renders the aurora-hero answer body. If the answer contains `[N]`
  /// citation markers (backend planner style), parses them into tap-able
  /// chips that scroll the source carousel. Otherwise falls back to full
  /// MarkdownBody for rich formatting.
  Widget _buildAnswerBody({
    required String content,
    required List<SearchResult> sources,
    required ScrollController carouselCtrl,
    required ThemeData theme,
    required bool isDark,
    required double cardStrideWp,
  }) {
    final hasCitations = RegExp(r'\[\d+\]').hasMatch(content);
    if (!hasCitations) {
      return MarkdownBody(
        data: content,
        selectable: true,
        styleSheet: _botMarkdownSheet(theme).copyWith(
          strong: GoogleFonts.inter(
            color: isDark
                ? const Color(0xFFC4B5FD)
                : const Color(0xFF6D28D9),
            fontWeight: FontWeight.w700,
            fontSize: Responsive.sp(13),
          ),
        ),
        onTapLink: (text, href, title) {
          if (href != null) {
            launchUrl(Uri.parse(href),
                mode: LaunchMode.externalApplication);
          }
        },
      );
    }

    final baseStyle = GoogleFonts.inter(
      fontSize: Responsive.sp(13),
      height: 1.55,
      color: theme.textTheme.bodyMedium?.color,
    );
    final boldStyle = GoogleFonts.inter(
      fontSize: Responsive.sp(13),
      height: 1.55,
      fontWeight: FontWeight.w700,
      color: isDark ? const Color(0xFFC4B5FD) : const Color(0xFF6D28D9),
    );

    // Matches **bold** or [N] tokens.
    final re = RegExp(r'\*\*([^*]+)\*\*|\[(\d+)\]');
    final spans = <InlineSpan>[];
    int last = 0;
    final matches = re.allMatches(content).toList();
    // De-dupe repeated citations to avoid visual noise: "[1] [1]" -> "[1]".
    int? prevCite;
    for (final m in matches) {
      if (m.start > last) {
        spans.add(TextSpan(
          text: content.substring(last, m.start),
          style: baseStyle,
        ));
        prevCite = null;
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(text: m.group(1), style: boldStyle));
        prevCite = null;
      } else {
        final n = int.tryParse(m.group(2)!);
        // Find the carousel position of the card whose citationIndex == n,
        // falling back to the raw (n-1) offset when the backend didn't
        // stamp indices (e.g. list_notes fallback path).
        int targetPos = -1;
        if (n != null && n >= 1) {
          for (var i = 0; i < sources.length; i++) {
            if (sources[i].citationIndex == n) {
              targetPos = i;
              break;
            }
          }
          if (targetPos < 0 && n <= sources.length) targetPos = n - 1;
        }
        if (n == null || targetPos < 0) {
          spans.add(TextSpan(text: m.group(0), style: baseStyle));
          prevCite = null;
        } else if (n == prevCite) {
          // skip duplicate citation
        } else {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _buildCitationChip(
              n,
              isDark,
              () {
                HapticFeedback.selectionClick();
                if (!carouselCtrl.hasClients) return;
                final target = targetPos * Responsive.wp(cardStrideWp);
                final max = carouselCtrl.position.maxScrollExtent;
                carouselCtrl.animateTo(
                  target > max ? max : target,
                  duration: const Duration(milliseconds: 340),
                  curve: Curves.easeOutCubic,
                );
              },
            ),
          ));
          prevCite = n;
        }
      }
      last = m.end;
    }
    if (last < content.length) {
      spans.add(TextSpan(text: content.substring(last), style: baseStyle));
    }

    return SelectableText.rich(
      TextSpan(children: spans, style: baseStyle),
    );
  }

  Widget _buildCitationChip(int n, bool isDark, VoidCallback onTap) {
    final bg = const Color(0xFF06B6D4).withOpacity(isDark ? 0.24 : 0.14);
    final border = const Color(0xFF06B6D4).withOpacity(isDark ? 0.55 : 0.45);
    final fg =
        isDark ? const Color(0xFF67E8F9) : const Color(0xFF0E7490);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Responsive.wp(1.5)),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Responsive.wp(6)),
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: Responsive.wp(5), vertical: Responsive.wp(0.5)),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border, width: 0.8),
              borderRadius: BorderRadius.circular(Responsive.wp(6)),
            ),
            child: Text(
              '$n',
              style: GoogleFonts.inter(
                fontSize: Responsive.sp(10),
                fontWeight: FontWeight.w700,
                color: fg,
                height: 1.1,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Perplexity-style numbered source card. Vertical layout: numbered badge
  /// overlaid on a gradient thumb, then title (2 lines), snippet (2 lines),
  /// source pill. Wider content area than the old mini card so users get
  /// enough context without opening the note.
  ///
  /// The numbered badge is only rendered when [citedNumbers] contains this
  /// card's `citationIndex` — i.e. the planner actually cited it inline as
  /// `[N]`. Cards that weren't cited still render (they are still part of
  /// the source set) but without the number chip. This keeps the two
  /// "citation" notions in sync: the number on the card == the `[N]` the
  /// user tapped in prose.
  Widget _buildCarouselCard(
      SearchResult s, int index, ThemeData theme, bool isDark,
      Set<int> citedNumbers) {
    final gradient = _thumbGradients[index % _thumbGradients.length];
    final snippet = _snippetFor(s);
    final label = _sourceLabel(s);
    final badgeNumber = s.citationIndex ?? (index + 1);
    final showBadge = citedNumbers.contains(badgeNumber);
    return _PressableCard(
      onTap: () => _openSourceDocument(s),
      borderRadius: BorderRadius.circular(Responsive.wp(14)),
      child: Container(
        width: Responsive.wp(148),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF1F1A2E).withOpacity(0.85)
              : Colors.white.withOpacity(0.92),
          borderRadius: BorderRadius.circular(Responsive.wp(14)),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.08)
                : const Color(0xFF8B5CF6).withOpacity(0.10),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.30 : 0.05),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Gradient thumb + numbered badge
            Stack(
              children: [
                Container(
                  height: Responsive.wp(78),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: gradient,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      _iconForResult(s),
                      size: Responsive.wp(30),
                      color: Colors.white.withOpacity(0.92),
                    ),
                  ),
                ),
                Positioned(
                  top: Responsive.wp(6),
                  left: Responsive.wp(6),
                  child: showBadge
                      ? Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: Responsive.wp(6),
                              vertical: Responsive.wp(1.5)),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius:
                                BorderRadius.circular(Responsive.wp(6)),
                          ),
                          child: Text(
                            '$badgeNumber',
                            style: GoogleFonts.inter(
                              fontSize: Responsive.sp(11),
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF67E8F9),
                              height: 1.0,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            // Text block
            Padding(
              padding: EdgeInsets.fromLTRB(Responsive.wp(9),
                  Responsive.wp(9), Responsive.wp(9), Responsive.wp(9)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: Responsive.sp(12.5),
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                  ),
                  if (snippet != null && snippet.isNotEmpty) ...[
                    SizedBox(height: Responsive.wp(5)),
                    Text(
                      snippet,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(10.5),
                        height: 1.35,
                        color: theme.textTheme.bodyMedium?.color
                            ?.withOpacity(0.75),
                      ),
                    ),
                  ],
                  SizedBox(height: Responsive.wp(7)),
                  Row(
                    children: [
                      _miniTag(label, isDark: isDark, cyan: true),
                      const Spacer(),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: Responsive.wp(12),
                        color: theme.textTheme.bodyMedium?.color
                            ?.withOpacity(0.45),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the "Search Deeper" button for loading additional results
  Widget _buildSearchDeeperButton(ChatMessage message) {
    return InkWell(
      onTap: _isLoadingMore ? null : () => _loadMoreResults(message),
      borderRadius: BorderRadius.circular(Responsive.wp(12)),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: Responsive.pp(10)),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF8B5CF6), Color(0xFF06B6D4)],
          ),
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF8B5CF6).withOpacity(0.30),
              blurRadius: Responsive.wp(10),
              offset: Offset(0, Responsive.wp(3)),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isLoadingMore) ...[
              SizedBox(
                width: Responsive.wp(14),
                height: Responsive.wp(14),
                child: const CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: Responsive.wp(8)),
              Text(
                'Loading...',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(12),
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ] else ...[
              Icon(Icons.travel_explore_rounded,
                  size: Responsive.sp(14), color: Colors.white),
              SizedBox(width: Responsive.wp(6)),
              Text(
                'Search Deeper',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(12),
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Shared markdown style for bot answers.
  MarkdownStyleSheet _botMarkdownSheet(ThemeData theme) {
    return MarkdownStyleSheet(
      p: GoogleFonts.inter(
          color: theme.colorScheme.onSurface,
          height: 1.5,
          fontSize: Responsive.sp(13)),
      strong: GoogleFonts.inter(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: Responsive.sp(13)),
      em: GoogleFonts.inter(
          color: theme.colorScheme.onSurface,
          fontStyle: FontStyle.italic,
          fontSize: Responsive.sp(13)),
      listBullet: GoogleFonts.inter(
          color: theme.colorScheme.onSurface,
          height: 1.5,
          fontSize: Responsive.sp(13)),
      a: GoogleFonts.inter(
          color: AppColors.primary,
          decoration: TextDecoration.underline,
          fontSize: Responsive.sp(13)),
      h3: GoogleFonts.inter(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: Responsive.sp(15)),
      h4: GoogleFonts.inter(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: Responsive.sp(14)),
    );
  }

  /// Aurora hero card: gradient border + soft tinted background wrapping the
  /// answer, with a "Key takeaway" eyebrow and meta pills.
  Widget _buildAuroraHero(ChatMessage msg, ThemeData theme, bool isDark) {
    final sources = msg.sources ?? const <SearchResult>[];
    final total =
        sources.length + (msg.resultPagination?.remainingSources.length ?? 0);
    final tags = <String>[];
    for (final s in sources) {
      final t = s.tag?.trim();
      if (t != null && t.isNotEmpty && !tags.contains(t)) tags.add(t);
      if (tags.length >= 2) break;
    }

    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Responsive.wp(20)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF8B5CF6).withOpacity(0.55),
            const Color(0xFF06B6D4).withOpacity(0.40),
            const Color(0xFFFB923C).withOpacity(0.35),
          ],
        ),
      ),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(Responsive.pp(14)),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Responsive.wp(19)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [
                    Color(0xFF251C40),
                    Color(0xFF152438),
                    Color(0xFF2A2030),
                  ]
                : const [
                    Color(0xFFF7F2FF),
                    Color(0xFFEDFAFF),
                    Color(0xFFFFF4EC),
                  ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(10), vertical: Responsive.pp(4)),
              decoration: BoxDecoration(
                color:
                    const Color(0xFF8B5CF6).withOpacity(isDark ? 0.22 : 0.10),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '✨ KEY TAKEAWAY',
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(9.5),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: isDark
                      ? const Color(0xFFC4B5FD)
                      : const Color(0xFF7C3AED),
                ),
              ),
            ),
            SizedBox(height: Responsive.wp(9)),
            _buildAnswerBody(
              content: msg.content,
              sources: sources,
              carouselCtrl: _carouselCtrlFor(msg),
              theme: theme,
              isDark: isDark,
              cardStrideWp: 156.0, // carousel card width (148) + separator (8)
            ),
            SizedBox(height: Responsive.wp(10)),
            Wrap(
              spacing: Responsive.wp(6),
              runSpacing: Responsive.wp(6),
              children: [
                _metaPill(
                  '● $total strong match${total == 1 ? '' : 'es'}',
                  isDark: isDark,
                  highlight: true,
                ),
                for (final t in tags) _metaPill('🏷 $t', isDark: isDark),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaPill(String text, {required bool isDark, bool highlight = false}) {
    final bg = highlight
        ? (isDark
            ? const Color(0xFF10B981).withOpacity(0.14)
            : const Color(0xFFECFDF5))
        : (isDark
            ? const Color(0xFF334155).withOpacity(0.7)
            : const Color(0xFFF1F5F9));
    final border = highlight
        ? (isDark
            ? const Color(0xFF10B981).withOpacity(0.3)
            : const Color(0xFFA7F3D0))
        : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0));
    final fg = highlight
        ? (isDark ? const Color(0xFF34D399) : const Color(0xFF047857))
        : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569));
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(9), vertical: Responsive.pp(4)),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: Responsive.sp(10),
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  Widget _sectionLabel(String left, String right, ThemeData theme) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Responsive.pp(2)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            left.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(10),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
          ),
          Text(
            right,
            style: GoogleFonts.inter(
              fontSize: Responsive.sp(10),
              fontWeight: FontWeight.w700,
              color: const Color(0xFF8B5CF6),
            ),
          ),
        ],
      ),
    );
  }

  static const List<List<Color>> _thumbGradients = [
    [Color(0xFFF97316), Color(0xFFFBBF24)],
    [Color(0xFF8B5CF6), Color(0xFFEC4899)],
    [Color(0xFF06B6D4), Color(0xFF3B82F6)],
    [Color(0xFF22B573), Color(0xFF84CC16)],
  ];

  /// Human-friendly source label for a result (Instagram, YouTube, PDF…).
  String _sourceLabel(SearchResult s) {
    // Prefer exact file_type / social_source first so Instagram posts
    // (not just reels), LinkedIn posts, etc. never fall through to "Snap".
    switch ((s.fileType ?? '').toLowerCase()) {
      case 'instagram':
        return 'Instagram';
      case 'youtube':
        return 'YouTube';
      case 'linkedin':
        return 'LinkedIn';
      case 'twitter':
      case 'x':
        return 'X';
      case 'reddit':
        return 'Reddit';
      case 'facebook':
        return 'Facebook';
      case 'quick_note':
        return 'Note';
      case 'screenshot':
        return 'Screenshot';
      case 'image':
        return 'Image';
      case 'webpage':
        return 'Webpage';
      case 'pdf':
        return 'PDF';
    }
    switch ((s.socialSource ?? '').toLowerCase()) {
      case 'instagram':
        return 'Instagram';
      case 'youtube':
        return 'YouTube';
      case 'linkedin':
        return 'LinkedIn';
      case 'twitter':
      case 'x':
        return 'X';
      case 'reddit':
        return 'Reddit';
      case 'facebook':
        return 'Facebook';
    }
    final name = (s.originalFilename ?? '').toLowerCase();
    final combined =
        '$name ${s.title.toLowerCase()} ${(s.viewUrl ?? '').toLowerCase()} '
        '${(s.sourceUrl ?? '').toLowerCase()}';
    if (combined.contains('instagram') || combined.contains('reel')) {
      return 'Instagram';
    }
    if (combined.contains('facebook') || combined.contains('fb.watch')) {
      return 'Facebook';
    }
    if (combined.contains('youtube') ||
        combined.contains('youtu.be') ||
        combined.contains('shorts')) {
      return 'YouTube';
    }
    if (combined.contains('linkedin')) return 'LinkedIn';
    if (combined.contains('twitter') ||
        combined.contains('x.com') ||
        combined.contains('tweet')) {
      return 'X';
    }
    if (combined.contains('reddit')) return 'Reddit';
    if (name.endsWith('.pdf')) return 'PDF';
    if (name.endsWith('.xlsx') ||
        name.endsWith('.xls') ||
        name.endsWith('.csv')) {
      return 'Sheet';
    }
    if (name.endsWith('.docx') || name.endsWith('.doc')) return 'Doc';
    if (name.endsWith('.pptx') || name.endsWith('.ppt')) return 'Slides';
    if (name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.webp')) {
      return 'Image';
    }
    return 'Snap';
  }

  /// Snippet for a featured card; suppressed when the display title was
  /// already derived from the same text (avoids showing the title twice).
  String? _snippetFor(SearchResult s) {
    final raw = s.snippet ?? s.description;
    if (raw == null) return null;
    final cleaned = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return null;
    final head = cleaned
        .substring(0, cleaned.length < 40 ? cleaned.length : 40)
        .toLowerCase();
    if (s.displayTitle.replaceAll('…', '').toLowerCase().contains(head)) {
      return null;
    }
    return cleaned;
  }

  Widget _miniTag(String text, {required bool isDark, bool cyan = false}) {
    final bg = cyan
        ? const Color(0xFF06B6D4).withOpacity(isDark ? 0.16 : 0.10)
        : const Color(0xFF8B5CF6).withOpacity(isDark ? 0.20 : 0.10);
    final fg = cyan
        ? (isDark ? const Color(0xFF67E8F9) : const Color(0xFF0E7490))
        : (isDark ? const Color(0xFFC4B5FD) : const Color(0xFF6D28D9));
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(7), vertical: Responsive.pp(2)),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Responsive.wp(6)),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: Responsive.sp(9.5),
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  Widget _buildFeaturedCard(
      SearchResult s, int index, ThemeData theme, bool isDark) {
    final snippet = _snippetFor(s);
    final cardColor = isDark ? const Color(0xFF1F2937) : Colors.white;
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.wp(8)),
      child: _PressableCard(
        onTap: () {
          HapticFeedback.selectionClick();
          _openSourceDocument(s);
        },
        borderRadius: BorderRadius.circular(Responsive.wp(16)),
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(Responsive.wp(16)),
            border: Border.all(
              color: isDark
                  ? const Color(0xFF8B5CF6).withOpacity(0.25)
                  : const Color(0xFFE9E4F8),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isDark ? 0.25 : 0.05),
                blurRadius: Responsive.wp(10),
                offset: Offset(0, Responsive.wp(3)),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                _openSourceDocument(s);
              },
              borderRadius: BorderRadius.circular(Responsive.wp(16)),
              splashColor: const Color(0xFF8B5CF6).withOpacity(0.14),
              highlightColor: const Color(0xFF06B6D4).withOpacity(0.06),
              child: Padding(
                padding: EdgeInsets.all(Responsive.pp(10)),
                child: Row(
                  children: [
                    Container(
                      width: Responsive.wp(52),
                      height: Responsive.wp(52),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors:
                              _thumbGradients[index % _thumbGradients.length],
                        ),
                        borderRadius: BorderRadius.circular(Responsive.wp(12)),
                      ),
                      child: Icon(
                        _iconForResult(s),
                        color: Colors.white,
                        size: Responsive.sp(22),
                      ),
                    ),
                    SizedBox(width: Responsive.wp(10)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: Responsive.sp(12.5),
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurface,
                              height: 1.25,
                            ),
                          ),
                          if (snippet != null) ...[
                            SizedBox(height: Responsive.wp(2)),
                            Text(
                              snippet,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: Responsive.sp(10.5),
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.6),
                                height: 1.35,
                              ),
                            ),
                          ],
                          SizedBox(height: Responsive.wp(5)),
                          Row(
                            children: [
                              if (s.tag != null &&
                                  s.tag!.trim().isNotEmpty) ...[
                                _miniTag(s.tag!.trim(), isDark: isDark),
                                SizedBox(width: Responsive.wp(5)),
                              ],
                              _miniTag(_sourceLabel(s),
                                  isDark: isDark, cyan: true),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: theme.colorScheme.onSurface.withOpacity(0.3),
                      size: Responsive.sp(18),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniCard(
      SearchResult s, int index, ThemeData theme, bool isDark) {
    final cardColor = isDark ? const Color(0xFF1F2937) : Colors.white;
    final gradient = _thumbGradients[index % _thumbGradients.length];
    return _PressableCard(
      onTap: () {
        HapticFeedback.selectionClick();
        _openSourceDocument(s);
      },
      borderRadius: BorderRadius.circular(Responsive.wp(14)),
      scale: 0.96,
      child: Container(
        width: Responsive.wp(148),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(Responsive.wp(14)),
          border: Border.all(
            color: isDark
                ? gradient.first.withOpacity(0.28)
                : gradient.first.withOpacity(0.18),
          ),
          boxShadow: [
            BoxShadow(
              color: gradient.first.withOpacity(isDark ? 0.18 : 0.10),
              blurRadius: Responsive.wp(8),
              offset: Offset(0, Responsive.wp(2)),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              _openSourceDocument(s);
            },
            borderRadius: BorderRadius.circular(Responsive.wp(14)),
            splashColor: gradient.first.withOpacity(0.14),
            highlightColor: gradient.last.withOpacity(0.06),
            child: Padding(
              padding: EdgeInsets.all(Responsive.pp(10)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: Responsive.wp(30),
                    height: Responsive.wp(30),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: gradient,
                      ),
                      borderRadius: BorderRadius.circular(Responsive.wp(9)),
                    ),
                    child: Icon(
                      _iconForResult(s),
                      size: Responsive.sp(15),
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: Responsive.wp(6)),
                  Expanded(
                    child: Text(
                      s.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: Responsive.sp(11),
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                        height: 1.3,
                      ),
                    ),
                  ),
                  SizedBox(height: Responsive.wp(4)),
                  Row(
                    children: [
                      Flexible(
                        child: _miniTag(_sourceLabel(s),
                            isDark: isDark, cyan: true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the tapped source card in the platform's native handler for
  /// its content type (browser, YouTube app, Instagram app, PDF viewer,
  /// etc.). We use the note's `view_url` when present and fall back to
  /// asking the API for one. Only when we truly have nothing to launch
  /// do we push into the in-app detail screen.
  ///
  /// Rationale for going back to external-app open: the tapped card is a
  /// _source_ the user saved from somewhere else. Opening in-app dumped
  /// them on a bare gradient header for notes not currently loaded in
  /// `notesProvider`, and blob-backed notes rendered as raw `.bin`
  /// downloads because the detail screen streams `blob_url` directly.
  Future<void> _openSourceDocument(SearchResult source) async {
    HapticFeedback.mediumImpact();
    // Prefer the view URL surfaced by the search worker.
    if (source.viewUrl != null && source.viewUrl!.isNotEmpty) {
      await launchUrl(Uri.parse(source.viewUrl!),
          mode: LaunchMode.externalApplication);
      return;
    }
    // Fallback 1: ask the API for a fresh view URL.
    try {
      final fetchedUrl = await ApiService().getViewUrl(source.noteId);
      if (fetchedUrl != null && fetchedUrl.isNotEmpty) {
        await launchUrl(Uri.parse(fetchedUrl),
            mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {}
    // Fallback 2: in-app note detail (only if no external URL exists,
    // e.g. quick_notes that have no source_url).
    if (mounted) context.push('/notes/${source.noteId}');
  }

  IconData _getIconForType(String? fileType) {
    switch (fileType) {
      case 'quick_note':
        return Icons.notes_outlined;
      case 'screenshot':
        return Icons.image_outlined;
      case 'webpage':
        return Icons.language;
      case 'facebook':
        return Icons.facebook_rounded;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  /// Resolve the chip icon by combining file_type + the original filename
  /// extension (so excel/word/ppt/csv/etc. show the right glyph rather than
  /// the generic txt-style `description_outlined`).
  IconData _iconForResult(SearchResult s) {
    // Prefer exact file_type match — Instagram posts (not just reels),
    // LinkedIn posts, tweets, etc. all get their brand icon reliably even
    // when title/url don't contain the platform name.
    switch ((s.fileType ?? '').toLowerCase()) {
      case 'instagram':
        return Icons.photo_camera_outlined;
      case 'youtube':
        return Icons.smart_display_outlined;
      case 'linkedin':
        return Icons.business_center_outlined;
      case 'twitter':
      case 'x':
        return Icons.alternate_email_rounded;
      case 'reddit':
        return Icons.forum_outlined;
      case 'facebook':
        return Icons.facebook_rounded;
      case 'quick_note':
        return Icons.sticky_note_2_outlined;
      case 'screenshot':
      case 'image':
        return Icons.image_outlined;
      case 'webpage':
        return Icons.language;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
    }

    // Same for the enriched social_source hint pulled from metadata.
    switch ((s.socialSource ?? '').toLowerCase()) {
      case 'instagram':
        return Icons.photo_camera_outlined;
      case 'youtube':
        return Icons.smart_display_outlined;
      case 'linkedin':
        return Icons.business_center_outlined;
      case 'twitter':
      case 'x':
        return Icons.alternate_email_rounded;
      case 'reddit':
        return Icons.forum_outlined;
      case 'facebook':
        return Icons.facebook_rounded;
    }

    // Loose text-match fallback for older notes that predate the file_type
    // column (or where enrichment failed).
    final name = (s.originalFilename ?? '').toLowerCase();
    final title = s.title.toLowerCase();
    final url = (s.viewUrl ?? '').toLowerCase();
    final sourceUrl = (s.sourceUrl ?? '').toLowerCase();
    final combined = '$name $title $url $sourceUrl';

    if (combined.contains('instagram.com') ||
        combined.contains('instagram') ||
        combined.contains('reel')) {
      return Icons.photo_camera_outlined;
    }
    if (combined.contains('facebook.com') ||
        combined.contains('fb.watch') ||
        combined.contains('facebook')) {
      return Icons.facebook_rounded;
    }
    if (combined.contains('youtube.com') ||
        combined.contains('youtu.be') ||
        combined.contains('youtube') ||
        combined.contains('shorts')) {
      return Icons.smart_display_outlined;
    }
    if (combined.contains('linkedin.com') || combined.contains('linkedin')) {
      return Icons.business_center_outlined;
    }
    if (combined.contains('twitter.com') ||
        combined.contains('x.com') ||
        combined.contains('tweet')) {
      return Icons.alternate_email_rounded;
    }
    if (combined.contains('reddit.com') || combined.contains('reddit')) {
      return Icons.forum_outlined;
    }
    if (name.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (name.endsWith('.xlsx') || name.endsWith('.xls'))
      return Icons.table_chart_outlined;
    if (name.endsWith('.csv')) return Icons.grid_on_outlined;
    if (name.endsWith('.docx') || name.endsWith('.doc'))
      return Icons.article_outlined;
    if (name.endsWith('.pptx') || name.endsWith('.ppt'))
      return Icons.slideshow_outlined;
    if (name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (name.endsWith('.md') || name.endsWith('.markdown'))
      return Icons.notes_outlined;
    if (name.endsWith('.txt')) return Icons.description_outlined;
    if (name.endsWith('.html') || name.endsWith('.htm')) return Icons.language;
    // Fall back to the existing file_type mapping
    return _getIconForType(s.fileType);
  }

  Widget _buildUserMessage(String text, {int? delay}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final widget = Padding(
      padding: EdgeInsets.only(
          bottom: Responsive.pp(12),
          left: MediaQuery.of(context).size.width * 0.08),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              padding: EdgeInsets.all(Responsive.pp(12)),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF7C3AED),
                    Color(0xFF8B5CF6),
                    Color(0xFF06B6D4),
                  ],
                ),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(Responsive.wp(18)),
                  bottomLeft: Radius.circular(Responsive.wp(18)),
                  topRight: Radius.circular(Responsive.wp(18)),
                  bottomRight: Radius.circular(Responsive.wp(4)),
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF8B5CF6)
                        .withOpacity(isDark ? 0.45 : 0.28),
                    blurRadius: Responsive.wp(14),
                    offset: Offset(0, Responsive.wp(4)),
                  ),
                ],
              ),
              child: Text(
                text,
                style: GoogleFonts.inter(
                    color: Colors.white,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    fontSize: Responsive.sp(13)),
              ),
            ),
          ),
          SizedBox(width: Responsive.wp(8)),
          _buildUserAvatar(isDark),
        ],
      ),
    );

    return delay != null
        ? widget.animate().fadeIn(delay: delay.ms).slideY(begin: 0.1)
        : widget;
  }

  /// Circular avatar shown next to a user message bubble. Mirrors the
  /// square avatar on the home screen — network image when photoUrl is
  /// available, otherwise the user's initial on a slate gradient.
  Widget _buildUserAvatar(bool isDark) {
    final user = ref.watch(authUserProvider);
    final photoUrl = user?.photoUrl;
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
    final initial = (user?.displayName?.trim().isNotEmpty ?? false)
        ? user!.displayName!.trim()[0].toUpperCase()
        : (user?.email?.trim().isNotEmpty ?? false)
            ? user!.email!.trim()[0].toUpperCase()
            : '?';
    return Container(
      width: Responsive.wp(28),
      height: Responsive.wp(28),
      decoration: BoxDecoration(
        gradient: hasPhoto
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? const [Color(0xFF475569), Color(0xFF334155)]
                    : const [Color(0xFF334155), Color(0xFF0F172A)],
              ),
        borderRadius: BorderRadius.circular(Responsive.wp(8)),
        image: hasPhoto
            ? DecorationImage(
                image: NetworkImage(photoUrl),
                fit: BoxFit.cover,
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: Responsive.wp(4),
            offset: Offset(0, Responsive.wp(2)),
          ),
        ],
      ),
      child: hasPhoto
          ? null
          : Center(
              child: Text(
                initial,
                style: GoogleFonts.inter(
                  fontSize: Responsive.sp(12),
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
    );
  }

  Widget _buildTagChips() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_tagsLoading) {
      return Container(
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(16), vertical: Responsive.pp(6)),
        child: Row(
          children: [
            SizedBox(
              width: Responsive.wp(14),
              height: Responsive.wp(14),
              child: CircularProgressIndicator(
                strokeWidth: Responsive.wp(2),
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            SizedBox(width: Responsive.wp(8)),
            Text(
              'Loading tags...',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
                fontSize: Responsive.sp(11),
              ),
            ),
          ],
        ),
      );
    }

    if (_availableTags.isEmpty) {
      return const SizedBox.shrink();
    }

    // Sort tags: selected first, then alphabetically
    final sortedTags = [..._availableTags]..sort((a, b) {
        final aSelected = _selectedTags.contains(a);
        final bSelected = _selectedTags.contains(b);
        if (aSelected && !bSelected) return -1;
        if (!aSelected && bSelected) return 1;
        return a.compareTo(b);
      });

    // Single horizontally-scrollable line — show every tag inline.
    final visibleTags = sortedTags;
    final overflowTags = const <String>[];
    final hasOverflow = false;

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(16), vertical: Responsive.pp(6)),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
            top: BorderSide(
                color:
                    isDark ? const Color(0xFF374151) : AppColors.borderLight)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Filter label (fixed on the left)
          Text(
            'Filter by Tag:',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              fontSize: Responsive.sp(11),
              fontWeight: FontWeight.w500,
            ),
          ),
          if (_selectedTags.isNotEmpty) ...[
            SizedBox(width: Responsive.wp(6)),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Responsive.pp(6), vertical: Responsive.pp(2)),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(Responsive.wp(8)),
              ),
              child: Text(
                '${_selectedTags.length} selected',
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: Responsive.sp(10),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          SizedBox(width: Responsive.wp(8)),
          // Horizontally-scrollable chips fill the rest of the row.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _buildTagChip(null, 'All', isDark, theme),
                  SizedBox(width: Responsive.wp(6)),
                  for (int i = 0; i < visibleTags.length; i++) ...[
                    _buildTagChip(
                        visibleTags[i], visibleTags[i], isDark, theme),
                    if (i != visibleTags.length - 1 || hasOverflow)
                      SizedBox(width: Responsive.wp(6)),
                  ],
                  if (hasOverflow)
                    _buildOverflowButton(overflowTags, isDark, theme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverflowButton(
      List<String> overflowTags, bool isDark, ThemeData theme) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _showOverflowDialog(overflowTags, isDark, theme);
      },
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(10), vertical: Responsive.pp(4)),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1F2937) : AppColors.lightBackground,
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          border: Border.all(
            color: AppColors.primary.withOpacity(0.5),
          ),
        ),
        child: Text(
          '+${overflowTags.length}',
          style: TextStyle(
            color: AppColors.primary,
            fontSize: Responsive.sp(11),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  void _showOverflowDialog(
      List<String> overflowTags, bool isDark, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(Responsive.wp(16))),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: Padding(
            padding: EdgeInsets.all(Responsive.pp(16)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'More tags',
                      style: TextStyle(
                        fontSize: Responsive.sp(16),
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() => _selectedTags.clear());
                        setModalState(() {});
                      },
                      child: Text(
                        'Clear all',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: Responsive.sp(13),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: Responsive.wp(12)),
                Flexible(
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: Responsive.wp(8),
                      runSpacing: Responsive.wp(8),
                      children: overflowTags.map((tag) {
                        final isSelected = _selectedTags.contains(tag);
                        return GestureDetector(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            setState(() {
                              if (isSelected) {
                                _selectedTags.remove(tag);
                              } else {
                                _selectedTags.add(tag);
                              }
                            });
                            setModalState(() {});
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: EdgeInsets.symmetric(
                                horizontal: Responsive.pp(12),
                                vertical: Responsive.pp(6)),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.primary
                                  : (isDark
                                      ? const Color(0xFF1F2937)
                                      : AppColors.lightBackground),
                              borderRadius:
                                  BorderRadius.circular(Responsive.wp(14)),
                              border: Border.all(
                                color: isSelected
                                    ? AppColors.primary
                                    : (isDark
                                        ? const Color(0xFF374151)
                                        : AppColors.borderLight),
                              ),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : theme.colorScheme.onSurface
                                        .withOpacity(0.8),
                                fontSize: Responsive.sp(12),
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                SizedBox(height: Responsive.wp(16)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTagChip(
      String? tag, String label, bool isDark, ThemeData theme) {
    final isAll = tag == null;
    final isSelected =
        isAll ? _selectedTags.isEmpty : _selectedTags.contains(tag);

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() {
          if (isAll) {
            // Tapping "All" clears selection
            _selectedTags.clear();
          } else {
            // Toggle tag selection
            if (_selectedTags.contains(tag)) {
              _selectedTags.remove(tag);
            } else {
              _selectedTags.add(tag);
            }
          }
        });
      },
      onDoubleTap: () {
        // Double-tap clears all selections
        HapticFeedback.mediumImpact();
        setState(() => _selectedTags.clear());
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
            horizontal: Responsive.pp(10), vertical: Responsive.pp(4)),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary
              : (isDark ? const Color(0xFF1F2937) : AppColors.lightBackground),
          borderRadius: BorderRadius.circular(Responsive.wp(12)),
          border: Border.all(
            color: isSelected
                ? AppColors.primary
                : (isDark ? const Color(0xFF374151) : AppColors.borderLight),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? Colors.white
                : theme.colorScheme.onSurface.withOpacity(0.8),
            fontSize: Responsive.sp(11),
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Responsive.pp(12), vertical: Responsive.pp(8)),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
            top: BorderSide(
                color:
                    isDark ? const Color(0xFF374151) : AppColors.borderLight)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: Responsive.sp(14),
                ),
                decoration: InputDecoration(
                  hintText: 'What are you looking for?',
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                    fontSize: Responsive.sp(13),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Responsive.wp(20)),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: isDark
                      ? const Color(0xFF1F2937)
                      : AppColors.lightBackground,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: Responsive.pp(16),
                      vertical: Responsive.pp(10)),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(width: Responsive.wp(8)),
            SizedBox(
              width: Responsive.wp(36),
              height: Responsive.wp(36),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _isSending
                      ? theme.colorScheme.onSurface.withOpacity(0.5)
                      : AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: _isSending
                      ? SizedBox(
                          width: Responsive.wp(18),
                          height: Responsive.wp(18),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(Icons.send,
                          color: Colors.white, size: Responsive.sp(18)),
                  onPressed: _isSending ? null : _sendMessage,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wraps a card so it briefly scales down on tap-down, giving haptic-like
/// visual feedback that pairs with the InkWell ripple.
class _PressableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final BorderRadius borderRadius;
  final double scale;

  const _PressableCard({
    required this.child,
    required this.onTap,
    required this.borderRadius,
    // Default press scale bumped from 0.975 → 0.94 so the tap feedback is
    // actually noticeable on a ~148dp carousel card. The old value was
    // visually indistinguishable from no animation.
    this.scale = 0.94,
  });

  @override
  State<_PressableCard> createState() => _PressableCardState();
}

class _PressableCardState extends State<_PressableCard> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    // Combines a shrink-scale with a tint overlay so the user gets both
    // motion and colour feedback — the pure scale alone was too subtle to
    // register as "I'm being tapped" on smaller cards.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Stack(
          children: [
            widget.child,
            // Tint overlay clipped to the same rounded rect as the card.
            Positioned.fill(
              child: IgnorePointer(
                child: ClipRRect(
                  borderRadius: widget.borderRadius,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    color: _pressed
                        ? (isDark
                            ? Colors.white.withOpacity(0.08)
                            : Colors.black.withOpacity(0.06))
                        : Colors.transparent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapBotHelpImageCard extends StatelessWidget {
  final bool isDark;

  const _SnapBotHelpImageCard({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: BoxConstraints(maxWidth: Responsive.wp(290)),
        padding: EdgeInsets.all(Responsive.pp(6)),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(Responsive.wp(20)),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.14)
                : Colors.black.withOpacity(0.08),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.28 : 0.14),
              blurRadius: Responsive.wp(18),
              offset: Offset(0, Responsive.wp(8)),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Responsive.wp(15)),
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: Image.asset(
              'assets/help/snapbot_search_example.jpg',
              fit: BoxFit.cover,
            ),
          ),
        ),
      ),
    );
  }
}

class _SnapBotHelpBullet extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _SnapBotHelpBullet({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: Responsive.wp(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primary, size: Responsive.sp(18)),
          SizedBox(width: Responsive.wp(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    color: theme.colorScheme.onSurface,
                    fontSize: Responsive.sp(13),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: Responsive.wp(3)),
                Text(
                  body,
                  style: GoogleFonts.inter(
                    color: theme.colorScheme.onSurface.withOpacity(0.74),
                    fontSize: Responsive.sp(12),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
