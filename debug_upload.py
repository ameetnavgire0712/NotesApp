"""Upload a bigger test PDF and poll status"""
import requests, time
from fpdf import FPDF

WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Create a multi-page PDF (~50KB)
pdf = FPDF()
for i in range(20):
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 10, f"Page {i+1} - Test Upload Pipeline")
    pdf.ln(20)
    pdf.set_font("Helvetica", "", 12)
    for j in range(15):
        pdf.cell(0, 8, f"This is line {j+1} on page {i+1}. Testing the full upload pipeline with TensorLake file_url conversion.")
        pdf.ln(8)

pdf_bytes = bytes(pdf.output())
print(f"Test PDF size: {len(pdf_bytes)} bytes ({len(pdf_bytes)/1024:.1f} KB)")

# Upload
files = {"file": ("big_test.pdf", pdf_bytes, "application/pdf")}
headers = {"X-API-Key": API_KEY}
resp = requests.post(f"{WORKER_URL}/api/v1/upload/file", files=files, data={"tag": "test"}, headers=headers)
print(f"Upload: {resp.status_code}")
result = resp.json()
print(f"Result: {result}")
trace_id = result.get("trace_id", "")

# Poll
if trace_id:
    print(f"\nPolling: {trace_id}")
    for i in range(60):
        time.sleep(3)
        r = requests.get(f"{WORKER_URL}/api/v1/upload/status/{trace_id}", headers=headers)
        s = r.json()
        status = s.get("status", "?")
        method = s.get("conversion_method", "?")
        note = s.get("note_id", "-")
        errs = s.get("pipeline_errors", "-")
        print(f"  [{i+1:2d}] status={status:10s} method={method} note={note} errors={errs}")
        if status in ("completed", "failed"):
            if status == "completed":
                print(f"\n=== SUCCESS in ~{(i+1)*3}s ===")
                print(f"  Note ID: {note}")
                print(f"  Title: {s.get('title', '?')}")
                print(f"  Total: {s.get('timing_total_ms', '?')}ms")
            else:
                print(f"\n=== FAILED ===")
                print(f"  Error: {s.get('error', '?')}")
                print(f"  Pipeline errors: {errs}")
            break
    else:
        print("\nTimeout after 3 minutes")
