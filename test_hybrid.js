// Test if user_id filter works now
async function test() {
  const USER_ID = '2649b4d0-c40d-4ab1-ac04-928fe1cf5969';
  
  console.log('Testing RAG search...');
  const ragResp = await fetch('https://notesapp-vector-search.monocle0712.workers.dev/rag-search', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': 'Infosys0712!'
    },
    body: JSON.stringify({
      query: 'RAG chunking methods',
      user_id: USER_ID
    })
  });
  
  const ragData = await ragResp.json();
  console.log('RAG results:', ragData.results?.length || 0);
  
  if (ragData.results?.length > 0) {
    console.log('First result title:', ragData.results[0].title?.slice(0, 50));
    console.log('View URL:', ragData.results[0].view_url);
    
    // Test the view URL
    console.log('\nTesting view URL...');
    const viewResp = await fetch(ragData.results[0].view_url);
    console.log('View response status:', viewResp.status);
    console.log('View content-type:', viewResp.headers.get('content-type'));
    
    if (viewResp.ok) {
      const contentType = viewResp.headers.get('content-type') || '';
      if (contentType.includes('application/json')) {
        const viewData = await viewResp.json();
        console.log('View response has content:', !!viewData.content_markdown);
        console.log('View response title:', viewData.title?.slice(0, 50));
      } else if (contentType.includes('application/pdf')) {
        const blob = await viewResp.blob();
        console.log('✅ PDF returned successfully, size:', blob.size, 'bytes');
      } else {
        const text = await viewResp.text();
        console.log('Response (first 200 chars):', text.slice(0, 200));
      }
    } else {
      const errorText = await viewResp.text();
      console.log('View error:', errorText);
    }
  }
}

test().catch(console.error);
