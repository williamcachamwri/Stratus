-- Migration 004: Resume Tokens
-- Creates the download_sessions table for DownloadResumeStore and the
-- block_manifests table for DeltaSync.  Block manifests are keyed by the same
-- security-scoped bookmark identifier used by ResumeStore.

CREATE TABLE IF NOT EXISTS download_sessions (
    id                 TEXT    NOT NULL PRIMARY KEY,
    file_url           TEXT,
    provider_id        TEXT    NOT NULL,
    account_id         TEXT    NOT NULL,
    remote_path        TEXT    NOT NULL,
    local_path         TEXT    NOT NULL,
    file_size          INTEGER,
    file_checksum      TEXT,
    segment_size       INTEGER NOT NULL DEFAULT 8388608,
    total_segments     INTEGER NOT NULL DEFAULT 0,
    completed_segments TEXT    NOT NULL DEFAULT '[]',
    created_at         REAL    NOT NULL,
    updated_at         REAL    NOT NULL,
    state              TEXT    NOT NULL DEFAULT 'pending',
    priority           INTEGER NOT NULL DEFAULT 50,
    retry_count        INTEGER NOT NULL DEFAULT 0,
    error_description  TEXT
);

CREATE INDEX IF NOT EXISTS idx_download_sessions_account_id
    ON download_sessions (account_id);

CREATE INDEX IF NOT EXISTS idx_download_sessions_state
    ON download_sessions (state);

CREATE INDEX IF NOT EXISTS idx_download_sessions_priority_state
    ON download_sessions (priority DESC, state);

CREATE INDEX IF NOT EXISTS idx_download_sessions_updated_at
    ON download_sessions (updated_at);

-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS block_manifests (
    id            TEXT NOT NULL PRIMARY KEY,
    file_bookmark TEXT NOT NULL UNIQUE,
    provider_id   TEXT NOT NULL,
    account_id    TEXT NOT NULL,
    remote_path   TEXT NOT NULL,
    block_map     TEXT NOT NULL,
    updated_at    REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_block_manifests_account_id
    ON block_manifests (account_id);

CREATE INDEX IF NOT EXISTS idx_block_manifests_remote_path
    ON block_manifests (remote_path);
