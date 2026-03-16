"""Test the upload endpoint"""
import httpx
import asyncio

async def test_upload():
    async with httpx.AsyncClient(timeout=300.0) as client:
        # Test file upload
        with open("requirements.txt", "rb") as f:
            content = f.read()
        
        files = {"file": ("requirements.txt", content, "text/plain")}
        data = {"title": "Test Requirements File", "tag": "test"}
        
        print("Uploading file...")
        response = await client.post(
            "http://localhost:8000/api/v1/upload/file",
            files=files,
            data=data
        )
        
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")

if __name__ == "__main__":
    asyncio.run(test_upload())
