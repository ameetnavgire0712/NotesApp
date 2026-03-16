"""Test PDF upload to verify TensorLake multipart fix works"""
import time
from fpdf import FPDF
import requests

# Create test PDF
p = FPDF()
p.add_page()
p.set_font('Arial', 'B', 16)
p.cell(200, 10, 'Test PDF for Upload Fix', ln=True)
p.set_font('Arial', '', 12)
p.multi_cell(0, 10, (
    'This is a test PDF document to verify that the TensorLake multipart upload fix '
    'works correctly in the Cloudflare Worker. The previous version used Workers built-in '
    'FormData which sent binary-encoded multipart headers that TensorLake Python server '
    'could not parse, returning "failed to convert header to a str". '
    'The fix manually constructs the multipart body with explicit ASCII Content-Disposition '
    'and Content-Type headers.'
))
p.output('test_upload.pdf')
print(f"Created test_upload.pdf")

# Upload to Worker
url = 'https://notesapp-vector-search.monocle0712.workers.dev/api/v1/upload/file'
headers = {'X-API-Key': 'na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU'}
files = {'file': ('test_upload.pdf', open('test_upload.pdf', 'rb'), 'application/pdf')}
data = {'tag': 'test-pdf-fix'}

print("Uploading PDF...")
r = requests.post(url, headers=headers, files=files, data=data)
print(f"Upload response: {r.status_code} - {r.json()}")

if r.status_code == 202:
    trace_id = r.json()['trace_id']
    # Poll for completion
    for i in range(30):
        time.sleep(3)
        sr = requests.get(
            f'{url.rsplit("/", 2)[0]}/upload/status/{trace_id}',
            headers=headers
        )
        status = sr.json()
        print(f"  Poll {i+1}: status={status.get('status')}, error={status.get('error_message','')}")
        if status.get('status') in ('completed', 'failed'):
            if status.get('status') == 'completed':
                print(f"\n✅ SUCCESS! Title: {status.get('title_generated')}")
                print(f"   Chunks: {status.get('chunk_count')}, Time: {status.get('timing_total_ms')}ms")
            else:
                print(f"\n❌ FAILED: {status.get('error_message')}")
                print(f"   Pipeline errors: {status.get('pipeline_errors')}")
            break
