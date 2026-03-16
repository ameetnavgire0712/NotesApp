"""
Compare naive word-based chunking vs markdown-aware semantic chunking.
Uses a real document from the notes table (RAG Chunking Methods guide).
"""
import re
import json

# ============================================================================
# Method 1: Current naive word-based chunking (what Worker does now)
# ============================================================================
CHUNK_SIZE_WORDS = 500
CHUNK_OVERLAP_WORDS = 50

def naive_chunk(text: str) -> list[str]:
    """Current Worker chunking: 500 words, 50 word overlap, split on whitespace."""
    words = text.split()
    if len(words) <= CHUNK_SIZE_WORDS:
        return [text.strip()]
    
    chunks = []
    start = 0
    while start < len(words):
        end = min(start + CHUNK_SIZE_WORDS, len(words))
        chunk = ' '.join(words[start:end])
        chunks.append(chunk)
        start = end - CHUNK_OVERLAP_WORDS
        if start >= len(words) - CHUNK_OVERLAP_WORDS:
            break
    return chunks

# ============================================================================
# Method 2: Markdown-aware semantic chunking (proposed)
# ============================================================================
MAX_CHUNK_WORDS = 400   # Leave room for heading context prefix (~450 total with context)
MIN_CHUNK_WORDS = 100   # Aggressively merge chunks smaller than this
OVERLAP_WORDS = 0       # No overlap needed since we split on semantic boundaries

def markdown_aware_chunk(text: str) -> list[str]:
    """
    Markdown-aware chunking that:
    1. Splits on heading boundaries (# ## ###)
    2. Keeps paragraphs intact when possible
    3. Prepends parent heading context to each chunk
    4. Merges tiny adjacent sections
    5. Falls back to word-based splitting for huge sections
    """
    # Step 1: Parse into sections by headings
    sections = _parse_sections(text)
    
    # Step 2: Build chunks respecting section boundaries
    chunks = []
    for section in sections:
        heading = section['heading']
        parent_heading = section.get('parent_heading', '')
        body = section['body'].strip()
        
        if not body:
            continue
        
        # Build context prefix
        context_parts = []
        if parent_heading:
            context_parts.append(parent_heading)
        if heading and heading != parent_heading:
            context_parts.append(heading)
        context_prefix = ' > '.join(context_parts)
        
        body_words = body.split()
        
        if len(body_words) <= MAX_CHUNK_WORDS:
            # Section fits in one chunk — prepend context
            if context_prefix:
                chunk_text = f"[{context_prefix}]\n{body}"
            else:
                chunk_text = body
            chunks.append(chunk_text)
        else:
            # Section too large — split by paragraphs first, then by words
            paragraphs = re.split(r'\n\s*\n', body)
            current_chunk_parts = []
            current_word_count = 0
            
            for para in paragraphs:
                para = para.strip()
                if not para:
                    continue
                para_words = len(para.split())
                
                if current_word_count + para_words <= MAX_CHUNK_WORDS:
                    current_chunk_parts.append(para)
                    current_word_count += para_words
                else:
                    # Flush current chunk
                    if current_chunk_parts:
                        chunk_body = '\n\n'.join(current_chunk_parts)
                        if context_prefix:
                            chunks.append(f"[{context_prefix}]\n{chunk_body}")
                        else:
                            chunks.append(chunk_body)
                    
                    # Handle oversized paragraph
                    if para_words > MAX_CHUNK_WORDS:
                        # Last resort: word-based split within this paragraph
                        sub_chunks = _word_split(para, MAX_CHUNK_WORDS)
                        for sc in sub_chunks:
                            if context_prefix:
                                chunks.append(f"[{context_prefix}]\n{sc}")
                            else:
                                chunks.append(sc)
                        current_chunk_parts = []
                        current_word_count = 0
                    else:
                        current_chunk_parts = [para]
                        current_word_count = para_words
            
            # Flush remaining
            if current_chunk_parts:
                chunk_body = '\n\n'.join(current_chunk_parts)
                if context_prefix:
                    chunks.append(f"[{context_prefix}]\n{chunk_body}")
                else:
                    chunks.append(chunk_body)
    
    # Step 3: Merge tiny chunks with their neighbors
    chunks = _merge_small_chunks(chunks, MIN_CHUNK_WORDS, MAX_CHUNK_WORDS)
    
    return chunks


def _parse_sections(text: str) -> list[dict]:
    """Parse markdown into sections by headings, tracking parent hierarchy."""
    lines = text.split('\n')
    sections = []
    current_section = {'heading': '', 'parent_heading': '', 'body': '', 'level': 0}
    heading_stack = []  # Stack of (level, heading_text) for hierarchy tracking
    
    for line in lines:
        heading_match = re.match(r'^(#{1,4})\s+(.+)$', line)
        if heading_match:
            # Save previous section
            if current_section['body'].strip():
                sections.append(current_section)
            
            level = len(heading_match.group(1))
            heading_text = heading_match.group(2).strip()
            
            # Update heading stack
            while heading_stack and heading_stack[-1][0] >= level:
                heading_stack.pop()
            
            parent = heading_stack[-1][1] if heading_stack else ''
            heading_stack.append((level, heading_text))
            
            current_section = {
                'heading': heading_text,
                'parent_heading': parent,
                'body': '',
                'level': level,
            }
        else:
            current_section['body'] += line + '\n'
    
    # Save last section
    if current_section['body'].strip():
        sections.append(current_section)
    
    return sections


