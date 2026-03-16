"""Test which Groq models support function calling"""
import os
from dotenv import load_dotenv
load_dotenv()
from groq import Groq

client = Groq(api_key=os.getenv('GROQ_API_KEY'))

# Models to test (excluding audio/guard models)
models_to_test = [
    "llama-3.1-8b-instant",
    "llama-3.3-70b-versatile", 
    "meta-llama/llama-4-maverick-17b-128e-instruct",
    "meta-llama/llama-4-scout-17b-16e-instruct",
    "qwen/qwen3-32b",
    "groq/compound",
    "groq/compound-mini",
    "moonshotai/kimi-k2-instruct",
    "openai/gpt-oss-120b",
    "openai/gpt-oss-20b",
]

# Simple tool for testing
tools = [{
    "type": "function",
    "function": {
        "name": "test_search",
        "description": "Search for documents",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"}
            },
            "required": ["query"]
        }
    }
}]

print("Testing Groq Models for Function Calling Support:")
print("=" * 70)

for model in models_to_test:
    try:
        response = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": "Search for aadhar card"}],
            tools=tools,
            tool_choice="auto",
            max_tokens=100
        )
        
        has_tool_call = bool(response.choices[0].message.tool_calls)
        print(f"✅ {model:<50} Tool calling: {'YES' if has_tool_call else 'responded with text'}")
        
    except Exception as e:
        error_msg = str(e)[:60]
        print(f"❌ {model:<50} Error: {error_msg}")
