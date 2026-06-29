-- Migration 001: Accounts
-- Creates the accounts table for storing cloud account configurations.

CREATE TABLE IF NOT EXISTS accounts (
    id            TEXT    NOT NULL PRIMARY KEY,
    provider_id   TEXT    NOT NULL,
    display_name  TEXT    NOT NULL,
    email         TEXT,
    created_at    REAL    NOT NULL,
    updated_at    REAL    NOT NULL,
    is_active     INTEGER NOT NULL DEFAULT 1,
    metadata      TEXT                         -- JSON blob
);

CREATE INDEX IF NOT EXISTS idx_accounts_provider_id
    ON accounts (provider_id);

CREATE INDEX IF NOT EXISTS idx_accounts_is_active
    ON accounts (is_active);

CREATE INDEX IF NOT EXISTS idx_accounts_email
    ON accounts (email)
    WHERE email IS NOT NULL;
