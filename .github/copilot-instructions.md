# Copilot Instructions — lapis-memory

## Identity
Your name is **Momo**.

## Project Overview
`lapis-memory` is a persistent semantic memory library for AI agents running on **Lapis / OpenResty** (LuaJIT + PostgreSQL). It is a LuaRocks package installed into host apps via `luarocks-5.1 install lapis-memory`. The library is **not** a runnable app by itself — it is consumed by a host Lapis app.

- **GitHub**: https://github.com/kaio326/lapis-memory
- **LuaRocks package name**: `lapis-memory`
- **Current version**: `0.1.2-1` (tag `v0.1.2`)
- **Primary consumer**: the `portfolio` app at https://github.com/kaio326/portfolio

## Stack
- **Language**: Lua 5.1 / LuaJIT (OpenResty)
- **Runtime APIs**: `resty.aes`, `resty.random`, `resty.string`, `resty.http`, `ngx.*`, `lapis.db`
- **DB**: PostgreSQL 15 via `lapis.db` raw SQL
- **Protocol**: MCP (Model Context Protocol) stdio JSON-RPC 2.0 via `mcp/server.lua`
- **No Node, no Python runtime** — pure Lua

## Repository Layout

```
lapis_memory/           Core library modules
  init.lua              Entry point / M.setup() / re-exports
  store.lua             Vector + FTS memory storage
  embed.lua             Embedder dispatch
  routes.lua            Lapis HTTP route factory (M.register)
  web.lua               Self-contained admin web UI
  kg.lua                Knowledge-graph (lm_kg_facts)
  rerank.lua            Reranker dispatch
  secrets.lua           AES-256-CBC encrypted secret storage ← NEW in 0.1.2
  summarizer.lua        Background summarizer
  adapters/             Embedder adapters (ollama, openai, tei, …)
  embedders/            hash (pure-Lua, zero-deps)
  rerankers/            noop, ollama, openai, cross_encoder
  summarizers/          noop, ollama, openai
  cli/                  memo init / memo doctor support modules
  migrations/           Idempotent SQL migrations (001–005)
mcp/
  server.lua            Standalone CLI stdio MCP server
cli/
  memo                  Shell entrypoint (memo init, memo doctor, memo run)
examples/               Usage documentation
lapis-memory-0.1.2-1.rockspec
```

## Architecture

### HTTP routes (`lapis_memory/routes.lua`)
`M.register(app, opts)` registers all routes under `prefix` (default `/api/memory`).
- `authorise(self)` guards every route — calls `cfg.before_request` then `cfg.auth_fn`
- `decode_body(self)` normalises POST params / JSON body
- `json(status, body)` returns a Lapis response table

Route groups (all under `prefix`):
| Group | Routes |
|-------|--------|
| Core memory | CRUD + search + recent + promote |
| Knowledge graph | `/kg/*` — query, invalidate, timeline |
| Secrets | `/secrets`, `/secrets/:name/delete`, `/secrets/:name/execute` |

### MCP server (`mcp/server.lua`)
Standalone CLI process — JSON-RPC 2.0 over stdio. Bridges MCP clients (Claude Desktop, Cursor, Copilot Agent Mode) to the running lapis-memory HTTP API via `curl` shell-out.

Config via env vars: `MEMO_URL` (required), `MEMO_TOKEN`, `MEMO_SCOPE`, `MEMO_DEBUG`.

Tools table (each entry: `{ description, inputSchema, handler }`):
- `memory_write`, `memory_search`, `memory_recent`, `memory_get`, `memory_update`, `memory_delete`, `memory_promote`
- `secret_list`, `secret_store`, `secret_delete`, `secret_execute` ← NEW in 0.1.2

### Config (`M.setup(config)`)
All config keys set on `M.config`. `M.setup()` is called once by the host app at startup. Key fields:

| Key | Purpose |
|-----|---------|
| `embedder_local` | Which embedder to use (`"hash"`, `"ollama"`, `"openai"`, …) |
| `auth_fn` | Function `(self) → bool` — return false to allow, truthy to deny |
| `before_request` | Pre-auth hook |
| `master_key_path` | Path to a file containing a 64-hex-char master key for secrets |
| `master_key_env` | Name of an env var containing the master key |
| `master_key` | Explicit master key string (dev/CI only) |

## Secrets Module (`lapis_memory/secrets.lua`) — v0.1.2

### Design principle: execute_with_secret
The raw secret value **never crosses the LLM context boundary**. Only the HTTP response is returned.

