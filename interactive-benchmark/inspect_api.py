"""Inspect FlakeBench's OpenAPI spec to learn the template-creation request schema."""
import json
import sys

spec = json.load(open("/tmp/wi22_openapi.json"))
paths = spec.get("paths", {})

print("=== TEMPLATE / TEST PATHS ===")
for p in sorted(paths):
    if any(k in p.lower() for k in ("template", "test", "run")):
        methods = ",".join(
            m.upper() for m in paths[p] if m in ("get", "post", "put", "delete", "patch")
        )
        print(f"  {methods:16s} {p}")


def resolve(ref, seen=None):
    """Follow a $ref into components/schemas."""
    seen = seen or set()
    if ref in seen:
        return {"<recursive>": ref}
    seen.add(ref)
    name = ref.split("/")[-1]
    return spec.get("components", {}).get("schemas", {}).get(name, {})


def describe(schema, depth=0, maxdepth=2):
    """Print a compact field listing."""
    pad = "  " * (depth + 1)
    if "$ref" in schema:
        schema = resolve(schema["$ref"])
    props = schema.get("properties")
    if not props:
        return
    required = set(schema.get("required", []))
    for field, meta in props.items():
        if "$ref" in meta:
            sub = resolve(meta["$ref"])
            t = sub.get("title", "object")
        else:
            t = meta.get("type", "?")
            if t == "array":
                items = meta.get("items", {})
                it = items.get("type") or items.get("$ref", "?").split("/")[-1]
                t = f"array[{it}]"
        star = "*" if field in required else " "
        default = meta.get("default", None)
        dtxt = f"  (default={default!r})" if default is not None else ""
        print(f"{pad}{star}{field}: {t}{dtxt}")


# Focus on the POST that creates a template
for p in sorted(paths):
    if "template" not in p.lower():
        continue
    for method in ("post", "put"):
        op = paths[p].get(method)
        if not op:
            continue
        body = op.get("requestBody", {}).get("content", {}).get("application/json", {})
        sch = body.get("schema")
        if not sch:
            continue
        print(f"\n=== {method.upper()} {p} ===")
        print(f"  summary: {op.get('summary', '')}")
        describe(sch)
