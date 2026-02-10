# Skill Manifest v2 Specification

Version: 2.0.0

## Overview

Every skill that wants to be **discoverable, composable, and observable** embeds a `skill-manifest` block in its `SKILL.md`. The Agent reads this manifest to understand what the skill can do, how to call it, and what to expect back.

## Embedding

Fenced code block in SKILL.md:

````
```skill-manifest
{ ... }
```
````

Content is JSON (valid YAML). One block per SKILL.md.

## Schema

```json
{
  "schema_version": "2.0",
  "id": "skill-name",
  "version": "0.1.0",
  "capabilities": ["tag1", "tag2"],
  "effects": ["db.read", "db.write", "proc.exec", "net.fetch", "fs.read", "fs.write"],
  "operations": {
    "operation-name": {
      "description": "What this operation does",
      "input": {
        "param_name": {
          "type": "string | integer | boolean | json",
          "required": true,
          "default": null,
          "description": "What this parameter does"
        }
      },
      "output": {
        "description": "What the output contains",
        "fields": {
          "field_name": "type or description"
        }
      },
      "entrypoints": {
        "unix": ["bash", "scripts/foo.sh", "{param_name}"],
        "windows": ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts\\foo.ps1", "{param_name}"]
      }
    }
  },
  "stdout_contract": {
    "last_line_json": true
  }
}
```

## Field Reference

### Top-Level

| Field | Required | Description |
|-------|----------|-------------|
| `schema_version` | yes | Always `"2.0"` |
| `id` | yes | Matches the skill directory name |
| `version` | yes | Semver |
| `capabilities` | yes | Array of capability tags for discovery. Used by the skills index. |
| `effects` | yes | Side effects this skill may produce. Checked against policy. |
| `operations` | yes | Named operations the skill exposes |
| `stdout_contract` | yes | Output contract. `last_line_json: true` means the last stdout line is always valid JSON. |

### capabilities

Free-form tags describing what the skill can do. Used by the index for capability → skill lookup.

Convention: `domain-verb` format, e.g.:
- `memory-search`, `memory-store`, `memory-health`
- `skill-create`, `skill-validate`, `skill-package`
- `skill-install`, `skill-list`

### effects

Standardized side-effect declarations:

| Effect | Meaning |
|--------|---------|
| `db.read` | Reads from a database |
| `db.write` | Writes to a database |
| `proc.exec` | Executes external processes |
| `fs.read` | Reads files |
| `fs.write` | Writes/creates files |
| `net.fetch` | Makes network requests |
| `git.read` | Reads git state |
| `git.write` | Modifies git state (commit, push) |

### operations[name]

Each operation is a callable unit.

| Field | Required | Description |
|-------|----------|-------------|
| `description` | yes | What this operation does (Agent reads this to decide) |
| `input` | yes | Parameter definitions (can be empty `{}`) |
| `output` | yes | What the JSON output contains |
| `entrypoints` | yes | OS-specific command arrays |

### input[param]

| Field | Required | Description |
|-------|----------|-------------|
| `type` | yes | `string`, `integer`, `boolean`, or `json` |
| `required` | no | Default `false` |
| `default` | no | Default value if not provided |
| `description` | no | What this parameter does |

### entrypoints

Keys: `unix` (Linux/macOS) and `windows`.

Value: argv array. Use `{param_name}` placeholders — the Agent substitutes actual values before executing.

The command runs with the skill directory as cwd.

### output

| Field | Required | Description |
|-------|----------|-------------|
| `description` | yes | Human-readable description of output |
| `fields` | no | Key-value map of field names → types/descriptions |

The last line of stdout must be valid JSON matching this schema.

## Example: Memory Skill

```json
{
  "schema_version": "2.0",
  "id": "skill-system-memory",
  "version": "0.2.0",
  "capabilities": ["memory-search", "memory-store", "memory-health", "memory-types"],
  "effects": ["proc.exec", "db.read", "db.write"],
  "operations": {
    "search": {
      "description": "Search memories by natural language query. Returns ranked results with relevance scores.",
      "input": {
        "query": { "type": "string", "required": true, "description": "Natural language search query" },
        "limit": { "type": "integer", "required": false, "default": 5, "description": "Max results to return" }
      },
      "output": {
        "description": "Array of memory matches with id, title, content, and relevance_score",
        "fields": {
          "status": "ok | error",
          "data": "array of {id, title, content, relevance_score}"
        }
      },
      "entrypoints": {
        "unix": ["bash", "scripts/router_mem.sh", "search", "{query}", "{limit}"],
        "windows": ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts\\router_mem.ps1", "search", "{query}", "{limit}"]
      }
    },
    "store": {
      "description": "Store a new memory. Auto-deduplicates by content hash.",
      "input": {
        "memory_type": { "type": "string", "required": true, "description": "One of: semantic, episodic, procedural, working" },
        "category": { "type": "string", "required": true, "description": "Category name" },
        "title": { "type": "string", "required": true, "description": "One-line summary" },
        "tags_csv": { "type": "string", "required": true, "description": "Comma-separated tags" },
        "importance": { "type": "integer", "required": true, "description": "1-10 importance score" }
      },
      "output": {
        "description": "Confirmation with stored memory id",
        "fields": { "status": "ok | error", "id": "integer" }
      },
      "entrypoints": {
        "unix": ["bash", "scripts/router_mem.sh", "store", "{memory_type}", "{category}", "{title}", "{tags_csv}", "{importance}"],
        "windows": ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts\\router_mem.ps1", "store", "{memory_type}", "{category}", "{title}", "{tags_csv}", "{importance}"]
      }
    },
    "health": {
      "description": "Check memory system health: total count, average importance, stale count.",
      "input": {},
      "output": {
        "description": "Health metrics",
        "fields": { "status": "ok | error", "data": "array of {metric, value, status}" }
      },
      "entrypoints": {
        "unix": ["bash", "scripts/router_mem.sh", "health"],
        "windows": ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts\\router_mem.ps1", "health"]
      }
    },
    "types": {
      "description": "List available memory types and their descriptions.",
      "input": {},
      "output": {
        "description": "Memory type definitions",
        "fields": { "status": "ok | error", "data": "array of {type, lifespan, description}" }
      },
      "entrypoints": {
        "unix": ["bash", "scripts/router_mem.sh", "types"],
        "windows": ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "scripts\\router_mem.ps1", "types"]
      }
    }
  },
  "stdout_contract": {
    "last_line_json": true
  }
}
```

## Migration from v1

v1 used `router-manifest` as the block name. v2 uses `skill-manifest`.

Changes:
- Added `schema_version`
- Added `capabilities`
- Renamed flat `entrypoints` → nested `operations[name].entrypoints`
- Added `input` and `output` schemas per operation
- Added `description` per operation

Skills should update their blocks and change the fence name from `router-manifest` to `skill-manifest`.