### Key points
- AES-256-CBC encryption via `resty.aes` with random 8-byte salt per write
- Stored format: `"<16-char salt_hex>:<ciphertext_hex>"` in `lm_secrets.ciphertext`
- Master key resolution order: `master_key_path` file → `master_key_env` env var → `master_key` explicit. If none set, module is disabled; all other library features continue to work.
- No `get_secret` API exists — values cannot be retrieved through the HTTP or MCP layer

### Public API
```lua
local secrets = require("lapis_memory.secrets")

secrets.configure(config)            -- called automatically by M.setup()
secrets.enabled()                    -- → bool
secrets.store(name, value, desc)     -- → row, err
secrets.list()                       -- → [{id, name, description, ...}]  (no ciphertext)
secrets.delete(name)                 -- → bool, err
secrets.execute_with_secret(name, opts)  -- → response_body, err
```

`execute_with_secret` opts: `{ url, method?, headers?, body?, timeout_ms? }`.
Write `{secret}` anywhere in `url`, header values, or `body` — it is substituted server-side.

### DB table (`lm_secrets`)
Migration: `lapis_memory/migrations/005_lm_secrets.sql`
Columns: `id`, `name` (UNIQUE), `ciphertext`, `description`, `created_at`, `updated_at`, `last_used_at`, `used_count`.

## Migrations Pattern
- `migrations/001_init.sql` runs `\i schema.sql` for fresh installs
- `schema.sql` / `schema_bruteforce.sql` define only the base `lapis_memory` table
- All addons (KG, secrets, …) live in numbered migration files
- Migrations must be idempotent (`IF NOT EXISTS`, `IF EXISTS`)
- Apply sequentially: `psql -d mydb < lapis_memory/migrations/005_lm_secrets.sql`

## Rockspec Conventions
- File naming: `lapis-memory-<version>-<revision>.rockspec`
- `source.tag` must match the Git tag exactly (e.g. `"v0.1.2"`)
- All new `lapis_memory/*.lua` modules must be added to `build.modules`
- After creating a new rockspec: `git tag v<version> && git push origin v<version>`, then `luarocks upload lapis-memory-<version>-<revision>.rockspec`

## Consumer App Wiring (portfolio)
The portfolio app (`helpers/memory.lua`) calls `M.setup()` wrapped in `pcall` — failures log to `ngx.ERR` and never block app startup. To enable secrets in the portfolio:
1. Add `master_key_path = "/run/secrets/lm_master_key"` to the `setup({})` call in `helpers/memory.lua`
2. Generate key: `openssl rand -hex 32 > secrets/lm_master_key.txt`
3. Add `lm_master_key` to `docker-compose.yml` secrets section
4. Append `005_lm_secrets.sql` to portfolio's `db_migration.sql`
5. Bump `luarocks-5.1 install lapis-memory` version in portfolio's `Dockerfile` to `0.1.2-1`

## Developer Workflow
```bash
# The library has no runnable dev server — test via a host Lapis app.
# For quick Lua syntax checks:
luac -p lapis_memory/secrets.lua

# Push a new version
git tag v0.1.X && git push origin main v0.1.X
luarocks upload lapis-memory-0.1.X-1.rockspec  # requires API key
```

## File Editing Rule
**Never edit workspace files via terminal commands** (`sed -i`, `echo >`, `tee`, etc.). Always use the dedicated file editing tools (`replace_string_in_file`, `multi_replace_string_in_file`, `create_file`). Terminal commands are for reading/inspecting only.

## Commit Message Format
Follow conventional commits:
```
<type>: <short summary in imperative mood>

- <bullet: what changed and why>
```
Types: `feat`, `fix`, `refactor`, `chore`, `docs`.

## Key Files
| File | Purpose |
|------|---------|
| `lapis_memory/init.lua` | Entry point; `M.setup()`, config defaults, re-exports |
| `lapis_memory/routes.lua` | HTTP route factory; `M.register(app, opts)` |
| `lapis_memory/secrets.lua` | AES-256-CBC secret storage + execute_with_secret |
| `lapis_memory/kg.lua` | Knowledge-graph fact store |
| `lapis_memory/migrations/005_lm_secrets.sql` | lm_secrets table migration |
| `mcp/server.lua` | Standalone MCP stdio server |
| `cli/memo` | CLI entrypoint (memo init, doctor, run) |
| `lapis-memory-0.1.2-1.rockspec` | Current LuaRocks package spec |
| `CHANGELOG.md` | Release notes; `## Unreleased` section at top |
