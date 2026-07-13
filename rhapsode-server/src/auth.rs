use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use chrono::Utc;
use base64::Engine;
use rusqlite::params;
use sha2::{Digest, Sha256};
use std::sync::Arc;
use uuid::Uuid;

#[derive(Clone, Debug)]
pub struct AuthUser {
    pub user_id: String,
    pub device_id: String,
    pub device_name: String,
}

pub fn hash_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

pub fn generate_token() -> String {
    // Two UUIDs → 32 random bytes, URL-safe.
    let mut bytes = [0u8; 32];
    bytes[..16].copy_from_slice(Uuid::new_v4().as_bytes());
    bytes[16..].copy_from_slice(Uuid::new_v4().as_bytes());
    format!(
        "rhp_{}",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
    )
}

pub fn now_rfc3339() -> String {
    Utc::now().to_rfc3339()
}

pub fn create_device(
    db: &Db,
    user_id: &str,
    name: &str,
    platform: Option<&str>,
) -> ApiResult<(String, String)> {
    let device_id = Uuid::new_v4().to_string();
    let token = generate_token();
    let token_hash = hash_token(&token);
    let now = now_rfc3339();
    {
        let conn = db.conn();
        conn.execute(
            "INSERT INTO devices (id, user_id, name, platform, token_hash, created_at, last_seen_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
            params![device_id, user_id, name, platform, token_hash, now],
        )?;
    }
    Ok((device_id, token))
}

pub fn create_user_and_device(
    db: &Db,
    name: &str,
    platform: Option<&str>,
) -> ApiResult<(String, String, String)> {
    let user_id = Uuid::new_v4().to_string();
    let now = now_rfc3339();
    {
        let conn = db.conn();
        conn.execute(
            "INSERT INTO users (id, created_at) VALUES (?1, ?2)",
            params![user_id, now],
        )?;
    }
    db.ensure_lifetime_stats(&user_id, &now)?;
    let (device_id, token) = create_device(db, &user_id, name, platform)?;
    Ok((user_id, device_id, token))
}

pub fn lookup_bearer(db: &Db, token: &str) -> ApiResult<AuthUser> {
    let token_hash = hash_token(token);
    let now = now_rfc3339();
    let conn = db.conn();
    let row = conn.query_row(
        "SELECT id, user_id, name FROM devices
         WHERE token_hash = ?1 AND revoked_at IS NULL",
        params![token_hash],
        |r| {
            Ok(AuthUser {
                device_id: r.get(0)?,
                user_id: r.get(1)?,
                device_name: r.get(2)?,
            })
        },
    );
    match row {
        Ok(user) => {
            let _ = conn.execute(
                "UPDATE devices SET last_seen_at = ?1 WHERE id = ?2",
                params![now, user.device_id],
            );
            Ok(user)
        }
        Err(rusqlite::Error::QueryReturnedNoRows) => Err(ApiError::Unauthorized),
        Err(e) => Err(e.into()),
    }
}

impl FromRequestParts<Arc<crate::state::AppState>> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<crate::state::AppState>,
    ) -> Result<Self, Self::Rejection> {
        let auth = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or(ApiError::Unauthorized)?;
        let token = auth
            .strip_prefix("Bearer ")
            .or_else(|| auth.strip_prefix("bearer "))
            .ok_or(ApiError::Unauthorized)?
            .to_string();
        let state = Arc::clone(state);
        tokio::task::spawn_blocking(move || lookup_bearer(&state.db, &token))
            .await
            .map_err(|e| ApiError::Internal(e.into()))?
    }
}
