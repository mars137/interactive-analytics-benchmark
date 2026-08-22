"""Delete all WI22_ARM_* templates so they can be recreated cleanly."""
import json
import urllib.request

API = "http://127.0.0.1:8000"

with urllib.request.urlopen(f"{API}/api/templates/", timeout=60) as r:
    body = json.load(r)
items = body if isinstance(body, list) else body.get("templates", body.get("items", []))

for t in items:
    name = str(t.get("template_name", ""))
    if not name.startswith("WI22_ARM_"):
        continue
    req = urllib.request.Request(
        f"{API}/api/templates/{t['template_id']}", method="DELETE"
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            print(f"deleted {name}: HTTP {r.status}")
    except Exception as e:  # noqa: BLE001 - report and continue
        print(f"delete {name} failed: {e}")
