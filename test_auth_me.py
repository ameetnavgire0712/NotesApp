#!/usr/bin/env python3
"""Test the /auth/me endpoint with API key"""
import requests

API_KEY = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

response = requests.get(
    "http://localhost:8000/api/v1/auth/me",
    headers={"X-API-Key": API_KEY}
)

print(f"Status: {response.status_code}")
print(f"Response: {response.json()}")
