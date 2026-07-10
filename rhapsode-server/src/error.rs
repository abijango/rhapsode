use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;
use thiserror::Error;

pub type ApiResult<T> = Result<T, ApiError>;

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("not found")]
    NotFound,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("conflict: {0}")]
    Conflict(String),
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
    #[error(transparent)]
    Db(#[from] rusqlite::Error),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code, message) = match &self {
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized", self.to_string()),
            ApiError::Forbidden(m) => (StatusCode::FORBIDDEN, "forbidden", m.clone()),
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not_found", self.to_string()),
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, "bad_request", m.clone()),
            ApiError::Conflict(m) => (StatusCode::CONFLICT, "conflict", m.clone()),
            ApiError::Internal(e) => {
                tracing::error!(error = %e, "internal error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal",
                    "internal server error".into(),
                )
            }
            ApiError::Db(e) => {
                tracing::error!(error = %e, "db error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal",
                    "database error".into(),
                )
            }
        };
        (
            status,
            Json(json!({ "error": code, "message": message })),
        )
            .into_response()
    }
}
