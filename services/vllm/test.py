import json, urllib.request, sys

url = "http://localhost:8000/v1/chat/completions"
payload = json.dumps({
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Say hello in 5 words."}],
    "max_tokens": 20
}).encode()

req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
try:
    resp = urllib.request.urlopen(req, timeout=20)
    data = json.loads(resp.read().decode())
    reply = data["choices"][0]["message"]["content"]
    tokens = data["usage"]
    print(f"OK: {reply}")
    print(f"Tokens: {tokens}")
except Exception as e:
    print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)
