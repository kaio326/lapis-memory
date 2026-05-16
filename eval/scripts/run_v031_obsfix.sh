#!/usr/bin/env bash
# v0.3.1 — Plan 12 observation slot-append fix: full benchmark suite.
#
# Runs all three corpora with the Ollama embedder + llama3.1:8b synthesizer
# to validate the slot-partitioned supplement fix restores R@1 across the
# board after the symmetric-RRF regression.
#
# Expected runtimes (rough):
#   LME full (n=500)   : ~4-5h (synthesis per scope = synthesis per question)
#   LoCoMo full        : ~30-60min (synthesis per dialogue = 10 times)
#   ConvoMem full      : ~30-60min (synthesis per dialogue)
#
# Usage:
#   cd /path/to/lapis-memory
#   bash eval/scripts/run_v031_obsfix.sh [lme|locomo|convomem|all]
#
# Results are written to eval/results/
set -euo pipefail
cd "$(dirname "$0")/../.."

export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
export PGDATABASE=lm_bruteforce_test
export OLLAMA_MODEL=nomic-embed-text
export OLLAMA_DIM=768
# Truncate long LME sessions to avoid embedding dimension mismatch / OOM
export EMBED_MAX_CHARS=6000

OUT=eval/results
LOG=/tmp/run_v031_obsfix.log
SUITE=${1:-all}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== v0.3.1 obsfix benchmark suite (suite=$SUITE) ==="
log "DB=$PGDATABASE embedder=ollama($OLLAMA_MODEL) synthesizer=llama3.1:8b"
log "Log: $LOG"

# ---- LongMemEval (n=500, oracle corpus) ----------------------------------
run_lme() {
    log "--- LongMemEval: START (n=500, with-observations via summarizer-model) ---"
    lua5.1 eval/longmemeval_run.lua \
        --embedder ollama \
        --summarizer-model llama3.1:8b \
        --out "$OUT/longmemeval_ollama_v031_obsfix.json" \
        2>&1 | tee -a "$LOG"
    log "--- LongMemEval: DONE ---"
}

# ---- LoCoMo (1986 QAs across 10 dialogues) -------------------------------
run_locomo() {
    log "--- LoCoMo: START (full corpus, with-observations via summarizer-model) ---"
    lua5.1 eval/locomo_run.lua \
        --embedder ollama \
        --summarizer-model llama3.1:8b \
        --out "$OUT/locomo_ollama_v031_obsfix.json" \
        2>&1 | tee -a "$LOG"
    log "--- LoCoMo: DONE ---"
}

# ---- ConvoMem (full corpus) -----------------------------------------------
run_convomem() {
    log "--- ConvoMem: START (full corpus, with-observations via summarizer-model) ---"
    lua5.1 eval/convomem_run.lua \
        --embedder ollama \
        --summarizer-model llama3.1:8b \
        --out "$OUT/convomem_ollama_v031_obsfix.json" \
        2>&1 | tee -a "$LOG"
    log "--- ConvoMem: DONE ---"
}

case "$SUITE" in
    lme)     run_lme ;;
    locomo)  run_locomo ;;
    convomem) run_convomem ;;
    all)
        run_locomo
        run_convomem
        run_lme
        ;;
    *)
        echo "Usage: $0 [lme|locomo|convomem|all]" >&2
        exit 1
        ;;
esac

log "=== Suite complete ==="
