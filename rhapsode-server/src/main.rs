mod auth;
mod config;
mod db;
mod error;
mod library;
mod routes;
mod state;

use crate::config::Config;
use crate::db::Db;
use crate::library::ScanMode;
use crate::state::AppState;
use anyhow::Context;
use std::net::SocketAddr;
use std::sync::Arc;
use tower_http::trace::TraceLayer;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = Config::from_env()?;
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new(format!(
            "rhapsode_server={},tower_http=info",
            config.log_filter
        ))
    });
    tracing_subscriber::fmt().with_env_filter(filter).init();

    let db = Db::open(&config.database_path())?;
    let state = AppState::new(config.clone(), db);

    // Startup incremental index (non-blocking for the listener once spawned).
    {
        let s = Arc::clone(&state);
        tokio::spawn(async move {
            run_scan(s, ScanMode::Incremental, "startup").await;
        });
    }

    // Periodic incremental scan (default 15m; RHAPSODE_SCAN_INTERVAL_SECS=0 disables).
    if let Some(interval) = config.scan_interval {
        let s = Arc::clone(&state);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(interval).await;
                run_scan(Arc::clone(&s), ScanMode::Incremental, "periodic").await;
            }
        });
        tracing::info!(?interval, "background incremental scan enabled");
    } else {
        tracing::info!("background incremental scan disabled");
    }

    let app = routes::router(Arc::clone(&state)).layer(TraceLayer::new_for_http());

    let addr: SocketAddr = config
        .bind
        .parse()
        .with_context(|| format!("parse bind address {}", config.bind))?;
    tracing::info!(
        %addr,
        data = %config.data_dir.display(),
        "rhapsode-server listening"
    );
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn run_scan(state: Arc<AppState>, mode: ScanMode, reason: &'static str) {
    if !state.try_begin_scan() {
        tracing::debug!(reason, "scan skipped (already running)");
        return;
    }
    let audio = state.config.library_audio.clone();
    let ebook = state.config.library_ebook.clone();
    let state2 = Arc::clone(&state);
    let result = tokio::task::spawn_blocking(move || {
        let r = library::scan_libraries(&state2.db, &audio, &ebook, mode);
        state2.end_scan();
        r
    })
    .await;
    match result {
        Ok(Ok(report)) => {
            tracing::info!(
                reason,
                mode = report.mode,
                upserted = report.upserted,
                skipped = report.skipped_unchanged,
                removed = report.removed,
                audio = report.audio_items,
                ebook = report.ebook_items,
                "library scan finished"
            );
        }
        Ok(Err(e)) => tracing::error!(reason, error = %e, "library scan failed"),
        Err(e) => tracing::error!(reason, error = %e, "library scan task join failed"),
    }
}
