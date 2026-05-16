#!/usr/bin/env bash
# v0.3.1 — Plan 12 observation slot-append fix: TEI/bge-m3 benchmark suite.
#
# Runs all three corpora with bge-m3 (via TEI) + llama3.1:8b synthesizer
# to establish v0.3.1 numbers for the best-performing embedder config.
#
# Prerequisites:
#   - TEI embed sidecar running at TEI_URL (default http://127.0.0.1:8001/embed)
#   - Ollama running with llama3.1:8b loaded (for synthesis)
#
# Usage:
#   cd /path/to/lapis-memory
#   bash eval/scripts/run_v031_obsfix_tei.sh [lme|locomo|convomem|all]
#
# Results are written to eval/results/
set -euo pipefail
cd "$(dirname "$0")/../.."

export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
export PGDATABASE=lm_bruteforce_test
# TEI bge-m3 sidecar (adjust port if needed)
export TEI_URL="${TEI_URL:-http://127.0.0.1:8001/embed}"
export TEI_DIM=1024
# bge-m3 supports 8192 tokens natively; use 12000 chars as generous cutoff
export EMBED_MAX_CHARS=12000

OUT=eval/results
LOG=/tmp/run_v031_obsfix_tei.log
SUITE=${1:-all}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== v0.3.1 obsfix TEI/bge-m3 benchmark suite (suite=$SUITE) ==="
log "DB=$PGDATABASE embedder=tei(bge-m3 @${TEI_URL}) synthesizer=llama3.1:8b"
log "Log: $LOG"

# Verify TEI is reachable
if ! curl -sf "${TEI_URL%/embed}/health" > /dev/null 2>&1; then
    log "ERROR: TEI sidecar not reachable at ${TEI_URL%/embed}/health"
    log "Start it with: docker compose -f eval/sidecars/docker-compose.yml up -d tei-embed"
    exit 1
fi
log "TEI health check OK"

# ---- LoCoMo (1986 QAs across 10 dialogues) -------------------------------
run_locomo() {
    log "--- LoCoMo: START (bge-m3, with-observations via summarizer-model) ---"
    lua5.1 eval/locomo_run.lua \
        --embedder tei \
        --summarizer-model llama3.1:8b \
        --out "$OUT/locomo_tei_v031_obsfix.json" \
        2>&1 | tee -a "$LOG"
    log "--- LoCoMo: DONE ---"
}

# ---- ConvoMem (full corpus) -----------------------------------------------
run_convomem() {
    log "--- ConvoMem: START (bge-m3, with-observations via summarizer-model) ---"
    lua5.1 eval/convomem_run.lua \
        --embedder tei \
        --summarizer-model llama3.1:8b \
        --out "$OUT/convomem_tei_v031_obsfix.json" \
        2>&1 | tee -a "$LOG"
    log "--- ConvoMem: DONE ---"
}

# ---- LongMemEval (n=500, oracle corpus) ----------------------------------
run_lme() {
    log "--- LongMemEval: START (bge-m3, n=500, with-observations via summarizer-model) ---"
    lua5.1 eval/longmemeval_run.lua \
        --embedder tei \
        --summarizer-model llama3.1:8b \
        --out "$OUT/longmemeval_tei_v031_obsfix.json" \
        2>&1 | tee -a "$LOG"
    log "--- LongMemEval: DONE ---"
}

case "$SUITE" in
    lme)      run_lme ;;
    locomo)   run_locomo ;;
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

log "=== TEI suite complete ==="
