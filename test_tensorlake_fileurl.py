"""Test TensorLake file_url approach (same as Worker)"""
import requests
import time
from fpdf import FPDF
import hashlib
import hmac
import base64
from datetime import datetime, timezone, timedelta
from urllib.parse import urlparse, quote

TENSORLAKE_BASE = "https://api.tensorlake.ai/documents/v2"
TENSORLAKE_KEY = "tl_apiKey_n9tNzWL8dnfDDHdFwhDbP_e_H8F1wGbSYBq_wr1C3VI6ERdeoMlR"

# Azure Blob config
AZURE_ACCOUNT = "rawnotesstorage"
AZURE_CONTAINER = "notes-storage"
AZURE_KEY = "vNJYMYALLiNXPwMZcT8fqCxh8Gc8tgBTvSu7LVkuq0gQJf7xsv0H4MqNFqRIRhCTYRhAA4lrm1Lq+AStWL3jMg=="

def generate_sas_url(blob_path: str, expiry_minutes: int = 30) -> str:
    """Generate Azure Blob SAS URL (same logic as Worker)"""
    expiry = datetime.now(timezone.utc) + timedelta(minutes=expiry_minutes)
    expiry_str = expiry.strftime("%Y-%m-%dT%H:%M:%SZ")
    start = datetime.now(timezone.utc) - timedelta(minutes=5)
    start_str = start.strftime("%Y-%m-%dT%H:%M:%SZ")
    
    # Canonical resource
    canonical_resource = f"/blob/{AZURE_ACCOUNT}/{AZURE_CONTAINER}/{blob_path}"
    
    # String to sign (order matters!)
    string_to_sign = "\n".join([
        "r",           # permissions (read)
        start_str,     # start time
        expiry_str,    # expiry time
        canonical_resource,
        "",            # signed identifier
        "",            # signed IP
        "https",       # protocol
        "2022-11-02",  # version
        "b",           # resource type (blob)
        "",            # snapshot time
        "",            # encryption scope
        "",            # rscc
        "",            # rscd
        "",            # rsce
        "",            # rscl
        ""             # rsct
    ])
    
    # HMAC signature
    key_bytes = base64.b64decode(AZURE_KEY)
    sig = base64.b64encode(
        hmac.new(key_bytes, string_to_sign.encode('utf-8'), hashlib.sha256).digest()
    ).decode('utf-8')
    
    # Build SAS URL
    sas_params = (
        f"sp=r&st={quote(start_str)}&se={quote(expiry_str)}"
        f"&spr=https&sv=2022-11-02&sr=b&sig={quote(sig)}"
    )
    
    return f"https://{AZURE_ACCOUNT}.blob.core.windows.net/{AZURE_CONTAINER}/{blob_path}?{sas_params}"

# Create tiny PDF
pdf = FPDF()
pdf.add_page()
pdf.set_font("Helvetica", size=12)
pdf.cell(0, 10, "Tiny Test Document")
pdf.ln(10)
pdf.multi_cell(0, 8, "This is a small test to verify TensorLake file_url integration.")
pdf_bytes = bytes(pdf.output())
print(f"PDF size: {len(pdf_bytes)} bytes")

# Upload to Azure Blob
blob_name = f"test/tiny_test_{int(time.time())}.pdf"
blob_url = f"https://{AZURE_ACCOUNT}.blob.core.windows.net/{AZURE_CONTAINER}/{blob_name}"

print(f"\n1. Uploading to Azure Blob: {blob_name}")
date_str = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
content_type = "application/pdf"

# Azure REST API auth
string_to_sign = f"PUT\n\n\n{len(pdf_bytes)}\n\napplication/pdf\n\n\n\n\n\n\nx-ms-blob-type:BlockBlob\nx-ms-date:{date_str}\nx-ms-version:2022-11-02\n/{AZURE_ACCOUNT}/{AZURE_CONTAINER}/{blob_name}"
sig = base64.b64encode(
    hmac.new(base64.b64decode(AZURE_KEY), string_to_sign.encode('utf-8'), hashlib.sha256).digest()
).decode('utf-8')

resp = requests.put(
    blob_url,
    data=pdf_bytes,
    headers={
        "x-ms-blob-type": "BlockBlob",
        "x-ms-date": date_str,
        "x-ms-version": "2022-11-02",
        "Content-Type": content_type,
        "Content-Length": str(len(pdf_bytes)),
        "Authorization": f"SharedKey {AZURE_ACCOUNT}:{sig}"
    }
)
print(f"   Blob upload: {resp.status_code}")
if resp.status_code >= 300:
    print(f"   Error: {resp.text}")
    exit(1)

# Generate SAS URL
sas_url = generate_sas_url(blob_name)
print(f"   SAS URL: {sas_url[:80]}...")

# Test SAS URL works
print("\n2. Testing SAS URL...")
test_resp = requests.head(sas_url)
print(f"   HEAD request: {test_resp.status_code}")

# Call TensorLake with file_url
print("\n3. Calling TensorLake /read with file_url...")
tl_headers = {
    "Authorization": f"Bearer {TENSORLAKE_KEY}",
    "Content-Type": "application/json"
}
tl_resp = requests.post(
    f"{TENSORLAKE_BASE}/read",
    json={"file_url": sas_url},
    headers=tl_headers
)
print(f"   Response: {tl_resp.status_code}")
print(f"   Body: {tl_resp.text[:300]}")

if tl_resp.status_code >= 300:
    print("   ERROR!")
    exit(1)

data = tl_resp.json()
parse_id = data.get("parse_id") or data.get("task_id")
print(f"   parse_id: {parse_id}")

# Poll for results
print("\n4. Polling...")
for i in range(30):
    time.sleep(1)
    poll_resp = requests.get(f"{TENSORLAKE_BASE}/parse/{parse_id}", headers={"Authorization": f"Bearer {TENSORLAKE_KEY}"})
    poll_data = poll_resp.json()
    status = poll_data.get("status", "?")
    print(f"   [{i+1:2d}] HTTP {poll_resp.status_code} | status={status}")
    
    if status.lower() in ["successful", "completed", "success"]:
        print("\n5. SUCCESS! Response keys:", list(poll_data.keys()))
        
        if "document_markdown" in poll_data:
            md = poll_data["document_markdown"]
            print(f"\n   document_markdown ({len(md)} chars): {md[:200]}")
        
        if "chunks" in poll_data:
            chunks = poll_data["chunks"]
            print(f"\n   chunks: {len(chunks)} items")
            if chunks:
                print(f"   chunks[0] keys: {list(chunks[0].keys())}")
        
        if "pages" in poll_data:
            pages = poll_data["pages"]
            print(f"\n   pages: {len(pages)} items")
            if pages:
                print(f"   pages[0] keys: {list(pages[0].keys())}")
        break
    
    if status.lower() == "failed":
        print(f"   FAILED: {poll_data}")
        break
else:
    print("   Timeout")
