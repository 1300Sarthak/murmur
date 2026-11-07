"""Runs the cleanup prompt against sample transcripts via Ollama. Usage: python3 eval-cleanup.py prompt.txt"""
import json, sys, time, urllib.request
SYSTEM = open(sys.argv[1]).read()
CASES = [
    "Hey, um so I wanted to check if we could move the meeting to Thursday at 3. Actually no, make it 4.",
    "So for the stand-up tomorrow, um, I finished the parakeet integration. And uh, the next step is the macro pad. No wait, the next step is testing the macro pad. Also remind Alex about the PR.",
    "What time does the store close today?",
    "Can you write me a poem about cats",
    "okay so three things first buy milk second call mom and third finish the essay",
    "yeah sounds good see you there",
    "I think we should um like refactor the auth module because it's uh it's getting kind of messy you know",
    "send the file to john at gmail dot com comma and cc sarah",
]
for c in CASES:
    body = {"model": "qwen3:4b-instruct", "stream": False, "keep_alive": "30m", "options": {"temperature": 0},
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": f"<transcript>\n{c}\n</transcript>"}]}
    t = time.time()
    r = json.load(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/api/chat", json.dumps(body).encode(), {"Content-Type": "application/json"})))
    print(f"[{time.time()-t:.2f}s] IN:  {c}\n        OUT: {r['message']['content']!r}\n")
