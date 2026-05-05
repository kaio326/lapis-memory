rockspec_format = "3.0"
package = "lapis-memory"
version = "0.1-1"

source = {
    url = "git+https://github.com/kaio326/lapis-memory.git",
    tag = "v0.1",
}

description = {
    summary  = "Persistent semantic memory for AI agents on Lapis / OpenResty (PostgreSQL + pgvector)",
    detailed = [[
        lapis-memory is a persistent semantic memory store for AI agents
        and conversational apps running on Lapis / OpenResty.

        Features:
          * Hybrid vector + full-text retrieval over PostgreSQL.
          * Two backends: pgvector (recommended) or pure brute-force REAL[]
            (zero extension dependency).
          * Pluggable embedders: Ollama, OpenAI, Voyage, Cohere, DeepSeek,
            Anthropic, generic HTTP, and a built-in pure-Lua "hash"
            embedder with no external dependencies.
          * Pluggable rerankers (Ollama, OpenAI, cross-encoder via TEI).
          * Background summarizer + decay/importance scoring.
          * Knowledge-graph adjunct (lm_kg_facts) for currently-valid
            facts with temporal validity.
          * MCP server bundled (mcp/server.lua) so models can read/write
            memory directly through Model Context Protocol.

        Benchmarks (R@10):
          * LoCoMo: 82.5% (hash) / 86.6% (Ollama bge-m3).
          * Salesforce ConvoMem: hash R@1 81.6% / MRR 0.885;
            Ollama R@1 88.3% / MRR 0.921.
    ]],
    homepage   = "https://github.com/kaio326/lapis-memory",
    issues_url = "https://github.com/kaio326/lapis-memory/issues",
    license    = "MIT",
    maintainer = "Kaio Fernandes <contact@kaiofernandes.com>",
    labels     = { "memory", "agents", "ai", "embeddings", "pgvector",
                   "rag", "lapis", "openresty", "postgresql", "mcp" },
}

dependencies = {
    "lua >= 5.1",
    "lapis >= 1.8.0",
    "lua-cjson >= 2.1.0",
    -- lua-resty-http is only needed when using an HTTP embedder
    -- (Ollama / OpenAI / generic). The pure-Lua "hash" embedder works
    -- without it. It is bundled with OpenResty by default.
    "lua-resty-http >= 0.17",
}

build = {
    type    = "builtin",
    modules = {
        ["lapis_memory"]                    = "lapis_memory/init.lua",
        ["lapis_memory.store"]              = "lapis_memory/store.lua",
        ["lapis_memory.embed"]              = "lapis_memory/embed.lua",
        ["lapis_memory.routes"]             = "lapis_memory/routes.lua",
        ["lapis_memory.web"]                = "lapis_memory/web.lua",
        ["lapis_memory.hooks"]              = "lapis_memory/hooks.lua",
        ["lapis_memory.kg"]                 = "lapis_memory/kg.lua",
        ["lapis_memory.rerank"]             = "lapis_memory/rerank.lua",
        ["lapis_memory.summarizer"]         = "lapis_memory/summarizer.lua",
        ["lapis_memory.tune_weights"]       = "lapis_memory/tune_weights.lua",
        ["lapis_memory.adapters.ollama"]    = "lapis_memory/adapters/ollama.lua",
        ["lapis_memory.adapters.openai"]    = "lapis_memory/adapters/openai.lua",
        ["lapis_memory.adapters.generic"]   = "lapis_memory/adapters/generic.lua",
        ["lapis_memory.adapters.voyage"]    = "lapis_memory/adapters/voyage.lua",
        ["lapis_memory.adapters.cohere"]    = "lapis_memory/adapters/cohere.lua",
        ["lapis_memory.adapters.anthropic"] = "lapis_memory/adapters/anthropic.lua",
        ["lapis_memory.adapters.deepseek"]  = "lapis_memory/adapters/deepseek.lua",
        ["lapis_memory.embedders.hash"]     = "lapis_memory/embedders/hash.lua",
        ["lapis_memory.rerankers.noop"]          = "lapis_memory/rerankers/noop.lua",
        ["lapis_memory.rerankers.ollama"]        = "lapis_memory/rerankers/ollama.lua",
        ["lapis_memory.rerankers.openai"]        = "lapis_memory/rerankers/openai.lua",
        ["lapis_memory.rerankers.cross_encoder"] = "lapis_memory/rerankers/cross_encoder.lua",
        ["lapis_memory.summarizers.noop"]   = "lapis_memory/summarizers/noop.lua",
        ["lapis_memory.summarizers.ollama"] = "lapis_memory/summarizers/ollama.lua",
        ["lapis_memory.summarizers.openai"] = "lapis_memory/summarizers/openai.lua",
    },
    install = {
        bin = { ["memo"] = "cli/memo" },
    },
    copy_directories = { "examples", "mcp" },
}
