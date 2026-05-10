# luamemo MCP server

A pure-Lua [Model Context Protocol](https://modelcontextprotocol.io/) stdio
server that gives AI clients (Claude Desktop, Cursor, Continue.dev,
Copilot Agent Mode, …) direct access to the luamemo memory store.

It operates in two modes — choose the one that fits your setup:

| Mode | How it connects | When to use |
|------|----------------|-------------|
| **Direct DB** (`MEMO_DB_URL`) | Connects to PostgreSQL directly — no running HTTP server required | Standalone use: AI agent only, or plain Lua app without Lapis |
| **HTTP API** (`MEMO_URL`) | Calls your running Lapis/HTTP app's `/api/memory` routes | When you want the agent to go through your app's `auth_fn` and middleware |

For most users the direct-DB mode is the right choice — it requires only
PostgreSQL and the `luamemo` library.

Once installed, your AI assistant can call eleven tools:

| Tool | Purpose |
|---|---|
| `memory_write`   | Store a memory (decision, fact, plan, snippet, …). Optional `importance` (0..10) and `decay_rate` (0..1/day) control search ranking. |
| `memory_search`  | Hybrid vector + full-text search, weighted by importance × time-decay. `ignore_decay=true` disables weighting (debug). |
| `memory_recent`  | List most recent memories in a scope. |
| `memory_get`     | Fetch a single memory by ID. |
| `memory_update`  | Update title / body / tags / metadata / importance / decay_rate. |
| `memory_delete`  | Permanently delete a memory. |
| `memory_promote` | Roll a hot session scope into a long-term scope (session-continuity). |
| `secret_list`    | List stored secrets — names and metadata only, **no values**. |
| `secret_store`   | Encrypt and store an API key or token. **Use from terminal only** — never call this from the chat window. |
| `secret_delete`  | Permanently delete a stored secret. |
| `secret_execute` | Make an HTTP request with `{secret}` substituted server-side; only the response body is returned to the agent. |

These survive chat-session crashes, IDE restarts, device switches, and the
VS Code "Invalid string length" overflow on very long sessions.

---

## Requirements

- **Lua 5.1+** or **LuaJIT** (whichever is on your `$PATH` as `lua`)
- **lua-cjson** (`luarocks install lua-cjson`)
- **PostgreSQL 15+** with the luamemo schema applied (direct-DB mode)
  — or a running `luamemo` HTTP API (HTTP mode)

> ### `curl` dependency (HTTP mode only)
> When using `MEMO_URL` (HTTP mode), the MCP server shells out to `curl`
> for its HTTP calls. `curl` is preinstalled on macOS, Linux, and modern
> Windows. In direct-DB mode (`MEMO_DB_URL`) no `curl` is needed — all
> calls go through `luamemo.db` / pgmoon directly.

---

## Install

```bash
git clone https://github.com/kaio326/lapis-memory.git ~/luamemo
chmod +x ~/luamemo/mcp/server.lua
luarocks install lua-cjson    # if not already installed
```

Verify:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | MEMO_URL=http://localhost:8080/api/memory lua ~/luamemo/mcp/server.lua
```

You should get a one-line JSON response containing `serverInfo` and
`capabilities`.

---

## Configure your client

All examples below show the **direct-DB mode** (`MEMO_DB_URL`), which is the
simplest setup — no running HTTP server required. To use HTTP mode instead,
replace `MEMO_DB_URL` with `MEMO_URL` (and optionally `MEMO_TOKEN` for auth).
See [Transport modes](#transport-modes) for the trade-offs.

### Claude Desktop

Edit `claude_desktop_config.json`:

- macOS:  `~/Library/Application Support/Claude/claude_desktop_config.json`
- Linux:  `~/.config/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "luamemo": {
      "command": "lua",
      "args": ["/absolute/path/to/luamemo/mcp/server.lua"],
      "env": {
        "MEMO_DB_URL": "postgresql://user:pass@localhost:5432/mydb",
        "MEMO_SCOPE":  "global"
      }
    }
  }
}
```

Restart Claude Desktop. The eleven memory and secret tools will appear in the tool list.

### Cursor

Cursor reads MCP servers from `~/.cursor/mcp.json` (same schema as Claude
Desktop). Use the identical config.

### Continue.dev

In `~/.continue/config.yaml`:

```yaml
experimental:
  modelContextProtocolServers:
    - transport:
        type: stdio
        command: lua
        args: ["/absolute/path/to/luamemo/mcp/server.lua"]
        env:
          MEMO_DB_URL: postgresql://user:pass@localhost:5432/mydb
          MEMO_SCOPE:  global
