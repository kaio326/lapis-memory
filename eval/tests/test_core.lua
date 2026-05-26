-- eval/tests/test_core.lua
-- Merged core DB tests:
--   Section 1: Bruteforce   (write / dedup / search, both backends)
--   Section 2: Write-Many   (batched ingest via memory.write_many)
--   Section 3: Tiers        (Plan 10 memory-tier derivation + search filtering)
--   Section 4: Promote      (memory.promote session-continuity helper)
--   Section 5: Decay+Dedup+Summary (decay ranking, dedup merge, summarizer compaction)
--
-- Usage:
--   MEMO_DB_URL=postgresql://postgres:postgres@127.0.0.1:5432/luamemo_dev \
--     lua5.1 eval/tests/test_core.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db     = require("luamemo.db")
local memory = require("luamemo")

local pass = 0
local fail = 0

local function check(label, ok, detail)
    if ok then
        io.write("[PASS] " .. label .. "\n")
        pass = pass + 1
    else
        io.write("[FAIL] " .. label .. (detail and (" — " .. detail) or "") .. "\n")
        fail = fail + 1
    end
end

local function header(s)
    io.write(string.format("\n=== %s ===\n", s))
end

-- =========================================================================
-- Section 1: Bruteforce / write / dedup / search
-- =========================================================================
header("Bruteforce — write / dedup / search")

memory.setup({
    db_table       = "lm_memories",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",
    default_scope  = "smoke",
    auth_fn        = function() return true end,
})
io.write("resolved backend = " .. tostring(memory.store.backend()) .. "\n")

db.query("DELETE FROM lm_memories WHERE scope = 'smoke'")

