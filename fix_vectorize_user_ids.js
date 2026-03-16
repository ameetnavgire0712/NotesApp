/**
 * Script to fix missing user_id in Vectorize metadata
 * 
 * This script:
 * 1. Queries Vectorize to find vectors without user_id
 * 2. Gets the note details from Supabase (which has user_id)
 * 3. Re-upserts vectors with correct user_id metadata
 * 
 * Usage: 
 *   SUPABASE_SERVICE_KEY=your_key node fix_vectorize_user_ids.js
 */

const SUPABASE_URL = 'https://vnpqsmiuismvwsynpmfu.supabase.co';
const SUPABASE_SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;
const WORKER_URL = 'https://notesapp-vector-search.monocle0712.workers.dev';
const WORKER_API_KEY = 'Infosys0712!';

// Check what user_ids exist in vectors
async function checkVectorUserIds() {
  console.log('Checking vector metadata for user_ids...\n');
  
  const response = await fetch(`${WORKER_URL}/hybrid`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': WORKER_API_KEY
    },
    body: JSON.stringify({
      query: 'document note',
      rerank: false
    })
  });
  
  const data = await response.json();
  
  console.log('Sample of vector metadata:');
  (data.trace_data?.vector_candidates || []).slice(0, 5).forEach(v => {
    console.log(`  note_id: ${v.note_id?.slice(0,8)}... | user_id: ${v.user_id || 'MISSING'} | title: ${v.title?.slice(0,30)}`);
  });
  
  const hasUserId = (data.trace_data?.vector_candidates || []).filter(v => v.user_id).length;
  const missing = (data.trace_data?.vector_candidates || []).filter(v => !v.user_id).length;
  
  console.log(`\nVectors with user_id: ${hasUserId}`);
  console.log(`Vectors missing user_id: ${missing}`);
  
  // Collect unique note_ids without user_id
  const noteIds = new Set();
  (data.trace_data?.vector_candidates || []).forEach(v => {
    if (!v.user_id && v.note_id) {
      noteIds.add(v.note_id);
    }
  });
  
  return [...noteIds];
}

// Get note details from Supabase (has user_id!)
async function getNoteFromSupabase(noteId) {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&select=id,user_id,title,tag,blob_url,content_markdown`,
    {
      headers: {
        'apikey': SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${SUPABASE_SERVICE_KEY}`,
        'Content-Type': 'application/json'
      }
    }
  );
  
  if (!response.ok) {
    console.error(`Failed to fetch note ${noteId}: ${response.status}`);
    return null;
  }
  
  const notes = await response.json();
  return notes[0] || null;
}

// Re-upsert a note's vectors with user_id
async function reindexNote(note) {
  console.log(`\nRe-indexing note: ${note.id} (${note.title?.slice(0, 40)}...)`);
  console.log(`  user_id: ${note.user_id}`);
  
  const content = note.content_markdown;
  if (!content || content.length < 50) {
    console.log('  ⚠️ Skipping - content too short');
    return false;
  }
  
  // Simple chunking (matches the backend chunker roughly)
  const chunkSize = 1000;
  const overlap = 200;
  const chunks = [];
  
  for (let i = 0; i < content.length; i += (chunkSize - overlap)) {
    const chunk = content.slice(i, i + chunkSize);
    if (chunk.length > 50) {
      chunks.push({
        id: `${note.id}_chunk_${chunks.length}`,
        text: chunk,  // Worker will generate embedding
        metadata: {
          note_id: note.id,
          user_id: note.user_id,  // <-- THE FIX
          title: note.title || 'Untitled',
          tag: note.tag || '',
          blob_url: note.blob_url || '',
          chunk_index: chunks.length,
          content: chunk.slice(0, 500)
        }
      });
    }
  }
  
  console.log(`  Created ${chunks.length} chunks with user_id`);
  
  if (chunks.length === 0) {
    return false;
  }
  
  // Upsert to Worker (will overwrite existing vectors with same ID)
  const response = await fetch(`${WORKER_URL}/upsert`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': WORKER_API_KEY
    },
    body: JSON.stringify({
      vectors: chunks
    })
  });
  
  if (!response.ok) {
    console.error(`  ❌ Upsert failed: ${response.status} ${await response.text()}`);
    return false;
  }
  
  const result = await response.json();
  console.log(`  ✅ Upserted ${result.count} vectors`);
  return true;
}

async function main() {
  if (!SUPABASE_SERVICE_KEY) {
    console.error('❌ SUPABASE_SERVICE_KEY environment variable required');
    console.log('\nUsage:');
    console.log('  $env:SUPABASE_SERVICE_KEY="your_service_key"');
    console.log('  node fix_vectorize_user_ids.js');
    process.exit(1);
  }
  
  try {
    // Step 1: Find notes without user_id in vectors
    const noteIds = await checkVectorUserIds();
    console.log(`\nFound ${noteIds.length} notes needing user_id fix`);
    
    if (noteIds.length === 0) {
      console.log('✅ All vectors have user_id!');
      return;
    }
    
    // Step 2: Re-index each note
    let fixed = 0;
    for (const noteId of noteIds) {
      const note = await getNoteFromSupabase(noteId);
      if (note) {
        const success = await reindexNote(note);
        if (success) fixed++;
      } else {
        console.log(`\n⚠️ Note ${noteId} not found in Supabase (may have been deleted)`);
      }
      
      // Rate limit
      await new Promise(r => setTimeout(r, 1000));
    }
    
    console.log(`\n========================================`);
    console.log(`Fixed ${fixed}/${noteIds.length} notes`);
    console.log(`========================================`);
    
    // Verify the fix
    console.log('\nVerifying fix...');
    await checkVectorUserIds();
    
  } catch (error) {
    console.error('Error:', error);
    process.exit(1);
  }
}

main();

