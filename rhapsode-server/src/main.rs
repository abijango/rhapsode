mod auth;
mod config;
mod db;
mod error;
mod library;
mod routes;
mod state;

use crate::config::Config;
use crate::db::Db;
use crate::state::AppState;
use anyhow::Context;
use std::net::SocketAddr;
use tower_http::trace::TraceLayer;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = Config::from_env()?;
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(format!("rhapsode_server={},tower_http=info", config.log_filter)));
    tracing_subscriber::fmt().with_env_filter(filter).init();

    let db = Db::open(&config.database_path())?;
    let state = AppState::new(config.clone(), db);
    let app = routes::router(state).layer(TraceLayer::new_for_http());

    let addr: SocketAddr = config
        .bind
        .parse()
        .with_context(|| format!("parse bind address {}", config.bind))?;
    tracing::info!(%addr, data = %config.data_dir.display(), "rhapsode-server listening");
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
