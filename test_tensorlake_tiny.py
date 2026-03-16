"""Test TensorLake response format with a tiny 1-page PDF"""
import requests
import time
from fpdf import FPDF

TENSORLAKE_BASE = "https://api.tensorlake.ai/documents/v2"
TENSORLAKE_KEY = "tl_apiKey_n9tNzWL8dnfDDHdFwhDbP_e_H8F1wGbSYBq_wr1C3VI6ERdeoMlR"

# Create tiny 1-page PDF (< 1KB)
pdf = FPDF()
pdf.add_page()
pdf.set_font("Helvetica", size=12)
pdf.cell(0, 10, "Test Document")
pdf.ln(10)
pdf.multi_cell(0, 8, "This is a small test to check TensorLake response format.")
pdf_bytes = bytes(pdf.output())
print(f"PDF size: {len(pdf_bytes)} bytes")

# Upload directly to TensorLake
print("\n1. Uploading to TensorLake...")
files = {"file": ("tiny_test.pdf", pdf_bytes, "application/pdf")}
headers = {"Authorization": f"Bearer {TENSORLAKE_KEY}"}

resp = requests.post(f"{TENSORLAKE_BASE}/read", files=files, headers=headers)
print(f"   Upload response: {resp.status_code}")
data = resp.json()
print(f"   Response: {data}")

parse_id = data.get("parse_id") or data.get("task_id")
if not parse_id:
    print("ERROR: No parse_id returned")
    exit(1)

print(f"\n2. Polling parse_id: {parse_id}")
for i in range(30):
    time.sleep(1)
    poll_resp = requests.get(f"{TENSORLAKE_BASE}/parse/{parse_id}", headers=headers)
    poll_data = poll_resp.json()
    status = poll_data.get("status", "?")
    print(f"   [{i+1:2d}] HTTP {poll_resp.status_code} | status={status}")
    
    if status.lower() in ["successful", "completed", "success"]:
        print("\n3. SUCCESS! Full response structure:")
        print(f"   Keys: {list(poll_data.keys())}")
        
        if "document_markdown" in poll_data:
            print(f"\n   document_markdown: {poll_data['document_markdown'][:200]}...")
        
        if "chunks" in poll_data:
            print(f"\n   chunks ({len(poll_data['chunks'])} total):")
            for j, c in enumerate(poll_data['chunks'][:2]):
                print(f"     [{j}] keys={list(c.keys())}, content={str(c.get('content',''))[:100]}")
        
        if "pages" in poll_data:
            print(f"\n   pages ({len(poll_data['pages'])} total):")
            for j, p in enumerate(poll_data['pages'][:1]):
                print(f"     [{j}] keys={list(p.keys())}")
                if "content" in p:
                    print(f"         content={str(p['content'])[:100]}")
                if "page_fragments" in p:
                    print(f"         page_fragments={len(p['page_fragments'])} items")
        break
    
    if status.lower() == "failed":
        print(f"\n   FAILED: {poll_data.get('error', '?')}")
        break
else:
    print("\n   Timeout after 30s")
