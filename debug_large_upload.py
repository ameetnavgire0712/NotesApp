"""Upload a larger test PDF (~200KB with lots of text) to test longer TensorLake processing"""
import requests, time
from fpdf import FPDF

WORKER_URL = "https://notesapp-vector-search.monocle0712.workers.dev"
API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Create a large multi-page PDF (~100KB+)
pdf = FPDF()
for i in range(50):
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 10, f"Chapter {i+1} - Machine Learning Fundamentals")
    pdf.ln(15)
    pdf.set_font("Helvetica", "", 11)
    for j in range(25):
        pdf.cell(0, 7, f"Section {i+1}.{j+1}: Deep learning architectures enable neural networks to learn hierarchical representations of data.")
        pdf.ln(7)
        pdf.cell(0, 7, f"Transformer models use self-attention mechanisms to process sequential data efficiently without recurrence.")
        pdf.ln(7)

pdf_bytes = bytes(pdf.output())
print(f"Test PDF size: {len(pdf_bytes)} bytes ({len(pdf_bytes)/1024:.1f} KB)")

# Upload
files = {"file": ("large_test_doc.pdf", pdf_bytes, "application/pdf")}
headers = {"X-API-Key": API_KEY}
resp = requests.post(f"{WORKER_URL}/api/v1/upload/file", files=files, data={"tag": "test"}, headers=headers)
print(f"Upload: {resp.status_code}")
result = resp.json()
print(f"Result: {result}")
trace_id = result.get("trace_id", "")

# Poll
if trace_id:
    print(f"\nPolling: {trace_id}")
    for i in range(90):
        time.sleep(3)
        r = requests.get(f"{WORKER_URL}/api/v1/upload/status/{trace_id}", headers=headers)
        s = r.json()
        status = s.get("status", "?")
        note = s.get("note_id", "-")
        print(f"  [{i+1:2d}] {(i+1)*3:3d}s status={status}")
        if status in ("completed", "failed"):
            if status == "completed":
                print(f"\n=== SUCCESS in ~{(i+1)*3}s ===")
                print(f"  Note ID: {note}")
            else:
                print(f"\n=== FAILED: {s.get('error', s.get('error_message', '?'))} ===")
            break
    else:
        print("\nTimeout after 4.5 minutes")
