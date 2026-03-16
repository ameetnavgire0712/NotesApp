"""Test if HTTP/2 causes TensorLake failure"""
import httpx

api_key = "tl_apiKey_n9tNzWL8dnfDDHdFwhDbP_e_H8F1wGbSYBq_wr1C3VI6ERdeoMlR"
url = "https://api.tensorlake.ai/documents/v2/files"

# Read PDF
with open('test_upload.pdf', 'rb') as f:
    pdf_data = f.read()

print(f"PDF size: {len(pdf_data)} bytes")

# Test with HTTP/1.1 (standard)
print("\n--- HTTP/1.1 Test ---")
try:
    with httpx.Client(http2=False) as client:
        r = client.put(url, files={'file': ('test.pdf', pdf_data, 'application/pdf')},
                       headers={'Authorization': f'Bearer {api_key}'})
        print(f"HTTP/1.1: {r.status_code} - {r.text[:200]}")
except Exception as e:
    print(f"HTTP/1.1 error: {e}")

# Test with HTTP/2
print("\n--- HTTP/2 Test ---")
try:
    with httpx.Client(http2=True) as client:
        r = client.put(url, files={'file': ('test.pdf', pdf_data, 'application/pdf')},
                       headers={'Authorization': f'Bearer {api_key}'})
        print(f"HTTP/2: {r.status_code} - {r.text[:200]}")
except Exception as e:
    print(f"HTTP/2 error: {e}")
