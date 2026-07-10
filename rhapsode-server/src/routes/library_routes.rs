use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult};
use crate::library;
use crate::state::AppState;
use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::Response;
use axum::Json;
use serde::Deserialize;
use std::sync::Arc;
use tokio::fs::File;
use tokio_util::io::ReaderStream;

#[derive(Deserialize)]
pub struct LibraryQuery {
    pub kind: Option<String>,
}

pub async fn list_library(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Query(q): Query<LibraryQuery>,
) -> ApiResult<Json<serde_json::Value>> {
    let items = library::list_items(&state.db, q.kind.as_deref())?;
    Ok(Json(serde_json::json!({ "items": items })))
}

pub async fn get_item(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<library::LibraryItemDto>> {
    Ok(Json(library::get_item(&state.db, &id)?))
}

pub async fn list_files(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let files = library::list_files(&state.db, &id)?;
    Ok(Json(serde_json::json!({ "files": files })))
}

pub async fn scan_library(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
) -> ApiResult<Json<serde_json::Value>> {
    if !state.try_begin_scan() {
        return Err(ApiError::Conflict("scan already running".into()));
    }
    let audio = state.config.library_audio.clone();
    let ebook = state.config.library_ebook.clone();
    let db_path = state.config.database_path();
    // Run scan on blocking thread; reopen is heavy — use same Db via spawn_blocking
    let state2 = state.clone();
    let report = tokio::task::spawn_blocking(move || {
        let result = library::scan_libraries(&state2.db, &audio, &ebook);
        state2.end_scan();
        result
    })
    .await
    .map_err(|e| ApiError::Internal(e.into()))??;

    let _ = db_path; // silence
    Ok(Json(serde_json::json!({
        "ok": true,
        "audio_items": report.audio_items,
        "ebook_items": report.ebook_items,
        "upserted": report.upserted,
    })))
}

pub async fn scan_status(State(state): State<Arc<AppState>>, _user: AuthUser) -> Json<serde_json::Value> {
    Json(serde_json::json!({ "running": state.scan_running() }))
}

pub async fn download_file(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Path((id, file_id)): Path<(String, String)>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let path = library::resolve_file_path(
        &state.db,
        &state.config.library_audio,
        &state.config.library_ebook,
        &id,
        &file_id,
    )?;

    let meta = tokio::fs::metadata(&path)
        .await
        .map_err(|_| ApiError::NotFound)?;
    let file_len = meta.len();
    let mime = mime_guess::from_path(&path)
        .first_or_octet_stream()
        .essence_str()
        .to_string();

    // Optional Range: bytes=start-end
    let range = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_bytes_range);

    if let Some((start, end_inclusive)) = range {
        if start >= file_len {
            return Err(ApiError::BadRequest("range not satisfiable".into()));
        }
        let end = end_inclusive.unwrap_or(file_len - 1).min(file_len - 1);
        if end < start {
            return Err(ApiError::BadRequest("invalid range".into()));
        }
        let len = end - start + 1;
        let mut file = File::open(&path)
            .await
            .map_err(|e| ApiError::Internal(e.into()))?;
        use tokio::io::{AsyncReadExt, AsyncSeekExt};
        file.seek(std::io::SeekFrom::Start(start))
            .await
            .map_err(|e| ApiError::Internal(e.into()))?;
        let limited = file.take(len);
        let stream = ReaderStream::new(limited);
        let body = Body::from_stream(stream);
        let mut res = Response::new(body);
        *res.status_mut() = StatusCode::PARTIAL_CONTENT;
        let headers = res.headers_mut();
        headers.insert(header::CONTENT_TYPE, HeaderValue::from_str(&mime).unwrap());
        headers.insert(
            header::CONTENT_LENGTH,
            HeaderValue::from_str(&len.to_string()).unwrap(),
        );
        headers.insert(
            header::CONTENT_RANGE,
            HeaderValue::from_str(&format!("bytes {start}-{end}/{file_len}")).unwrap(),
        );
        headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
        return Ok(res);
    }

    let file = File::open(&path)
        .await
        .map_err(|e| ApiError::Internal(e.into()))?;
    let stream = ReaderStream::new(file);
    let body = Body::from_stream(stream);
    let mut res = Response::new(body);
    let headers = res.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_str(&mime).unwrap());
    headers.insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&file_len.to_string()).unwrap(),
    );
    headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    let filename = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("download");
    if let Ok(v) = HeaderValue::from_str(&format!("attachment; filename=\"{filename}\"")) {
        headers.insert(header::CONTENT_DISPOSITION, v);
    }
    Ok(res)
}

fn parse_bytes_range(h: &str) -> Option<(u64, Option<u64>)> {
    let h = h.strip_prefix("bytes=")?;
    let (start, end) = h.split_once('-')?;
    let start: u64 = start.parse().ok()?;
    let end = if end.is_empty() {
        None
    } else {
        Some(end.parse().ok()?)
    };
    Some((start, end))
}


