use anyhow::{bail, Context, Result};
use std::env;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct Config {
    pub data_dir: PathBuf,
    pub library_audio: PathBuf,
    pub library_ebook: PathBuf,
    pub bind: String,
    pub bootstrap_token: Option<String>,
    pub log_filter: String,
    /// Background incremental scan interval. `None` / 0 = disabled.
    pub scan_interval: Option<Duration>,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let data_dir = env::var("RHAPSODE_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("./data"));
        let library_audio = env::var("RHAPSODE_LIBRARY_AUDIO")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("./fixtures/audio"));
        let library_ebook = env::var("RHAPSODE_LIBRARY_EBOOK")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("./fixtures/ebook"));
        let bind = env::var("RHAPSODE_BIND").unwrap_or_else(|_| "0.0.0.0:8080".into());
        let bootstrap_token = env::var("RHAPSODE_BOOTSTRAP_TOKEN")
            .ok()
            .filter(|s| !s.is_empty());
        let log_filter = env::var("RHAPSODE_LOG").unwrap_or_else(|_| "info".into());

        // Default 15 minutes. Set RHAPSODE_SCAN_INTERVAL_SECS=0 to disable.
        let scan_interval = match env::var("RHAPSODE_SCAN_INTERVAL_SECS") {
            Ok(s) => {
                let n: u64 = s.parse().unwrap_or(900);
                if n == 0 {
                    None
                } else {
                    Some(Duration::from_secs(n))
                }
            }
            Err(_) => Some(Duration::from_secs(900)),
        };

        std::fs::create_dir_all(&data_dir)
            .with_context(|| format!("create data dir {}", data_dir.display()))?;

        if !library_audio.exists() {
            tracing::warn!(
                path = %library_audio.display(),
                "audio library path does not exist yet (scan will find nothing)"
            );
        }
        if !library_ebook.exists() {
            tracing::warn!(
                path = %library_ebook.display(),
                "ebook library path does not exist yet (scan will find nothing)"
            );
        }

        Ok(Self {
            data_dir,
            library_audio,
            library_ebook,
            bind,
            bootstrap_token,
            log_filter,
            scan_interval,
        })
    }

    pub fn database_path(&self) -> PathBuf {
        self.data_dir.join("rhapsode.db")
    }

    pub fn require_bootstrap_token(&self, provided: &str) -> Result<()> {
        match &self.bootstrap_token {
            Some(expected) if constant_time_eq(expected.as_bytes(), provided.as_bytes()) => Ok(()),
            Some(_) => bail!("invalid bootstrap token"),
            None => bail!("bootstrap disabled (RHAPSODE_BOOTSTRAP_TOKEN not set)"),
        }
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}
