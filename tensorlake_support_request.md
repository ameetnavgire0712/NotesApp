# TensorLake Support Request: File Upload Fails from Cloudflare Workers

## Summary
File uploads to the TensorLake Document Ingestion API (`PUT /documents/v2/files`) fail with a **500 Internal Server Error** when the request originates from a **Cloudflare Worker** using the `fetch()` API. The same upload works perfectly from Python (`httpx`, `requests`), `curl`, and all other HTTP clients.

## Error Details
- **Endpoint**: `PUT https://api.tensorlake.ai/documents/v2/files`
- **HTTP Status**: `500`
- **Error Response Body**: `failed to convert header to a str`
- **File types affected**: ALL (PDF, images, etc.) — the issue is with the HTTP transport, not file content

## Environment
- **Runtime**: Cloudflare Workers (V8 isolate, Workers Runtime)
- **HTTP Protocol**: Cloudflare Workers' `fetch()` uses HTTP/2 by default to external origins
- **Authentication**: Bearer token (valid — same API key works from Python)

## Reproduction

### ❌ FAILS — Cloudflare Worker `fetch()`:
```typescript
// Approach 1: FormData + File (standard Web API)
const file = new File([fileData], "document.pdf", { type: "application/pdf" });
const formData = new FormData();
formData.append('file_bytes', file);

const resp = await fetch("https://api.tensorlake.ai/documents/v2/files", {
  method: 'PUT',
  headers: { 'Authorization': `Bearer ${API_KEY}` },
  body: formData,
});
// Result: 500 - "failed to convert header to a str"

// Approach 2: Manually constructed multipart body (pure ASCII headers)
const boundary = 'MyBoundary123';
const encoder = new TextEncoder();
const headerPart = encoder.encode(
  `--${boundary}\r\n` +
  `Content-Disposition: form-data; name="file_bytes"; filename="document.pdf"\r\n` +
  `Content-Type: application/pdf\r\n\r\n`
);
const footerPart = encoder.encode(`\r\n--${boundary}--\r\n`);
const body = new Uint8Array(headerPart.length + fileData.byteLength + footerPart.length);
body.set(headerPart, 0);
body.set(new Uint8Array(fileData), headerPart.length);
body.set(footerPart, headerPart.length + fileData.byteLength);

const resp = await fetch("https://api.tensorlake.ai/documents/v2/files", {
  method: 'PUT',
  headers: {
    'Authorization': `Bearer ${API_KEY}`,
    'Content-Type': `multipart/form-data; boundary=${boundary}`,
    'Content-Length': body.length.toString(),
  },
  body: body.buffer,
});
// Result: ALSO 500 - "failed to convert header to a str"
```

### ✅ WORKS — Python (exact same API key, same file, same multipart format):
```python
# Using httpx (HTTP/2)
import httpx
with httpx.Client(http2=True) as client:
    resp = client.put(
        "https://api.tensorlake.ai/documents/v2/files",
        headers={"Authorization": f"Bearer {API_KEY}"},
        files={"file_bytes": ("document.pdf", pdf_data, "application/pdf")}
    )
# Result: 200 - {"file_id": "file_xxx", "created_at": "..."}

# Using requests (HTTP/1.1)
import requests
resp = requests.put(
    "https://api.tensorlake.ai/documents/v2/files",
    headers={"Authorization": f"Bearer {API_KEY}"},
    files={"file_bytes": ("document.pdf", pdf_data, "application/pdf")}
)
# Result: 200 - {"file_id": "file_xxx", "created_at": "..."}

# Manual multipart from Python (identical byte structure as Worker) - ALSO WORKS
boundary = "TLBoundaryTest12345abc"
header_part = f'--{boundary}\r\nContent-Disposition: form-data; name="file_bytes"; filename="document.pdf"\r\nContent-Type: application/pdf\r\n\r\n'.encode("utf-8")
footer_part = f'\r\n--{boundary}--\r\n'.encode("utf-8")
body = header_part + pdf_data + footer_part
resp = requests.put(
    "https://api.tensorlake.ai/documents/v2/files",
    headers={
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    },
    data=body
)
# Result: 200 - works fine
```

### ✅ WORKS — curl:
```bash
curl --request PUT \
  --url https://api.tensorlake.ai/documents/v2/files \
  --header 'Authorization: Bearer <token>' \
  --header 'Content-Type: multipart/form-data' \
  --form 'file_bytes=@document.pdf'
# Result: 200 - works fine
```

## Additional Test: Transfer-Encoding: chunked
When we explicitly send `Transfer-Encoding: chunked` from Python, TensorLake returns a **400 Bad Request** (raw HTML, not JSON):
```python
resp = requests.put(url, headers={
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": f"multipart/form-data; boundary={boundary}",
    "Transfer-Encoding": "chunked",
}, data=body)
# Result: 400 - <html><head><title>400 Bad Request</title></head>...</html>
```
This suggests TensorLake's server has issues with chunked transfer encoding.

## Root Cause Hypothesis
Cloudflare Workers' `fetch()` sends HTTP/2 requests to upstream origins. In HTTP/2:
- There is no `Transfer-Encoding: chunked` header (chunking is implicit via DATA frames)
- Headers are binary (HPACK compressed), not plain ASCII strings
- Pseudo-headers (`:method`, `:path`, etc.) replace the HTTP/1.1 request line

We believe TensorLake's server (likely Python/FastAPI behind a reverse proxy) is receiving HTTP/2 frames and trying to decode a binary header value as a UTF-8 string, which fails with "failed to convert header to a str".

The fact that `Transfer-Encoding: chunked` over HTTP/1.1 also fails (400 Bad Request) supports this — the server's multipart parser may not handle streamed/chunked bodies properly, and HTTP/2's implicit framing triggers a similar code path.

## What We Need
1. **Can you confirm if your API server supports HTTP/2 for file uploads?**
2. **Is there a way to force HTTP/1.1 for the upload endpoint?**
3. **Could you look at the server logs for our recent failed uploads?** Our API key starts with `tl_apiKey_n9tN...` and the uploads were between 2026-02-19 13:00 UTC and 2026-02-19 14:00 UTC.

## Workaround We've Considered
- We could proxy the upload through a non-Workers service (e.g., our Python backend on Fly.io), but this defeats the purpose of migrating to Workers for lower latency and simpler architecture.
- Is there a way to make the TensorLake API accept HTTP/2 multipart uploads?

## Our Previously Working Python Code (Fly.io)
This is the code that works perfectly and we're trying to replicate in Cloudflare Workers:
```python
class TensorlakeService:
    BASE_URL = "https://api.tensorlake.ai/documents/v2"
    
    async def _upload_file(self, file_content, filename, content_type):
        client = httpx.AsyncClient(http2=True, timeout=120.0)
        response = await client.put(
            f"{self.BASE_URL}/files",
            headers={"Authorization": f"Bearer {self.api_key}"},
            files={"file_bytes": (filename, file_content, content_type)}
        )
        response.raise_for_status()
        return response.json().get("file_id")
```

Thank you for your help!
