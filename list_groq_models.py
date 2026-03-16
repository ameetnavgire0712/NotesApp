import os
from dotenv import load_dotenv
load_dotenv()
from groq import Groq

client = Groq(api_key=os.getenv('GROQ_API_KEY'))
models = client.models.list()

# Filter out audio/guard models
text_models = [m for m in models.data 
               if 'whisper' not in m.id.lower() 
               and 'guard' not in m.id.lower() 
               and 'orpheus' not in m.id.lower() 
               and 'safeguard' not in m.id.lower()]

print('Text Generation Models with Details:')
print('=' * 80)
for m in sorted(text_models, key=lambda x: x.id):
    print(f'Model: {m.id}')
    ctx = getattr(m, 'context_window', 'N/A')
    owner = getattr(m, 'owned_by', 'N/A')
    print(f'  Context Window: {ctx}')
    print(f'  Owned By: {owner}')
    print()
