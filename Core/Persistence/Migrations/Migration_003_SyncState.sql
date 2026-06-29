-- Migration 003: Sync State
-- Creates the sync_state table for SyncStateDB and the sync_pairs table
-- for tracking active folder sync configurations.

CREATE TABLE IF NOT EXISTS sync_state (
    local_path      TEXT NOT NULL,
    remote_path     TEXT NOT NULL,
    account_id      TEXT NOT NULL,
    local_checksum  TEXT,
    remote_checksum TEXT,
    last_synced_at  REAL,
    local_mod_date  REAL,
    remote_mod_date REAL,
    sync_status     TEXT NOT NULL DEFAULT 'pending',

    PRIMARY KEY (local_path, account_id)
);

CREATE INDEX IF NOT EXISTS idx_sync_state_account_id
    ON sync_state (account_id);

CREATE INDEX IF NOT EXISTS idx_sync_state_sync_status
    ON sync_state (sync_status);

CREATE INDEX IF NOT EXISTS idx_sync_state_account_status
    ON sync_state (account_id, sync_status);

CREATE INDEX IF NOT EXISTS idx_sync_state_remote_path
    ON sync_state (remote_path);

-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sync_pairs (
    id           TEXT    NOT NULL PRIMARY KEY,
    local_folder TEXT    NOT NULL,
    remote_path  TEXT    NOT NULL,
    account_id   TEXT    NOT NULL,
    sync_mode    TEXT    NOT NULL DEFAULT 'bidirectional',
    is_active    INTEGER NOT NULL DEFAULT 1,
    created_at   REAL    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sync_pairs_account_id
    ON sync_pairs (account_id);

CREATE INDEX IF NOT EXISTS idx_sync_pairs_is_active
    ON sync_pairs (is_active);

CREATE INDEX IF NOT EXISTS idx_sync_pairs_account_active
    ON sync_pairs (account_id, is_active);
