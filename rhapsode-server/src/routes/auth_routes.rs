use crate::auth::{self, AuthUser};
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::Json;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Deserialize)]
pub struct BootstrapBody {
    pub device_name: String,
    pub platform: Option<String>,
}

#[derive(Deserialize)]
pub struct CreateDeviceBody {
    pub device_name: String,
    pub platform: Option<String>,
}

#[derive(Serialize)]
pub struct TokenResponse {
    pub user_id: String,
    pub device_id: String,
    pub api_token: String,
    pub device_name: String,
}

#[derive(Serialize)]
pub struct DeviceDto {
    pub id: String,
    pub name: String,
    pub platform: Option<String>,
    pub created_at: String,
    pub last_seen_at: Option<String>,
    pub revoked: bool,
}

#[derive(Serialize)]
pub struct MeResponse {
    pub user_id: String,
    pub device_id: String,
    pub device_name: String,
}

pub async fn bootstrap(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(body): Json<BootstrapBody>,
) -> ApiResult<Json<TokenResponse>> {
    if body.device_name.trim().is_empty() {
        return Err(ApiError::BadRequest("device_name required".into()));
    }
    let provided = headers
        .get("X-Bootstrap-Token")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    state
        .config
        .require_bootstrap_token(provided)
        .map_err(|e| ApiError::Forbidden(e.to_string()))?;

    let user_count = state.db.user_count()?;
    if user_count > 0 {
        return Err(ApiError::Conflict(
            "users already exist; use POST /v1/auth/devices with an existing token".into(),
        ));
    }

    let (user_id, device_id, api_token) = auth::create_user_and_device(
        &state.db,
        body.device_name.trim(),
        body.platform.as_deref(),
    )?;
    Ok(Json(TokenResponse {
        user_id,
        device_id,
        api_token,
        device_name: body.device_name.trim().to_string(),
    }))
}

pub async fn create_device_route(
    State(state): State<Arc<AppState>>,
    user: AuthUser,
    Json(body): Json<CreateDeviceBody>,
) -> ApiResult<Json<TokenResponse>> {
    if body.device_name.trim().is_empty() {
        return Err(ApiError::BadRequest("device_name required".into()));
    }
    let (device_id, api_token) = auth::create_device(
        &state.db,
        &user.user_id,
        body.device_name.trim(),
        body.platform.as_deref(),
    )?;
    Ok(Json(TokenResponse {
        user_id: user.user_id,
        device_id,
        api_token,
        device_name: body.device_name.trim().to_string(),
    }))
}

pub async fn list_devices(
    State(state): State<Arc<AppState>>,
    user: AuthUser,
) -> ApiResult<Json<Vec<DeviceDto>>> {
    let conn = state.db.conn();
    let mut stmt = conn.prepare(
        "SELECT id, name, platform, created_at, last_seen_at, revoked_at
         FROM devices WHERE user_id = ?1 ORDER BY created_at",
    )?;
    let rows = stmt.query_map(params![user.user_id], |r| {
        let revoked_at: Option<String> = r.get(5)?;
        Ok(DeviceDto {
            id: r.get(0)?,
            name: r.get(1)?,
            platform: r.get(2)?,
            created_at: r.get(3)?,
            last_seen_at: r.get(4)?,
            revoked: revoked_at.is_some(),
        })
    })?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>()?))
}

pub async fn revoke_device(
    State(state): State<Arc<AppState>>,
    user: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let now = auth::now_rfc3339();
    let conn = state.db.conn();
    let n = conn.execute(
        "UPDATE devices SET revoked_at = ?1
         WHERE id = ?2 AND user_id = ?3 AND revoked_at IS NULL",
        params![now, id, user.user_id],
    )?;
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(Json(serde_json::json!({ "ok": true, "revoked": id })))
}

pub async fn me(user: AuthUser) -> Json<MeResponse> {
    Json(MeResponse {
        user_id: user.user_id,
        device_id: user.device_id,
        device_name: user.device_name,
    })
}
