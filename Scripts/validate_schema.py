#!/usr/bin/env python3
"""A small JSON Schema checker for docs/schemas/*.json (no third-party packages).

Supports the subset those schemas use: type, enum, const, required, properties, additionalProperties (false or a schema),
items, minimum and local "$ref" into "$defs". Anything else in a schema is an error, so the schema cannot silently
promise more than this script checks.

    python3 Scripts/validate_schema.py docs/schemas/scan-report.schema.json report.json
    sfverify --json ... | python3 Scripts/validate_schema.py docs/schemas/scan-report.schema.json -
"""
import json
import sys

SUPPORTED = {
    "$schema", "title", "description", "$defs", "$ref", "type", "enum", "const", "required", "properties",
    "additionalProperties", "items", "minimum",
}
TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
}


def validate(value, schema, root, path="$"):
    """Returns a list of problems (empty when `value` conforms to `schema`)."""
    unknown = set(schema) - SUPPORTED
    if unknown:
        return [f"{path}: schema keyword(s) not supported by this checker: {sorted(unknown)}"]
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].removeprefix("#/").split("/"):
            node = node[part]
        return validate(value, node, root, path)
    problems = []
    if "type" in schema and not TYPES[schema["type"]](value):
        return [f"{path}: expected {schema['type']}, found {type(value).__name__}"]
    if "const" in schema and (value != schema["const"] or isinstance(value, bool) != isinstance(schema["const"], bool)):
        problems.append(f"{path}: expected {schema['const']!r}, found {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if "minimum" in schema and TYPES["number"](value) and value < schema["minimum"]:
        problems.append(f"{path}: {value} is below {schema['minimum']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{path}: missing required key {key!r}")
        properties = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for key, child in value.items():
            if key in properties:
                problems += validate(child, properties[key], root, f"{path}.{key}")
            elif extra is False:
                problems.append(f"{path}: unexpected key {key!r}")
            elif isinstance(extra, dict):
                problems += validate(child, extra, root, f"{path}.{key}")
    if isinstance(value, list) and "items" in schema:
        for i, child in enumerate(value):
            problems += validate(child, schema["items"], root, f"{path}[{i}]")
    return problems


def check(value, schema_path):
    with open(schema_path) as f:
        schema = json.load(f)
    return validate(value, schema, schema)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    text = sys.stdin.read() if sys.argv[2] == "-" else open(sys.argv[2]).read()
    problems = check(json.loads(text), sys.argv[1])
    for p in problems:
        print(p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
