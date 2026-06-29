-- Migration 002: Upload Queue
-- Creates the upload_sessions table for ResumeStore.  The persisted file
-- reference stores both a security-scoped bookmark and a fallback URL string so
-- interrupted sandboxed uploads can resume after relaunch.

CREATE TABLE IF NOT EXISTS upload_sessions (
    id                TEXT    NOT NULL PRIMARY KEY,
    file_bookmark     TEXT    NOT NULL,
    file_url_string   TEXT    NOT NULL,
    provider_id       TEXT    NOT NULL,
    account_id        TEXT    NOT NULL,
    remote_path       TEXT    NOT NULL,
    upload_id         TEXT,
    file_size         INTEGER NOT NULL,
    file_checksum     TEXT    NOT NULL,
    chunk_size        INTEGER NOT NULL,
    total_chunks      INTEGER NOT NULL,
    completed_chunks  TEXT    NOT NULL DEFAULT '[]',
    etags             TEXT    NOT NULL DEFAULT '{}',
    created_at        REAL    NOT NULL,
    updated_at        REAL    NOT NULL,
    state             TEXT    NOT NULL DEFAULT 'queued',
    priority          INTEGER NOT NULL DEFAULT 50,
    retry_count       INTEGER NOT NULL DEFAULT 0,
    error_description TEXT
);

CREATE INDEX IF NOT EXISTS idx_upload_sessions_account_id
    ON upload_sessions (account_id);

CREATE INDEX IF NOT EXISTS idx_upload_sessions_state
    ON upload_sessions (state);

CREATE INDEX IF NOT EXISTS idx_upload_sessions_account_state
    ON upload_sessions (account_id, state);

CREATE INDEX IF NOT EXISTS idx_upload_sessions_updated_at
    ON upload_sessions (updated_at);
