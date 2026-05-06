-- lapis_memory/secrets.lua
-- Encrypted secret storage for lapis-memory.
--
-- Secrets are stored AES-256-CBC encrypted in a local JSON file.
-- No database table is required — the file is the store.
--
-- Activation: set config.secrets_file to a writable path.
-- If secrets_file is not configured, all write operations return a
-- graceful error and execute_with_secret is disabled.  The rest of
-- lapis-memory works normally.
--
-- File format: { "v": 1, "secrets": { [name]: { ciphertext, description,
--   created_at, updated_at, last_used_at, used_count } } }
-- Writes are atomic: write to <path>.tmp then os.rename().
--
-- Master key resolution order (first match wins):
--   1. master_key_path  -- path to a file containing the hex-encoded key
--                          (recommended; use a Docker secret or env file)
--   2. master_key_env   -- name of an environment variable holding the key
--   3. master_key       -- explicit key string in setup() config
--
-- Key format: 64 hex chars (= 32 bytes).  Generate with:
--   openssl rand -hex 32
--
-- When neither key nor file path is configured, all write operations return
-- an error; list() returns an empty table; enabled() returns false.

local aes   = require("resty.aes")
local rnd   = require("resty.random")
local rstr  = require("resty.string")
local cjson = require("cjson.safe")
-- resty.http is lazy-required inside execute_with_secret to avoid
-- loading resty.http_connect outside of a request context in OpenResty.

local M = {}

