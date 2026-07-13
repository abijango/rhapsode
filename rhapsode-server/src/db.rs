use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

pub struct Db {
    conn: Mutex<Connection>,
}

impl Db {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)
            .with_context(|| format!("open sqlite {}", path.display()))?;
        conn.busy_timeout(Duration::from_secs(8))?;
        conn.execute_batch(
            "
            PRAGMA foreign_keys = ON;
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            ",
        )?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    pub fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().expect("db lock poisoned")
    }

    fn migrate(&self) -> Result<()> {
        let conn = self.conn();
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS users (
              id TEXT PRIMARY KEY,
              created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS devices (
              id TEXT PRIMARY KEY,
              user_id TEXT NOT NULL REFERENCES users(id),
              name TEXT NOT NULL,
              platform TEXT,
              token_hash TEXT NOT NULL UNIQUE,
              created_at TEXT NOT NULL,
              last_seen_at TEXT,
              revoked_at TEXT
            );

            CREATE TABLE IF NOT EXISTS library_items (
              id TEXT PRIMARY KEY,
              content_key TEXT NOT NULL UNIQUE,
              kind TEXT NOT NULL,
              title TEXT NOT NULL,
              author TEXT,
              duration_seconds REAL,
              rel_path TEXT,
              missing INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS media_files (
              id TEXT PRIMARY KEY,
              item_id TEXT NOT NULL REFERENCES library_items(id) ON DELETE CASCADE,
              role TEXT NOT NULL,
              rel_path TEXT NOT NULL,
              size_bytes INTEGER,
              duration_seconds REAL,
              sort_order INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS progress (
              item_id TEXT PRIMARY KEY REFERENCES library_items(id) ON DELETE CASCADE,
              audio_position_seconds REAL,
              audio_duration_seconds REAL,
              ebook_progression REAL,
              ebook_locator_json TEXT,
              is_finished INTEGER NOT NULL DEFAULT 0,
              finished_at TEXT,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS item_stats (
              item_id TEXT PRIMARY KEY REFERENCES library_items(id) ON DELETE CASCADE,
              saved_seconds REAL NOT NULL DEFAULT 0,
              listened_seconds REAL NOT NULL DEFAULT 0,
              reading_seconds REAL NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS lifetime_stats (
              user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
              saved_seconds REAL NOT NULL DEFAULT 0,
              played_seconds REAL NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_media_files_item ON media_files(item_id);
            CREATE INDEX IF NOT EXISTS idx_devices_token ON devices(token_hash);
            CREATE INDEX IF NOT EXISTS idx_media_files_rel ON media_files(rel_path);
            "#,
        )?;

        // Additive column for incremental scan (ignore if already present).
        let _ = conn.execute(
            "ALTER TABLE media_files ADD COLUMN mtime_secs INTEGER",
            [],
        );

        Ok(())
    }

    pub fn user_count(&self) -> Result<i64> {
        let conn = self.conn();
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0))?;
        Ok(n)
    }

    pub fn ensure_lifetime_stats(&self, user_id: &str, now: &str) -> Result<()> {
        let conn = self.conn();
        conn.execute(
            "INSERT OR IGNORE INTO lifetime_stats (user_id, saved_seconds, played_seconds, updated_at)
             VALUES (?1, 0, 0, ?2)",
            params![user_id, now],
        )?;
        Ok(())
    }
}

pub fn max_f64(a: f64, b: f64) -> f64 {
    if a > b {
        a
    } else {
        b
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn max_merge() {
        assert_eq!(max_f64(1.0, 2.0), 2.0);
        assert_eq!(max_f64(5.0, 3.0), 5.0);
    }
}