def _word_split(text: str, max_words: int) -> list[str]:
    """Fallback word-based split for oversized paragraphs."""
    words = text.split()
    chunks = []
    for i in range(0, len(words), max_words):
        chunks.append(' '.join(words[i:i + max_words]))
    return chunks


def _merge_small_chunks(chunks: list[str], min_words: int, max_words: int) -> list[str]:
    """Merge chunks smaller than min_words with adjacent chunks. Multiple passes."""
    if not chunks:
        return chunks
    
    # Multiple passes until no more merges happen
    for _ in range(5):
        merged = []
        i = 0
        any_merged = False
        while i < len(chunks):
            current = chunks[i]
            current_words = len(current.split())
            
            # If current chunk is too small, try to merge with next
            if current_words < min_words and i + 1 < len(chunks):
                next_chunk = chunks[i + 1]
                combined_words = current_words + len(next_chunk.split())
                if combined_words <= max_words:
                    merged.append(current + '\n\n' + next_chunk)
                    i += 2
                    any_merged = True
                    continue
            
            # If current chunk is too small and there's a previous chunk, merge backward
            if current_words < min_words and merged:
                prev = merged[-1]
                combined_words = len(prev.split()) + current_words
                if combined_words <= max_words:
                    merged[-1] = prev + '\n\n' + current
                    i += 1
                    any_merged = True
                    continue
            
            merged.append(current)
            i += 1
        
        chunks = merged
        if not any_merged:
            break
    
    return chunks


# ============================================================================
# Analysis & Comparison
# ============================================================================

def analyze_chunk(chunk: str, index: int) -> dict:
    """Analyze a single chunk's properties."""
    words = chunk.split()
    sentences = re.split(r'[.!?]+', chunk)
    sentences = [s.strip() for s in sentences if s.strip()]
    
    # Check if chunk starts/ends mid-sentence
    starts_mid = not chunk[0].isupper() and not chunk.startswith('[') and not chunk.startswith('*') and not chunk.startswith('#') and not chunk.startswith('```')
    ends_mid = not chunk.rstrip().endswith(('.', '!', '?', ':', '`', '*', ')'))
    
    # Check for heading context
    has_context = chunk.startswith('[')
    
    return {
        'index': index,
        'words': len(words),
        'chars': len(chunk),
        'sentences': len(sentences),
        'starts_mid_sentence': starts_mid,
        'ends_mid_sentence': ends_mid,
        'has_heading_context': has_context,
        'first_30_chars': chunk[:80].replace('\n', '↵'),
        'last_30_chars': chunk[-60:].replace('\n', '↵'),
    }


