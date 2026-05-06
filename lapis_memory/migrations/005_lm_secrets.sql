-- lapis-memory migration 005: lm_secrets
--
-- Creates the encrypted secret storage table used by the lm_secrets module
-- and the execute_with_secret MCP tool pattern.
--
-- Secret VALUES are stored as AES-256-CBC ciphertext ("<salt_hex>:<ct_hex>").
-- The master key is NEVER persisted in the database.
--
-- Safe to re-run (all statements are IF NOT EXISTS).

CREATE TABLE IF NOT EXISTS lm_secrets (
    id           SERIAL PRIMARY KEY,
    -- Unique human-readable identifier (alphanumeric + hyphen/underscore/dot,
    -- max 128 chars; enforced by application layer).
    name         TEXT        NOT NULL UNIQUE,
    -- AES-256-CBC ciphertext.  Format: "<16-char salt_hex>:<ciphertext_hex>".
    -- Never query this column from outside lapis_memory.secrets.
    ciphertext   TEXT        NOT NULL,
    -- Optional human-readable description shown by list() and the MCP tool.
    description  TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Audit trail: when was this secret last used via execute_with_secret?
    last_used_at TIMESTAMPTZ,
    used_count   INT         NOT NULL DEFAULT 0
);

-- Index on name is implied by the UNIQUE constraint.
-- Additional index for time-ordered listing.
CREATE INDEX IF NOT EXISTS lm_secrets_created_idx
    ON lm_secrets (created_at DESC);