do
    local seeds = {
        { title = "How to deploy with Docker", body = "Run docker compose up to start the stack." },
        { title = "PostgreSQL backup strategy", body = "Use pg_dump nightly and ship to S3." },
        { title = "Cache invalidation guide", body = "Flush profile_cache after profile updates." },
        { title = "JWT vs sessions", body = "We use sessions because of CSRF and revocation." },
        { title = "T2125 expense categories", body = "Meals at 50%, motor vehicle, home office." },
    }
    for i, s in ipairs(seeds) do
        local row, err, action = memory.write({
            scope = "smoke", kind = "fact", title = s.title, body = s.body,
        })
        check("write seed " .. i, row ~= nil, tostring(err))
        check("seed " .. i .. " action=inserted", action == "inserted",
            "got " .. tostring(action))
    end

    local dup, derr, daction = memory.write({
        scope = "smoke", kind = "fact",
        title = "How to deploy with Docker",
        body  = "Run docker compose up to start the stack.",
    })
    check("near-duplicate: row returned", dup ~= nil, tostring(derr))
    check("near-duplicate: action=merged", daction == "merged", "got " .. tostring(daction))

    local app, aerr, aaction = memory.write({
        scope = "smoke", kind = "fact",
        title = "How to deploy with Docker",
        body  = "Run docker compose up to start the stack.",
        dedup_strategy = "append",
    })
    check("force append: row returned", app ~= nil, tostring(aerr))
    check("force append: action=inserted", aaction == "inserted", "got " .. tostring(aaction))

    local results, serr = memory.search({
        query = "docker deploy command", scope = "smoke", limit = 3,
    })
    check("search semantic: results returned", results ~= nil and #results > 0, tostring(serr))
    check("search semantic: top result mentions Docker",
        results ~= nil and results[1] ~= nil and results[1].title:find("Docker") ~= nil)
    check("search: embedding column stripped",
        results ~= nil and results[1] ~= nil and results[1].embedding == nil)

    local results2 = memory.search({ query = "T2125 meals", scope = "smoke", limit = 3 })
    check("search lexical: T2125 is top result",
        results2 ~= nil and results2[1] ~= nil and results2[1].title:find("T2125") ~= nil)

    local recents = memory.recent({ scope = "smoke", limit = 10 })
    check("recent: >= 6 rows total", recents ~= nil and #recents >= 6, tostring(#(recents or {})))
end

-- =========================================================================
-- Section 2: Write-Many
-- =========================================================================
header("Write-Many")

memory.setup({
    db_table        = "lm_memories",
    embedder_local  = "hash",
    embed_dim       = 384,
    backend         = "auto",
    default_scope   = "smoke_wm",
    dedup_enabled   = true,
    dedup_threshold = 0.95,
    auth_fn         = function() return true end,
})

db.query("DELETE FROM lm_memories WHERE scope LIKE 'smoke_wm%'")

do
    -- Happy path: 5 rows in single chunk
    local batch = {}
    for i = 1, 5 do
        batch[i] = {
            scope = "smoke_wm", kind = "fact",
            title = "row " .. i,
            body  = "body content number " .. i .. " with unique tokens " .. i .. i .. i,
        }
    end
    local results, err = memory.write_many(batch, { batch_size = 100 })
    check("write_many happy path: no error", err == nil, tostring(err))
    check("write_many happy path: 5 results", results ~= nil and #results == 5,
        tostring(results and #results))
    if results then
        for i, r in ipairs(results) do
            check("write_many row " .. i .. " inserted",
                r.row ~= nil and r.action == "inserted",
                "action=" .. tostring(r.action) .. " err=" .. tostring(r.error))
            check("write_many row " .. i .. " title preserved",
                r.row ~= nil and r.row.title == "row " .. i)
        end
    end

    -- Multi-chunk: 12 rows with batch_size=5
    db.query("DELETE FROM lm_memories WHERE scope = 'smoke_wm'")
    local big = {}
    for i = 1, 12 do
        big[i] = { scope = "smoke_wm", kind = "fact",
            title = "B" .. i, body = "distinct body " .. i .. " " .. (i * 17) }
    end
    results, err = memory.write_many(big, { batch_size = 5 })
    check("write_many multi-chunk: no error", err == nil, tostring(err))
    check("write_many multi-chunk: 12 results", results ~= nil and #results == 12,
        tostring(results and #results))
    if results then
        for i, r in ipairs(results) do
            check("write_many chunk row " .. i .. " title=B" .. i,
                r.row ~= nil and r.row.title == "B" .. i)
        end
    end

    -- Mixed validation errors
    db.query("DELETE FROM lm_memories WHERE scope = 'smoke_wm'")
    local mixed = {
        { scope = "smoke_wm", kind = "fact", title = "good 1", body = "alpha aaa" },
        { scope = "smoke_wm", kind = "fact", title = "",       body = "" },
        { scope = "smoke_wm", kind = "fact", title = "good 2", body = "beta bbb" },
        "not a table",
        { scope = "smoke_wm", kind = "fact", title = "good 3", body = "gamma ccc",
          importance = 99 },
        { scope = "smoke_wm", kind = "fact", title = "good 4", body = "delta ddd" },
    }
    results, err = memory.write_many(mixed)
    check("write_many mixed: no abort error", err == nil, tostring(err))
    check("write_many mixed: 6 results", results ~= nil and #results == 6,
        tostring(results and #results))
    if results then
        local ok_count, err_count = 0, 0
        for _, r in ipairs(results) do
            if r.row then ok_count = ok_count + 1 else err_count = err_count + 1 end
        end
        check("write_many mixed: 3 ok", ok_count == 3, "got " .. ok_count)
        check("write_many mixed: 3 err", err_count == 3, "got " .. err_count)
    end

    -- Dedup skip
    db.query("DELETE FROM lm_memories WHERE scope = 'smoke_wm'")
    local seed = memory.write({ scope = "smoke_wm", kind = "fact",
        title = "Postgres backup strategy",
        body  = "Use pg_dump nightly and ship to S3 with retention." })
    check("write_many dedup: seed written", seed ~= nil)
    local skip_batch = {
        { scope = "smoke_wm", kind = "fact",
          title = "Postgres backup strategy",
          body  = "Use pg_dump nightly and ship to S3 with retention." },
        { scope = "smoke_wm", kind = "fact",
          title = "Cache invalidation",
          body  = "Flush profile_cache after profile mutations." },
    }
    results, err = memory.write_many(skip_batch, { dedup_strategy = "skip" })
    check("write_many dedup: no error", err == nil, tostring(err))
    check("write_many dedup: 2 results", results ~= nil and #results == 2)
    check("write_many dedup: first=skipped",
        results ~= nil and results[1] ~= nil and results[1].action == "skipped",
        tostring(results and results[1] and results[1].action))
    check("write_many dedup: second=inserted",
        results ~= nil and results[2] ~= nil and results[2].action == "inserted",
        tostring(results and results[2] and results[2].action))
end

-- =========================================================================
-- Section 3: Tiers
-- =========================================================================
header("Tiers")

memory.setup({
    db_table          = "lm_memories",
    embedder_local    = "hash",
    embed_dim         = 384,
    backend           = "auto",
    default_scope     = "smoke:tiers",
    auth_fn           = function() return true end,
    summarizer_adapter = "noop",
    skip_observations = true,
})

local TIERS_SCOPE = "smoke:tiers"
db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(TIERS_SCOPE))

do
    -- Migration check
    local col_check = db.query([[
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'lm_memories'
           AND column_name = 'tier' LIMIT 1]])
    local tiers_ok = col_check and #col_check > 0
    check("tiers: lm_memories.tier column exists (migration 008)", tiers_ok,
        "apply luamemo/migrations/008_tiers.sql")

    if tiers_ok then
        -- Auto tier from importance
        local r0 = memory.write({ scope = TIERS_SCOPE, body = "ephemeral event A", importance = 0.2 })
        check("tiers: importance=0.2 → tier=0",
            r0 ~= nil and tonumber(r0.tier) == 0, "tier=" .. tostring(r0 and r0.tier))

        local r1 = memory.write({ scope = TIERS_SCOPE, body = "working memory B", importance = 0.5 })
        check("tiers: importance=0.5 → tier=1",
            r1 ~= nil and tonumber(r1.tier) == 1, "tier=" .. tostring(r1 and r1.tier))

        local r2 = memory.write({ scope = TIERS_SCOPE, body = "consolidated fact C", importance = 0.7 })
        check("tiers: importance=0.7 → tier=2",
            r2 ~= nil and tonumber(r2.tier) == 2, "tier=" .. tostring(r2 and r2.tier))

        local r3 = memory.write({ scope = TIERS_SCOPE, body = "core decision D", importance = 1.5 })
        check("tiers: importance=1.5 → tier=3",
            r3 ~= nil and tonumber(r3.tier) == 3, "tier=" .. tostring(r3 and r3.tier))

        -- Explicit override
        local ro = memory.write({
            scope = TIERS_SCOPE, body = "manually tier 2",
            importance = 0.2, tier = 2,
        })
        check("tiers: explicit tier=2 overrides importance-derived tier=0",
            ro ~= nil and tonumber(ro.tier) == 2, "tier=" .. tostring(ro and ro.tier))

        -- write_many tier derivation
        local wm_results = memory.write_many({
            { scope = TIERS_SCOPE, body = "batch ephemeral", importance = 0.1 },
            { scope = TIERS_SCOPE, body = "batch working",   importance = 0.4 },
            { scope = TIERS_SCOPE, body = "batch core",      importance = 2.0 },
        }, { dedup_strategy = "append" })
        check("tiers write_many: 3 results", #wm_results == 3)
        check("tiers write_many: ephemeral tier=0",
            wm_results[1].row ~= nil and tonumber(wm_results[1].row.tier) == 0,
            "tier=" .. tostring(wm_results[1].row and wm_results[1].row.tier))
        check("tiers write_many: working tier=1",
            wm_results[2].row ~= nil and tonumber(wm_results[2].row.tier) == 1,
            "tier=" .. tostring(wm_results[2].row and wm_results[2].row.tier))
        check("tiers write_many: core tier=3",
            wm_results[3].row ~= nil and tonumber(wm_results[3].row.tier) == 3,
            "tier=" .. tostring(wm_results[3].row and wm_results[3].row.tier))

        -- Search tier_min filtering
        local all_rows = memory.search({ query = "memory", scope = TIERS_SCOPE,
            limit = 20, skip_observations = true })
        check("tiers search: rows returned", all_rows ~= nil and #all_rows >= 1)

        local tier1_rows = memory.search({ query = "memory", scope = TIERS_SCOPE,
            limit = 20, tier_min = 1, skip_observations = true })
        local has_tier0 = false
        for _, r in ipairs(tier1_rows or {}) do
            if tonumber(r.tier) == 0 then has_tier0 = true end
        end
        check("tiers search tier_min=1: no tier=0 rows", not has_tier0)

        local tier3_rows = memory.search({ query = "memory", scope = TIERS_SCOPE,
            limit = 20, tier_min = 3, skip_observations = true })
        local all_tier3 = tier3_rows ~= nil and #tier3_rows >= 1
        for _, r in ipairs(tier3_rows or {}) do
            if tonumber(r.tier) ~= 3 then all_tier3 = false end
        end
        check("tiers search tier_min=3: only tier=3", all_tier3)

        -- tier_max filtering
        local tier0only = memory.search({ query = "memory", scope = TIERS_SCOPE,
            limit = 20, tier_max = 0, skip_observations = true })
        local has_above0 = false
        for _, r in ipairs(tier0only or {}) do
            if tonumber(r.tier) ~= 0 then has_above0 = true end
        end
        check("tiers search tier_max=0: only tier=0 rows",
            tier0only ~= nil and #tier0only >= 1 and not has_above0)

        -- Tier field in returned rows
        check("tiers: tier field present in write() row", r3 ~= nil and r3.tier ~= nil)
        check("tiers: tier field is a number",
            r3 ~= nil and type(tonumber(r3.tier)) == "number")
    end

    db.query("DELETE FROM lm_memories WHERE scope = " .. db.escape_literal(TIERS_SCOPE))
end

-- =========================================================================
-- Section 4: Promote
-- =========================================================================
header("Promote")

memory.setup({
    db_table          = "lm_memories",
    embedder_local    = "hash",
    embed_dim         = 384,
    backend           = "auto",
    default_scope     = "session:phase12",
    auth_fn           = function() return true end,
    summarizer_adapter = "noop",
})

local FROM = "session:phase12"
local TO   = "user:phase12:lt"

db.query("DELETE FROM lm_memories WHERE scope IN ("
    .. db.escape_literal(FROM) .. ", " .. db.escape_literal(TO) .. ")")

do
    local seed_bodies = {
        "user asked about deploy workflow",
        "explained main vs production branch model",
        "noted db_migration.sql is idempotent",
        "user wants ssh-key-based deploys",
        "wrapped up: deploy via merge to production",
    }
    for _, b in ipairs(seed_bodies) do
        local row = memory.write({ scope = FROM, body = b })
        check("promote seed: " .. b:sub(1, 30), row ~= nil)
    end

    -- dry_run
    local r1 = memory.promote({ from_scope = FROM, to_scope = TO, dry_run = true })
    check("promote case1: dry_run promoted=1",
        r1 ~= nil and r1.promoted == 1, "promoted=" .. tostring(r1 and r1.promoted))
    check("promote case1: dry_run flag set", r1 ~= nil and r1.dry_run == true)
    check("promote case1: dry_run source_ids=5",
        r1 ~= nil and r1.source_ids ~= nil and #r1.source_ids == 5,
        tostring(r1 and r1.source_ids and #r1.source_ids))
    local after_dry = db.query("SELECT count(*) AS n FROM lm_memories WHERE scope = "
        .. db.escape_literal(TO))[1]
    check("promote case1: dry_run no DB mutation", tonumber(after_dry.n) == 0,
        "rows written=" .. tostring(after_dry.n))

    -- Real promote, keep source
    local r2 = memory.promote({ from_scope = FROM, to_scope = TO, delete_source = false })
    check("promote case2: promoted=1", r2 ~= nil and r2.promoted == 1)
    check("promote case2: summary_id present", r2 ~= nil and r2.summary_id ~= nil)
    check("promote case2: deleted_source=false", r2 ~= nil and r2.deleted_source == false)

    local sum = db.query("SELECT title, kind, metadata FROM lm_memories WHERE id = "
        .. tostring(r2 and r2.summary_id or 0))[1]
    check("promote case2: kind=summary", sum ~= nil and sum.kind == "summary",
        "kind=" .. tostring(sum and sum.kind))
    check("promote case2: title has [promoted] prefix",
        sum ~= nil and sum.title ~= nil and sum.title:sub(1, 11) == "[promoted] ",
        "title=" .. tostring(sum and sum.title))

    local meta = sum and sum.metadata
    if type(meta) == "string" then
        meta = require("cjson").decode(meta)
    end
    check("promote case2: metadata.promoted_from",
        meta ~= nil and meta.promoted_from == FROM, tostring(meta and meta.promoted_from))
    check("promote case2: metadata.source_ids has 5",
        meta ~= nil and type(meta.source_ids) == "table" and #meta.source_ids == 5)

    local src_after = db.query("SELECT count(*) AS n FROM lm_memories WHERE scope = "
        .. db.escape_literal(FROM) .. " AND kind != 'summary'")[1]
    check("promote case2: source rows preserved",
        tonumber(src_after.n) == 5, "got " .. tostring(src_after.n))

    -- Real promote, delete source
    local r3 = memory.promote({ from_scope = FROM, to_scope = TO, delete_source = true })
    check("promote case3: promoted=1", r3 ~= nil and r3.promoted == 1)
    check("promote case3: deleted_source=true", r3 ~= nil and r3.deleted_source == true)
    local src_gone = db.query("SELECT count(*) AS n FROM lm_memories WHERE scope = "
        .. db.escape_literal(FROM))[1]
    check("promote case3: source deleted", tonumber(src_gone.n) == 0,
        "got " .. tostring(src_gone.n))
    local target_count = db.query("SELECT count(*) AS n FROM lm_memories WHERE scope = "
        .. db.escape_literal(TO))[1]
    check("promote case3: target has 2 summaries", tonumber(target_count.n) == 2,
        "got " .. tostring(target_count.n))

    -- Empty source -> no_rows
    local r4 = memory.promote({ from_scope = FROM, to_scope = TO })
    check("promote case4: empty source promoted=0", r4 ~= nil and r4.promoted == 0)
    check("promote case4: reason=no_rows",
        r4 ~= nil and r4.reason == "no_rows", "reason=" .. tostring(r4 and r4.reason))

    -- Validation errors
    local r5 = memory.promote({ from_scope = FROM })
    check("promote case5: missing to_scope",
        r5 ~= nil and r5.promoted == 0 and r5.errors ~= nil and r5.errors[1]:find("to_scope"))
    local r6 = memory.promote({ from_scope = "x", to_scope = "x" })
    check("promote case6: same scope rejected",
        r6 ~= nil and r6.promoted == 0 and r6.errors ~= nil
        and r6.errors[1]:find("from_scope == to_scope"))

    db.query("DELETE FROM lm_memories WHERE scope IN ("
        .. db.escape_literal(FROM) .. ", " .. db.escape_literal(TO) .. ")")
end

-- =========================================================================
-- Section 5: Decay + Dedup + Summary
-- =========================================================================
header("Decay + Dedup + Summary")

memory.setup({
    db_table       = "lm_memories",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",
    default_scope  = "h83",
    auth_fn        = function() return true end,
    summarizer_adapter          = "noop",
    summarizer_weight_threshold = 0.5,
    summarizer_retention_days   = 7,
    summarizer_batch_size       = 5,
    summarizer_max_batches      = 2,
})

db.query("DELETE FROM lm_memories WHERE scope LIKE 'h83%'")

do
    -- Decay
    local stable = memory.write({
        scope = "h83-decay", kind = "fact",
        title = "stable doctrine",
        body  = "The deploy procedure is documented in our runbook.",
        importance = 5.0, decay_rate = 0.0,
    })
    check("decay: stable row written", stable ~= nil)

    local rotting = memory.write({
        scope = "h83-decay", kind = "fact",
        title = "ephemeral note",
        body  = "The deploy procedure is documented in our runbook.",
        importance = 5.0, decay_rate = 0.5,
        dedup_strategy = "append",
    })
    check("decay: rotting row written", rotting ~= nil)

    db.query("ALTER TABLE lm_memories DISABLE TRIGGER lm_memories_touch_updated_at_trg")
    db.query("UPDATE lm_memories SET updated_at = now() - interval '30 days' WHERE id = " .. (rotting and rotting.id or 0))
    db.query("ALTER TABLE lm_memories ENABLE TRIGGER lm_memories_touch_updated_at_trg")

    local post = memory.search({
        query = "deploy procedure runbook", scope = "h83-decay",
        limit = 5, skip_observations = true,
    })
    local stable_pos, rotting_pos
    for i, r in ipairs(post or {}) do
        if stable  ~= nil and r.id == stable.id  then stable_pos  = i end
        if rotting ~= nil and r.id == rotting.id then rotting_pos = i end
    end
    check("decay: stable outranks rotting after 30d backdate",
        stable_pos ~= nil and rotting_pos ~= nil and stable_pos < rotting_pos,
        "stable=" .. tostring(stable_pos) .. " rotting=" .. tostring(rotting_pos))

    local ignored = memory.search({
        query = "deploy procedure runbook", scope = "h83-decay",
        limit = 5, ignore_decay = true, skip_observations = true,
    })
    local all_weight1 = true
    for _, r in ipairs(ignored or {}) do
        if r.weight ~= 1.0 then all_weight1 = false end
    end
    check("decay: ignore_decay=true yields weight=1.0 for all", all_weight1)

    -- Dedup
    local d1, _, a1 = memory.write({
        scope = "h83-dedup", kind = "fact",
        title = "client onboarding script",
        body  = "Read the welcome packet then run the onboarding checklist.",
    })
    check("dedup: first write action=inserted", d1 ~= nil and a1 == "inserted",
        "action=" .. tostring(a1))

    local d2, _, a2 = memory.write({
        scope = "h83-dedup", kind = "fact",
        title = "client onboarding script",
        body  = "Read the welcome packet then run the onboarding checklist.",
    })
    check("dedup: second write action=merged", d2 ~= nil and a2 == "merged",
        "action=" .. tostring(a2))
    check("dedup: merge preserves original id",
        d1 ~= nil and d2 ~= nil and d2.id == d1.id)

    local d3, _, a3 = memory.write({
        scope = "h83-dedup", kind = "fact",
        title = "client onboarding script",
        body  = "Read the welcome packet then run the onboarding checklist.",
        dedup_strategy = "append",
    })
    check("dedup: append creates new row",
        d3 ~= nil and a3 == "inserted" and d1 ~= nil and d3.id ~= d1.id)

    local n = db.query("SELECT count(*) AS c FROM lm_memories WHERE scope = 'h83-dedup'")
    check("dedup: 2 rows total (1 merged + 1 appended)",
        n ~= nil and tonumber(n[1].c) == 2, "got " .. tostring(n and n[1] and n[1].c))

    -- Summarizer
    for i = 1, 4 do
        local r = memory.write({
            scope = "h83-sum", kind = "fact",
            title = "old note " .. i,
            body  = "Stale content number " .. i .. ", retained for compaction tests.",
            importance = 0.2, decay_rate = 0.5,
        })
        check("summarizer seed " .. i, r ~= nil)
    end

    db.query("ALTER TABLE lm_memories DISABLE TRIGGER lm_memories_touch_updated_at_trg")
    db.query("UPDATE lm_memories SET updated_at = now() - interval '30 days' WHERE scope = 'h83-sum'")
    db.query("ALTER TABLE lm_memories ENABLE TRIGGER lm_memories_touch_updated_at_trg")

    local pre_count = db.query("SELECT count(*) AS c FROM lm_memories WHERE scope = 'h83-sum'")
    check("summarizer: 4 rows before summarize",
        pre_count ~= nil and tonumber(pre_count[1].c) == 4, tostring(pre_count and pre_count[1] and pre_count[1].c))

    local dry = memory.summarizer.run({
        scope = "h83-sum", weight_threshold = 0.5, retention_days = 7,
        batch_size = 5, max_batches = 1, dry_run = true,
    })
    check("summarizer dry-run: batches=1",     dry ~= nil and dry.batches == 1)
    check("summarizer dry-run: summarised=1",  dry ~= nil and dry.summarised == 1)
    check("summarizer dry-run: 4 replaced_ids", dry ~= nil and #dry.replaced_ids == 4,
        tostring(dry and #dry.replaced_ids))

    local mid_count = db.query("SELECT count(*) AS c FROM lm_memories WHERE scope = 'h83-sum'")
    check("summarizer dry-run: no mutation",
        mid_count ~= nil and tonumber(mid_count[1].c) == 4, tostring(mid_count and mid_count[1] and mid_count[1].c))

    local real = memory.summarizer.run({
        scope = "h83-sum", weight_threshold = 0.5, retention_days = 7,
        batch_size = 5, max_batches = 1,
    })
    check("summarizer real: summarised=1",   real ~= nil and real.summarised == 1)
    check("summarizer real: 1 new_id",       real ~= nil and #real.new_ids == 1)
    check("summarizer real: no errors",      real ~= nil and #real.errors == 0,
        real and table.concat(real.errors, "; ") or "")

    local rows = db.query("SELECT id, kind, title, metadata FROM lm_memories WHERE scope = 'h83-sum' ORDER BY id")
    check("summarizer: 1 row remains", rows ~= nil and #rows == 1, "got " .. tostring(rows and #rows))
    check("summarizer: kind=summary",  rows ~= nil and rows[1] ~= nil and rows[1].kind == "summary")

    local raw_meta = rows and rows[1] and rows[1].metadata
    local meta_t
    if type(raw_meta) == "table" then
        meta_t = raw_meta
    else
        meta_t = require("cjson.safe").decode(raw_meta or "{}") or {}
    end
    check("summarizer: metadata.summarized_ids has 4",
        meta_t ~= nil and meta_t.summarized_ids ~= nil and #meta_t.summarized_ids == 4,
        tostring(meta_t and meta_t.summarized_ids and #meta_t.summarized_ids))
end

-- =========================================================================
io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