def print_comparison(text: str):
    print("=" * 100)
    print("CHUNKING COMPARISON TEST")
    print(f"Document: {len(text)} chars, {len(text.split())} words")
    print("=" * 100)
    
    # Run both methods
    naive_chunks = naive_chunk(text)
    semantic_chunks = markdown_aware_chunk(text)
    
    # ---- Naive Summary ----
    print(f"\n{'='*50}")
    print(f"METHOD 1: NAIVE WORD-BASED (current)")
    print(f"{'='*50}")
    print(f"Chunks: {len(naive_chunks)}")
    naive_analysis = [analyze_chunk(c, i) for i, c in enumerate(naive_chunks)]
    
    mid_start = sum(1 for a in naive_analysis if a['starts_mid_sentence'])
    mid_end = sum(1 for a in naive_analysis if a['ends_mid_sentence'])
    word_counts = [a['words'] for a in naive_analysis]
    
    print(f"Word counts: min={min(word_counts)}, max={max(word_counts)}, avg={sum(word_counts)/len(word_counts):.0f}")
    print(f"Chunks starting mid-sentence: {mid_start}/{len(naive_chunks)} ({mid_start/len(naive_chunks)*100:.0f}%)")
    print(f"Chunks ending mid-sentence:   {mid_end}/{len(naive_chunks)} ({mid_end/len(naive_chunks)*100:.0f}%)")
    print(f"Chunks with heading context:  0/{len(naive_chunks)} (0%)")
    
    print(f"\n--- Naive Chunks Detail ---")
    for i, (chunk, analysis) in enumerate(zip(naive_chunks, naive_analysis)):
        print(f"\n  Chunk {i+1}: {analysis['words']} words")
        print(f"    Start: {analysis['first_30_chars']}")
        print(f"    End:   {analysis['last_30_chars']}")
        if analysis['starts_mid_sentence']:
            print(f"    ⚠️  STARTS MID-SENTENCE")
        if analysis['ends_mid_sentence']:
            print(f"    ⚠️  ENDS MID-SENTENCE")
    
    # ---- Semantic Summary ----
    print(f"\n{'='*50}")
    print(f"METHOD 2: MARKDOWN-AWARE SEMANTIC (proposed)")
    print(f"{'='*50}")
    print(f"Chunks: {len(semantic_chunks)}")
    semantic_analysis = [analyze_chunk(c, i) for i, c in enumerate(semantic_chunks)]
    
    mid_start_s = sum(1 for a in semantic_analysis if a['starts_mid_sentence'])
    mid_end_s = sum(1 for a in semantic_analysis if a['ends_mid_sentence'])
    with_context = sum(1 for a in semantic_analysis if a['has_heading_context'])
    word_counts_s = [a['words'] for a in semantic_analysis]
    
    print(f"Word counts: min={min(word_counts_s)}, max={max(word_counts_s)}, avg={sum(word_counts_s)/len(word_counts_s):.0f}")
    print(f"Chunks starting mid-sentence: {mid_start_s}/{len(semantic_chunks)} ({mid_start_s/len(semantic_chunks)*100:.0f}%)")
    print(f"Chunks ending mid-sentence:   {mid_end_s}/{len(semantic_chunks)} ({mid_end_s/len(semantic_chunks)*100:.0f}%)")
    print(f"Chunks with heading context:  {with_context}/{len(semantic_chunks)} ({with_context/len(semantic_chunks)*100:.0f}%)")
    
    print(f"\n--- Semantic Chunks Detail ---")
    for i, (chunk, analysis) in enumerate(zip(semantic_chunks, semantic_analysis)):
        print(f"\n  Chunk {i+1}: {analysis['words']} words")
        print(f"    Start: {analysis['first_30_chars']}")
        print(f"    End:   {analysis['last_30_chars']}")
        if analysis['starts_mid_sentence']:
            print(f"    ⚠️  STARTS MID-SENTENCE")
        if analysis['ends_mid_sentence']:
            print(f"    ⚠️  ENDS MID-SENTENCE")
    
    # ---- Side-by-Side Quality Comparison ----
    print(f"\n{'='*100}")
    print("QUALITY COMPARISON SUMMARY")
    print(f"{'='*100}")
    print(f"{'Metric':<40} {'Naive':>15} {'Semantic':>15} {'Winner':>15}")
    print(f"{'-'*85}")
    print(f"{'Total chunks':<40} {len(naive_chunks):>15} {len(semantic_chunks):>15} {'—':>15}")
    print(f"{'Avg words/chunk':<40} {sum(word_counts)/len(word_counts):>15.0f} {sum(word_counts_s)/len(word_counts_s):>15.0f} {'—':>15}")
    print(f"{'Min chunk words':<40} {min(word_counts):>15} {min(word_counts_s):>15} {'—':>15}")
    print(f"{'Max chunk words':<40} {max(word_counts):>15} {max(word_counts_s):>15} {'—':>15}")
    
    w1 = 'Semantic' if mid_start_s < mid_start else ('Tie' if mid_start_s == mid_start else 'Naive')
    print(f"{'Starts mid-sentence':<40} {mid_start:>15} {mid_start_s:>15} {w1:>15}")
    
    w2 = 'Semantic' if mid_end_s < mid_end else ('Tie' if mid_end_s == mid_end else 'Naive')
    print(f"{'Ends mid-sentence':<40} {mid_end:>15} {mid_end_s:>15} {w2:>15}")
    
    print(f"{'Has heading context':<40} {0:>15} {with_context:>15} {'Semantic':>15}")
    
    # Show a specific problematic naive chunk vs semantic equivalent
    print(f"\n{'='*100}")
    print("EXAMPLE: NAIVE CHUNK THAT BREAKS SEMANTIC BOUNDARY")
    print(f"{'='*100}")
    # Find a naive chunk that starts mid-sentence
    for i, a in enumerate(naive_analysis):
        if a['starts_mid_sentence'] and i > 0:
            print(f"\n--- Naive Chunk {i+1} (starts mid-sentence) ---")
            print(naive_chunks[i][:300])
            print("...")
            break
    
    print(f"\n--- Semantic Chunk covering same content ---")
    # Find the semantic chunk that covers similar content
    if naive_chunks and len(naive_chunks) > 2:
        # Look for overlap by searching for a unique phrase from the problematic naive chunk
        target_phrase = naive_chunks[1][:50].split()[-3:]
        target = ' '.join(target_phrase)
        for i, sc in enumerate(semantic_chunks):
            if target.lower() in sc.lower():
                print(f"Semantic Chunk {i+1}:")
                print(sc[:400])
                print("...")
                break


    # Show 3 full semantic chunks to inspect quality
    print(f"\n{'='*100}")
    print("FULL SEMANTIC CHUNKS (samples)")
    print(f"{'='*100}")
    for i in [0, 4, 12]:
        if i < len(semantic_chunks):
            words_in = len(semantic_chunks[i].split())
            print(f"\n--- Semantic Chunk {i+1} ({words_in} words) ---")
            print(semantic_chunks[i])
            print(f"{'─'*80}")


if __name__ == '__main__':
    with open('test_chunking_doc.md', 'r', encoding='utf-8-sig') as f:
        text = f.read()
    text = text.replace('\ufeff', '').strip()
    
    print_comparison(text)