```

### Copilot Agent Mode (VS Code)

Add to `.vscode/mcp.json` in your workspace:

```json
{
  "servers": {
    "luamemo": {
      "type": "stdio",
      "command": "lua",
      "args": ["/absolute/path/to/luamemo/mcp/server.lua"],
      "env": {
        "MEMO_DB_URL": "postgresql://user:pass@localhost:5432/mydb",
        "MEMO_SCOPE":  "repo:my-project"
      }
    }
  }
}
```

---

## Environment variables

### Direct-DB mode

| Variable | Required | Purpose |
|---|---|---|
| `MEMO_DB_URL` | yes | PostgreSQL connection URL — `postgresql://user:pass@host:5432/db` |
| `MEMO_SCOPE`  | no  | Default scope when a tool call omits `scope` |
| `MEMO_MASTER_KEY`    | no | 64-hex-char AES-256 master key for encrypted secrets |
| `MEMO_SECRETS_FILE`  | no | Writable path for the encrypted secrets JSON file — both `MEMO_MASTER_KEY` and `MEMO_SECRETS_FILE` must be set to enable secrets |
| `MEMO_DEBUG`  | no  | Set to `1` to log raw JSON-RPC frames to stderr |

### HTTP mode

| Variable | Required | Purpose |
|---|---|---|
| `MEMO_URL`   | yes | Base URL of the luamemo HTTP API — e.g. `https://app.example.com/api/memory` |
| `MEMO_TOKEN` | no  | Bearer token sent as `Authorization: Bearer <token>` |
| `MEMO_SCOPE` | no  | Default scope when a tool call omits `scope` |
| `MEMO_DEBUG` | no  | Set to `1` to log raw JSON-RPC frames to stderr |

`MEMO_SCOPE` is the simplest way to point one MCP server instance at one
project — set it to `repo:my-project` and every write/search defaults to
that bucket without the model having to remember.

---

## Transport modes

### Direct DB (`MEMO_DB_URL`) — recommended for most users

The MCP server calls `luamemo.db` / pgmoon directly. No running HTTP
server required. This is the right choice when:

- You only need AI agent access to memory (not your app code)
- You are using a standalone Lua script, CLI tool, or eval harness
- You want the simplest possible setup

`memory.setup()` and `routes.register()` are **not needed** in this mode.
The MCP server calls `luamemo.setup()` internally using `MEMO_DB_URL`.

### HTTP API (`MEMO_URL`) — use when auth matters

The MCP server calls your running Lapis (or any HTTP) app's
`/api/memory` routes via `curl`. Use this when:

- You want the AI agent to go through the same `auth_fn`, rate-limiter,
  or CSRF hook that protects your app's other routes
- Your Lapis app code also calls `store.write()` in-process and you want
  a single, authoritative request path
- You run multiple agents sharing one app and need per-agent token auth

In this mode you **do** need `memory.setup()` and `routes.register()` in
your Lapis app, and the app must be running when the MCP server is active.

### Using both together (Lapis apps)

For a Lapis app, the common combination is:

- `memory.setup()` + `routes.register(app)` — for in-process use by your
  app code (e.g. auto-capturing messages via `luamemo.hooks`) and for
  non-MCP HTTP clients
- MCP server with `MEMO_URL` pointing at your Lapis routes — when you
  want the AI agent's writes to pass through `auth_fn`
- MCP server with `MEMO_DB_URL` — when you want the AI agent to have
  direct DB access independent of your app's auth layer

All three can coexist — they write to the same PostgreSQL tables.

---

## Per-project scopes

Run multiple MCP server instances pointing at the same `luamemo`
backend, each scoped to a different project:

```jsonc
{
  "mcpServers": {
    "memory-projectA": {
      "command": "lua",
      "args": ["/path/to/server.lua"],
      "env": { "MEMO_URL": "...", "MEMO_SCOPE": "repo:projectA" }
    },
    "memory-acme": {
      "command": "lua",
      "args": ["/path/to/server.lua"],
      "env": { "MEMO_URL": "...", "MEMO_SCOPE": "repo:acme" }
    }
  }
}
```

The model sees them as two independent tool sets.

---

## Troubleshooting

**"MEMO_URL env var is required"** — The `env` block in your client config
isn't being applied. Check the client's MCP logs (Claude Desktop has a
`Developer → MCP` panel).

**"empty response from server"** — Your `luamemo` API isn't reachable.
Test with `curl $MEMO_URL/recent` first.

**"invalid JSON response"** — The API returned HTML or plain text (likely
401/403/500). Run with `MEMO_DEBUG=1` and inspect stderr for the raw URL,
then hit it with `curl` directly.

**Tools don't appear in Claude Desktop** — Confirm `lua` is on the PATH
seen by Claude (it inherits the *login shell* PATH on macOS, not your
terminal's). Use an absolute path like `/usr/local/bin/lua` if needed.

---

## See also

- Project root: [`../README.md`](../README.md)
- MCP spec: <https://spec.modelcontextprotocol.io/>
