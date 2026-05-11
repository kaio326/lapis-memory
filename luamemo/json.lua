-- luamemo/json.lua
--
-- Portable JSON shim.
--
-- Tries cjson.safe first (always present in OpenResty; often installed in
-- plain-Lua environments).  Falls back to the bundled pure-Lua dkjson when
-- cjson is not available, so `luarocks install luamemo` never fails because
-- of a missing C compiler.
--
-- Public API (identical regardless of backend):
--   json.encode(value)          → string, raises on unencodable value
--   json.decode(str)            → value  (or nil, err_string on bad JSON)
--   json.null                   → sentinel for explicit JSON null
--
-- SHA-256 of bundled dkjson 2.5 (LuaDist copy):
--   9d3e5c82dcd572a6a4b764d705f72b948094124b0e338cec0d6dfefea59693b7

local M = {}

-- ── Try cjson.safe first ──────────────────────────────────────────────────
local ok, cjson_safe = pcall(require, "cjson.safe")
if ok and type(cjson_safe) == "table" then
    -- cjson.safe.decode already returns nil, err on bad JSON (never raises).
    M.encode = cjson_safe.encode
    M.decode = cjson_safe.decode
    M.null   = cjson_safe.null
    return M
end

-- ── Fallback: bundled dkjson (pure Lua, MIT) ─────────────────────────────
local dkjson = require("luamemo.vendor.dkjson")

-- json.null: use dkjson's own sentinel so decode returns it for JSON nulls.
M.null = dkjson.null

-- encode: dkjson.encode raises on unencodable value — matches cjson default.
function M.encode(value)
    return dkjson.encode(value)
end

-- decode: dkjson.decode returns (value, next_pos) on success and
-- (nil, pos, err_string) on failure.  Wrap to the cjson.safe signature:
-- returns value on success, nil + err_string on failure, never raises.
function M.decode(str)
    if type(str) ~= "string" then
        return nil, "json.decode: expected string, got " .. type(str)
    end
    local val, _, err = dkjson.decode(str, 1, dkjson.null)
    if err then
        return nil, err
    end
    return val
end

return M
