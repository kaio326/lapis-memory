-- eval/utils.lua
-- Utility modules for eval harnesses.
--
-- M.variants(text, n) → {string, ...}
--   Deterministic adversarial paraphrase generator for recall_bench.
--   Produces N variants per input string by chaining cheap transforms:
--
--     v1  synonym swap   — replace a small fixed set of common nouns/
--                          verbs/qualifiers with synonyms.
--     v2  reorder flip   — move trailing prepositional phrases to the
--                          front, or swap subject/object phrasing.
--     v3  drop function  — strip a small set of non-content words.
--
--   All transforms are deterministic and pure-Lua; no LLM calls.
--
-- Callers:
--   local pp = require("utils")
--   local variants = pp.variants(text, 3)

local M = {}

-- Small synonym table. Keys must be lowercase.
local SYN = {
    -- nouns
    ["address"]    = "location",
    ["car"]        = "vehicle",
    ["job"]        = "position",
    ["company"]    = "employer",
    ["doctor"]     = "physician",
    ["meeting"]    = "appointment",
    ["movie"]      = "film",
    ["restaurant"] = "diner",
    ["house"]      = "home",
    ["place"]      = "location",
    -- verbs
    ["bought"]     = "purchased",
    ["buy"]        = "purchase",
    ["got"]        = "received",
    ["get"]        = "receive",
    ["told"]       = "informed",
    ["said"]       = "stated",
    ["saw"]        = "witnessed",
    ["went"]       = "traveled",
    ["like"]       = "enjoy",
    ["likes"]      = "enjoys",
    ["want"]       = "desire",
    ["wants"]      = "desires",
    -- qualifiers
    ["big"]        = "large",
    ["small"]      = "tiny",
    ["fast"]       = "quick",
    ["good"]       = "great",
    ["bad"]        = "poor",
    ["happy"]      = "pleased",
}

-- Function words to drop (never drop content words).
local DROP = {
    ["the"]  = true, ["a"] = true, ["an"] = true, ["of"] = true,
    ["is"]   = true, ["do"] = true, ["did"] = true,
    ["have"] = true, ["had"] = true, ["has"] = true,
    ["you"]  = true, ["i"] = true,  ["my"] = true,
    ["that"] = true, ["this"] = true,
}

local function tokenize(s)
    local out = {}
    for word, sep in s:gmatch("([%w']+)(%s*[%p]?%s*)") do
        out[#out + 1] = { text = word, is_word = true }
        if sep ~= "" then
            out[#out + 1] = { text = sep, is_word = false }
        end
    end
    return out
end

local function detok(toks)
    local buf = {}
    for _, t in ipairs(toks) do buf[#buf + 1] = t.text end
    return table.concat(buf)
end

local function preserve_case(orig, replacement)
    if orig:sub(1, 1):match("%u") then
        return replacement:sub(1, 1):upper() .. replacement:sub(2)
    end
    return replacement
end

local function synonym_swap(text)
    local toks = tokenize(text)
    local changed = false
    for _, t in ipairs(toks) do
        if t.is_word then
            local syn = SYN[t.text:lower()]
            if syn then
                t.text  = preserve_case(t.text, syn)
                changed = true
            end
        end
    end
    if not changed then return "Specifically, " .. text end
    return detok(toks)
end

local function reorder(text)
    local body, punct = text:match("^(.-)([%.%?%!]?)$")
    body  = body or text
    punct = punct or ""
    local s, e, seg
    for _, prep in ipairs({ "in", "on", "at", "from", "with" }) do
        local pat = "%s+(" .. prep .. "%s+[%w%s,'\"]+)$"
        local s2, e2, cap = body:find(pat)
        if s2 and (not s or s2 > s) then s, e, seg = s2, e2, cap end
        local Pat = "%s+(" .. prep:sub(1,1):upper() .. prep:sub(2)
            .. "%s+[%w%s,'\"]+)$"
        local s3, e3, cap3 = body:find(Pat)
        if s3 and (not s or s3 > s) then s, e, seg = s3, e3, cap3 end
    end
    if s then
        local lhs   = body:sub(1, s - 1)
        local moved = seg:sub(1, 1):upper() .. seg:sub(2)
        return moved .. ", " .. lhs:sub(1, 1):lower() .. lhs:sub(2) .. punct
    end
    return "Regarding the topic, " .. text
end

local function drop_function_words(text)
    local toks = tokenize(text)
    local out  = {}
    local dropped = 0
    for _, t in ipairs(toks) do
        if t.is_word and DROP[t.text:lower()] then
            dropped = dropped + 1
        else
            out[#out + 1] = t
        end
    end
    if dropped == 0 then return "Note: " .. text end
    local result = detok(out):gsub("%s+", " ")
    return (result:gsub("^%s+", ""):gsub("%s+$", ""))
end

local TRANSFORMS = { synonym_swap, reorder, drop_function_words }

-- Generate `n` deterministic variants.  Cycles through TRANSFORMS in
-- order; for n > 3, variants 4+ are applied to the previous variant.
function M.variants(text, n)
    n = n or 3
    if n <= 0 then return {} end
    local out  = {}
    local prev = text
    for i = 1, n do
        local t = TRANSFORMS[((i - 1) % #TRANSFORMS) + 1]
        local v = t(prev)
        if v == prev then v = "Specifically, " .. v end
        out[#out + 1] = v
        prev = v
    end
    return out
end

return M
