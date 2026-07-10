use crate::config::Config;
use crate::db::Db;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub struct AppState {
    pub config: Config,
    pub db: Db,
    scan_running: AtomicBool,
}

impl AppState {
    pub fn new(config: Config, db: Db) -> Arc<Self> {
        Arc::new(Self {
            config,
            db,
            scan_running: AtomicBool::new(false),
        })
    }

    pub fn try_begin_scan(&self) -> bool {
        self.scan_running
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
    }

    pub fn end_scan(&self) {
        self.scan_running.store(false, Ordering::SeqCst);
    }

    pub fn scan_running(&self) -> bool {
        self.scan_running.load(Ordering::SeqCst)
    }
}
