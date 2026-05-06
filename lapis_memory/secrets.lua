-- lapis_memory/secrets.lua
-- Encrypted secret storage for lapis-memory.
--
-- Secrets are stored AES-256-CBC encrypted at rest. The master key is NEVER
-- persisted in the database and NEVER returned to callers. The canonical
-- usage pattern is execute_with_secret(), which substitutes the decrypted
-- value server-side into HTTP requests without leaking it to the LLM.
--
-- Key resolution order (first match wins):
--   1. master_key_path  — path to a file containing the hex-encoded key
--                         (recommended; use a Docker secret or env file)
--   2. master_key_env   — name of an environment variable holding the key
--   3. master_key       — explicit key string in setup() config
--
-- Key format: 64 hex chars (= 32 bytes).  Generate with:
--   openssl rand -hex 32
--
-- When no key source is configured, secrets are "disabled": all write
-- operations return an error; list() returns an empty table; enabled()
-- returns false. The rest of lapis-memory works normally.

local aes  = require("resty.aes")
local rnd  = require("resty.random")
local rstr = require("resty.string")
local db   = require("lapis.db")

-- lua-resty-http is always available in OpenResty / lapis environments.
local http = require("resty.http")

local M = {}

-- Internal: resolved 32-byte binary key, nil when not configured.
local _key = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function from_hex(s)
    return (s:gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*all")
    f:close()
    return s
end

-- Parse a raw key string into a 32-byte binary key.
-- Accepts: 64-char hex string OR a raw 32-byte string.
local function parse_key(raw)
    if not raw then return nil, "nil key" end
    raw = raw:gsub("%s+", "")          -- strip whitespace / trailing newline
    if #raw == 64 and raw:match("^%x+$") then
        return from_hex(raw), nil      -- hex-encoded 32-byte key
    end
    if #raw == 32 then
        return raw, nil                -- raw 32-byte key
    end
    return nil, ("master key must be 32 bytes (raw) or 64 hex chars, got %d chars"):format(#raw)
end

local function _log_warn(msg)
    if type(ngx) == "table" and ngx.log and ngx.WARN then
        ngx.log(ngx.WARN, "lapis_memory secrets: ", msg)
    end
end

-- ---------------------------------------------------------------------------
-- configure (called from init.lua setup())
-- ---------------------------------------------------------------------------

--- Configure the secrets module.  Called automatically by M.setup().
--- Safe to call multiple times; the last successful key source wins.
--- @param config table  The global lapis_memory config table.
function M.configure(config)
    config = config or {}
    _key   = nil   -- reset on every configure so setup() can re-run cleanly

    -- Priority 1: file path (Docker secret, env file, …)
    if config.master_key_path then
        local raw = read_file(config.master_key_path)
        if raw then
            local k, err = parse_key(raw)
            if k then _key = k; return end
            _log_warn("master_key_path invalid: " .. err)
        end
    end

    -- Priority 2: env var (name, not value)
    if config.master_key_env then
        local raw = os.getenv(config.master_key_env)
        if raw then
            local k, err = parse_key(raw)
            if k then _key = k; return end
            _log_warn("master_key_env invalid: " .. err)
        end
    end

    -- Priority 3: explicit value in config (CI / dev only — not for prod)
    if config.master_key then
        local k, err = parse_key(config.master_key)
        if k then _key = k; return end
        _log_warn("master_key invalid: " .. err)
    end

    -- No key configured — secrets disabled.
end

--- Returns true when a master key was successfully resolved.
--- Routes + MCP tools check this before any operation.
function M.enabled()
    return _key ~= nil
end

-- ---------------------------------------------------------------------------
-- Encryption / decryption
-- AES-256-CBC with a random 8-byte salt per encryption (via EVP_BytesToKey,
-- matching the pattern used in helpers/sin_crypto.lua in the portfolio).
-- Stored format: "<16-char salt_hex>:<ciphertext_hex>"
-- ---------------------------------------------------------------------------

local function _encrypt(plaintext)
    if not _key then return nil, "secrets: master key not configured" end

    local salt = rnd.bytes(8, true) or rnd.bytes(8)
    if not salt then return nil, "secrets: failed to generate salt" end

    local cipher = aes:new(_key, salt, aes.cipher(256, "cbc"), aes.hash.sha256, 1)
    if not cipher then return nil, "secrets: cipher init failed" end

    local ct = cipher:encrypt(plaintext)
    if not ct then return nil, "secrets: encryption failed" end

    return rstr.to_hex(salt) .. ":" .. rstr.to_hex(ct)
end

local function _decrypt(stored)
    if not _key then return nil, "secrets: master key not configured" end

    local salt_hex, ct_hex = stored:match("^([0-9a-fA-F]+):([0-9a-fA-F]+)$")
    if not salt_hex or not ct_hex then
        return nil, "secrets: invalid stored ciphertext format"
    end

    local salt = from_hex(salt_hex)
    local ct   = from_hex(ct_hex)

    local cipher = aes:new(_key, salt, aes.cipher(256, "cbc"), aes.hash.sha256, 1)
    if not cipher then return nil, "secrets: cipher init failed on decrypt" end

    local pt = cipher:decrypt(ct)
    if not pt then return nil, "secrets: decryption failed (wrong key or corrupt data)" end

    return pt
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

--- Name validation: alphanumeric, hyphens, underscores, dots; max 128 chars.
local function valid_name(name)
    if type(name) ~= "string" or name == "" then return false end
    if #name > 128 then return false end
    return name:match("^[%w%.%-_]+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Store (create or update) a secret by name.
--- The value is encrypted before writing; the plaintext is never persisted.
---
--- @param name        string   Unique secret identifier
--- @param value       string   Plaintext secret value
--- @param description string?  Optional human-readable description
--- @return table|nil  Row: {id, name, description, created_at, updated_at, last_used_at, used_count}
--- @return string|nil Error message
function M.store(name, value, description)
    if not M.enabled() then
        return nil, "secrets: not configured (no master_key)"
    end
    if not valid_name(name) then
        return nil, "secrets: name must be alphanumeric / hyphen / underscore / dot, max 128 chars"
    end
    if type(value) ~= "string" or value == "" then
        return nil, "secrets: value must be a non-empty string"
    end

    local ciphertext, err = _encrypt(value)
    if not ciphertext then return nil, err end

    local rows, qerr = db.query([[
        INSERT INTO lm_secrets (name, ciphertext, description)
        VALUES (?, ?, ?)
        ON CONFLICT (name) DO UPDATE
            SET ciphertext  = EXCLUDED.ciphertext,
                description = COALESCE(EXCLUDED.description, lm_secrets.description),
                updated_at  = now()
        RETURNING id, name, description, created_at, updated_at,
                  last_used_at, used_count
    ]], name, ciphertext, description or db.NULL)

    if not rows then return nil, "secrets: db error: " .. tostring(qerr) end
    return rows[1]
end

--- Permanently delete a secret.
---
--- @param name  string  Secret name
--- @return bool   true on success
--- @return string|nil  Error message ("not found" or DB error)
function M.delete(name)
    if not M.enabled() then
        return nil, "secrets: not configured (no master_key)"
    end
    if not valid_name(name) then return nil, "secrets: invalid name" end

    local rows, err = db.query(
        "DELETE FROM lm_secrets WHERE name = ? RETURNING id", name)
    if not rows then return false, "secrets: db error: " .. tostring(err) end
    if #rows == 0 then return false, "secrets: not found: " .. name end
    return true
end

--- List all secrets.  Returns names and metadata ONLY — values are never
--- included in the response.
---
--- @return table[]  {id, name, description, created_at, updated_at, last_used_at, used_count}[]
function M.list()
    if not M.enabled() then return {} end

    local rows = db.query([[
        SELECT id, name, description, created_at, updated_at,
               last_used_at, used_count
        FROM lm_secrets
        ORDER BY name ASC
    ]])
    return rows or {}
end

-- ---------------------------------------------------------------------------
-- execute_with_secret
-- ---------------------------------------------------------------------------
-- Substitutes {secret} in a URL / headers / body template server-side, makes
-- the HTTP request, and returns only the response body.  The decrypted value
-- is held in a local variable that does not cross the LLM context boundary.
-- ---------------------------------------------------------------------------

local function _substitute(template, secret_value)
    if type(template) ~= "string" then return template end
    return (template:gsub("{secret}", secret_value))
end

--- Execute an HTTP request with the secret substituted server-side.
--- {secret} is replaced in url, header values, and body — never returned.
---
--- @param name  string  Secret name to look up
--- @param opts  table   {
---   url        string   Request URL (may contain {secret})
---   method     string?  HTTP verb; default "GET"
---   headers    table?   Header map; any value may contain {secret}
---   body       string?  Request body; may contain {secret}
---   timeout_ms number?  Request timeout in ms; default 10000
--- }
--- @return string|nil  Response body (raw string)
--- @return string|nil  Error message
function M.execute_with_secret(name, opts)
    if not M.enabled() then
        return nil, "secrets: not configured (no master_key)"
    end
    if not valid_name(name) then
        return nil, "secrets: invalid name"
    end
    opts = opts or {}
    if type(opts.url) ~= "string" or opts.url == "" then
        return nil, "secrets: execute_with_secret requires opts.url"
    end

    -- Fetch ciphertext from DB.
    local rows, qerr = db.query(
        "SELECT ciphertext FROM lm_secrets WHERE name = ?", name)
    if not rows then
        return nil, "secrets: db error: " .. tostring(qerr)
    end
    if #rows == 0 then
        return nil, "secrets: not found: " .. name
    end

    -- Decrypt.  value is a local — it does not leave this function.
    local value, derr = _decrypt(rows[1].ciphertext)
    if not value then return nil, derr end

    -- Substitute {secret} in URL, header values, and body.
    local url    = _substitute(opts.url, value)
    local method = ((opts.method or "GET"):upper())

    local req_headers = {}
    if opts.headers then
        for k, v in pairs(opts.headers) do
            req_headers[k] = _substitute(tostring(v), value)
        end
    end

    local req_body = opts.body and _substitute(opts.body, value) or nil

    -- Zero out the value from local scope as early as possible.
    value = nil  -- luacheck: ignore

    -- Perform the HTTP request.
    local httpc, herr = http.new()
    if not httpc then
        return nil, "secrets: failed to create http client: " .. tostring(herr)
    end
    local timeout = tonumber(opts.timeout_ms) or 10000
    httpc:set_timeout(timeout)

    local res, rerr = httpc:request_uri(url, {
        method  = method,
        headers = req_headers,
        body    = req_body,
    })

    -- Bump usage tracking (best-effort; ignore errors).
    pcall(db.query, [[
        UPDATE lm_secrets
           SET last_used_at = now(), used_count = used_count + 1
         WHERE name = ?
    ]], name)

    if not res then
        return nil, "secrets: http request failed: " .. tostring(rerr)
    end

    return res.body, nil
end

return M
