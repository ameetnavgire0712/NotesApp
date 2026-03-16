"""Poll TensorLake for completion"""
import requests, time

API_KEY = "tl_apiKey_n9tNzWL8dnfDDHdFwhDbP_e_H8F1wGbSYBq_wr1C3VI6ERdeoMlR"
BASE = "https://api.tensorlake.ai/documents/v2"
parse_id = "parse_KNwPtt7jC6znQrwhgpJKd"

print("Polling...")
for i in range(60):
    time.sleep(2)
    r = requests.get(f"{BASE}/parse/{parse_id}", headers={"Authorization": f"Bearer {API_KEY}"})
    d = r.json()
    status = d.get("status", "?")
    print(f"  [{i+1}] status={status}")
    if status not in ["processing", "pending", "queued"]:
        print(f"  DONE! Keys: {list(d.keys())}")
        if d.get("result"):
            print(f"  Result keys: {list(d['result'].keys())}")
        print(f"  Raw: {str(d)[:2000]}")
        break