-- Internal state: resolved 32-byte binary key and file path.
local _key       = nil
local _file_path = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function from_hex(s)
    return (s:gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function _read_file(path)
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
    raw = raw:gsub("%s+", "")
    if #raw == 64 and raw:match("^%x+$") then
        return from_hex(raw), nil
    end
    if #raw == 32 then
        return raw, nil
    end
    return nil, ("master key must be 32 bytes (raw) or 64 hex chars, got %d chars"):format(#raw)
end

local function _log_warn(msg)
    if type(ngx) == "table" and ngx.log and ngx.WARN then
        ngx.log(ngx.WARN, "lapis_memory secrets: ", msg)
    end
end

-- ---------------------------------------------------------------------------
-- File-based store helpers
-- ---------------------------------------------------------------------------

-- Read and parse the JSON store file.
-- Returns an empty store when the file does not yet exist.
local function load_store()
    if not _file_path then
        return nil, "secrets: secrets_file not configured"
    end
    local raw = _read_file(_file_path)
    if not raw then
        return { v = 1, secrets = {} }
    end
    local store, err = cjson.decode(raw)
    if not store then
        return nil, "secrets: corrupt store file: " .. tostring(err)
    end
    store.secrets = store.secrets or {}
    return store
end

-- Atomic write: write to <path>.tmp then os.rename() into place.
local function save_store(store)
    if not _file_path then
        return nil, "secrets: secrets_file not configured"
    end
    local data, err = cjson.encode(store)
    if not data then return nil, "secrets: json encode failed: " .. tostring(err) end
    local tmp = _file_path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return nil, "secrets: cannot write to " .. tmp end
    f:write(data)
    f:close()
    local ok = os.rename(tmp, _file_path)
    if not ok then
        return nil, "secrets: rename failed (" .. tmp .. " -> " .. _file_path .. ")"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- configure (called from init.lua setup())
-- ---------------------------------------------------------------------------

--- Configure the secrets module.  Called automatically by M.setup().
--- Safe to call multiple times; the last successful key source wins.
--- @param config table  The global lapis_memory config table.
function M.configure(config)
    config     = config or {}
    _key       = nil
    _file_path = config.secrets_file or nil

    if config.master_key_path then
        local raw = _read_file(config.master_key_path)
        if raw then
            local k, err = parse_key(raw)
            if k then _key = k; return end
            _log_warn("master_key_path invalid: " .. err)
        end
    end

    if config.master_key_env then
        local raw = os.getenv(config.master_key_env)
        if raw then
            local k, err = parse_key(raw)
            if k then _key = k; return end
            _log_warn("master_key_env invalid: " .. err)
        end
    end

    if config.master_key then
        local k, err = parse_key(config.master_key)
        if k then _key = k; return end
        _log_warn("master_key invalid: " .. err)
    end
end

--- Returns true when both a master key and a secrets file path are configured.
function M.enabled()
    return _key ~= nil and _file_path ~= nil
end

-- ---------------------------------------------------------------------------
-- Encryption / decryption
-- AES-256-CBC with a random 8-byte salt per encryption.
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

local function valid_name(name)
    if type(name) ~= "string" or name == "" then return false end
    if #name > 128 then return false end
    return name:match("^[%w%.%-_]+$") ~= nil
end

local function now_iso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Store (create or update) a secret by name.
--- @param name        string   Unique secret identifier
--- @param value       string   Plaintext secret value
--- @param description string?  Optional human-readable description
--- @return table|nil  {name, description, created_at, updated_at}
--- @return string|nil Error message
function M.store(name, value, description)
    if not _file_path then
        return nil, "secrets: not configured (secrets_file not set)"
    end
    if not _key then
        return nil, "secrets: not configured (no master_key)"
    end
    if not valid_name(name) then
        return nil, "secrets: name must be alphanumeric / hyphen / underscore / dot, max 128 chars"
    end
    if type(value) ~= "string" or value == "" then
        return nil, "secrets: value must be a non-empty string"
    end

    local ciphertext, cerr = _encrypt(value)
    if not ciphertext then return nil, cerr end

    local store, serr = load_store()
    if not store then return nil, serr end

    local now      = now_iso()
    local existing = store.secrets[name]

    store.secrets[name] = {
        ciphertext   = ciphertext,
        description  = description or (existing and existing.description) or cjson.null,
        created_at   = (existing and existing.created_at) or now,
        updated_at   = now,
        last_used_at = (existing and existing.last_used_at) or cjson.null,
        used_count   = (existing and existing.used_count)  or 0,
    }

    local ok, werr = save_store(store)
    if not ok then return nil, werr end

    local s = store.secrets[name]
    return { name = name, description = s.description,
             created_at = s.created_at, updated_at = s.updated_at }
end

--- Permanently delete a secret.
--- @param name  string  Secret name
--- @return bool   true on success
--- @return string|nil  Error message
function M.delete(name)
    if not M.enabled() then return nil, "secrets: not configured" end
    if not valid_name(name) then return nil, "secrets: invalid name" end

    local store, err = load_store()
    if not store then return false, err end

    if not store.secrets[name] then
        return false, "secrets: not found: " .. name
    end

    store.secrets[name] = nil

    local ok, werr = save_store(store)
    if not ok then return false, werr end
    return true
end

--- List all secrets.  Returns names and metadata — values are never included.
--- @return table[]  {name, description, created_at, updated_at, last_used_at, used_count}[]
function M.list()
    local store = load_store()
    if not store then return {} end
    local out = {}
    for name, s in pairs(store.secrets) do
        table.insert(out, {
            name         = name,
            description  = s.description,
            created_at   = s.created_at,
            updated_at   = s.updated_at,
            last_used_at = s.last_used_at,
            used_count   = s.used_count,
        })
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ---------------------------------------------------------------------------
-- execute_with_secret
-- Substitutes {secret} in URL / headers / body server-side and makes the
-- HTTP request.  The decrypted value never leaves this function.
-- ---------------------------------------------------------------------------

local function _substitute(template, secret_value)
    if type(template) ~= "string" then return template end
    return (template:gsub("{secret}", secret_value))
end

--- Execute an HTTP request with the secret substituted server-side.
--- @param name  string  Secret name to look up
--- @param opts  table   { url, method?, headers?, body?, timeout_ms? }
--- @return string|nil  Response body
--- @return string|nil  Error message
function M.execute_with_secret(name, opts)
    if not M.enabled() then return nil, "secrets: not configured" end
    if not valid_name(name) then return nil, "secrets: invalid name" end
    opts = opts or {}
    if type(opts.url) ~= "string" or opts.url == "" then
        return nil, "secrets: execute_with_secret requires opts.url"
    end

    local store, serr = load_store()
    if not store then return nil, serr end

    local entry = store.secrets[name]
    if not entry then return nil, "secrets: not found: " .. name end

    local value, derr = _decrypt(entry.ciphertext)
    if not value then return nil, derr end

    local url    = _substitute(opts.url, value)
    local method = (opts.method or "GET"):upper()

    local req_headers = {}
    if opts.headers then
        for k, v in pairs(opts.headers) do
            req_headers[k] = _substitute(tostring(v), value)
        end
    end
    local req_body = opts.body and _substitute(opts.body, value) or nil

    value = nil  -- luacheck: ignore  (zero out before any I/O)

    -- Update usage tracking (best-effort).
    local now = now_iso()
    entry.last_used_at = now
    entry.used_count   = (entry.used_count or 0) + 1
    pcall(save_store, store)

    local http, herr = require("resty.http").new()
    if not http then
        return nil, "secrets: failed to create http client: " .. tostring(herr)
    end
    http:set_timeout(tonumber(opts.timeout_ms) or 10000)

    local res, rerr = http:request_uri(url, {
        method  = method,
        headers = req_headers,
        body    = req_body,
    })
    if not res then
        return nil, "secrets: http request failed: " .. tostring(rerr)
    end

    return res.body, nil
end

return M
