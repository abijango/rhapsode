mod auth_routes;
mod library_routes;
mod progress_routes;

use crate::state::AppState;
use axum::routing::{delete, get, post};
use axum::Router;
use std::sync::Arc;

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/health", get(health_v1))
        .route("/v1/me", get(auth_routes::me))
        .route("/v1/auth/bootstrap", post(auth_routes::bootstrap))
        .route(
            "/v1/auth/devices",
            get(auth_routes::list_devices).post(auth_routes::create_device_route),
        )
        .route(
            "/v1/auth/devices/{id}",
            delete(auth_routes::revoke_device),
        )
        .route("/v1/library", get(library_routes::list_library))
        .route("/v1/library/scan", post(library_routes::scan_library))
        .route(
            "/v1/library/scan/status",
            get(library_routes::scan_status),
        )
        .route("/v1/items/{id}", get(library_routes::get_item))
        .route("/v1/items/{id}/files", get(library_routes::list_files))
        .route(
            "/v1/items/{id}/files/{file_id}/download",
            get(library_routes::download_file),
        )
        .route(
            "/v1/items/{id}/progress",
            get(progress_routes::get_progress).put(progress_routes::put_progress),
        )
        .route("/v1/progress", get(progress_routes::list_progress))
        .route(
            "/v1/items/{id}/stats",
            get(progress_routes::get_item_stats).put(progress_routes::put_item_stats),
        )
        .route(
            "/v1/stats/lifetime",
            get(progress_routes::get_lifetime).put(progress_routes::put_lifetime),
        )
        .with_state(state)
}

async fn health() -> axum::Json<serde_json::Value> {
    axum::Json(serde_json::json!({ "ok": true }))
}

async fn health_v1(
    state: axum::extract::State<Arc<AppState>>,
) -> Result<axum::Json<serde_json::Value>, crate::error::ApiError> {
    // Keep this off the async worker: SQLite + Mutex would stall the runtime
    // (and client probes) while a library scan holds the DB lock.
    // Clients use `/health` for reachability; this endpoint is diagnostic.
    let state2 = Arc::clone(&state);
    let users = tokio::task::spawn_blocking(move || state2.db.user_count().ok())
        .await
        .ok()
        .flatten();
    Ok(axum::Json(serde_json::json!({
        "ok": true,
        "users": users,
        "scan_running": state.scan_running(),
    })))
}
