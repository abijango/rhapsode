use crate::auth::AuthUser;
use crate::db::max_f64;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::Json;
use chrono::{DateTime, Utc};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Debug, Serialize, Deserialize)]
pub struct ProgressBody {
    pub updated_at: String,
    pub audio_position_seconds: Option<f64>,
    pub audio_duration_seconds: Option<f64>,
    pub ebook_progression: Option<f64>,
    pub ebook_locator_json: Option<String>,
    pub is_finished: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct ProgressDto {
    pub item_id: String,
    pub audio_position_seconds: Option<f64>,
    pub audio_duration_seconds: Option<f64>,
    pub ebook_progression: Option<f64>,
    pub ebook_locator_json: Option<String>,
    pub is_finished: bool,
    pub finished_at: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ItemStatsBody {
    pub saved_seconds: Option<f64>,
    pub listened_seconds: Option<f64>,
    pub reading_seconds: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct ItemStatsDto {
    pub item_id: String,
    pub saved_seconds: f64,
    pub listened_seconds: f64,
    pub reading_seconds: f64,
    pub updated_at: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct LifetimeBody {
    pub saved_seconds: Option<f64>,
    pub played_seconds: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct LifetimeDto {
    pub saved_seconds: f64,
    pub played_seconds: f64,
    pub updated_at: String,
}

#[derive(Deserialize)]
pub struct ProgressListQuery {
    pub updated_since: Option<String>,
}

fn parse_ts(s: &str) -> ApiResult<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|_| ApiError::BadRequest(format!("invalid updated_at: {s}")))
}

fn item_exists(db: &crate::db::Db, id: &str) -> ApiResult<()> {
    let conn = db.conn();
    let n: i64 = conn.query_row(
        "SELECT COUNT(*) FROM library_items WHERE id = ?1",
        params![id],
        |r| r.get(0),
    )?;
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(())
}

pub async fn get_progress(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<ProgressDto>> {
    item_exists(&state.db, &id)?;
    let conn = state.db.conn();
    let row = conn.query_row(
        "SELECT audio_position_seconds, audio_duration_seconds, ebook_progression,
                ebook_locator_json, is_finished, finished_at, updated_at
         FROM progress WHERE item_id = ?1",
        params![id],
        |r| {
            Ok(ProgressDto {
                item_id: id.clone(),
                audio_position_seconds: r.get(0)?,
                audio_duration_seconds: r.get(1)?,
                ebook_progression: r.get(2)?,
                ebook_locator_json: r.get(3)?,
                is_finished: r.get::<_, i64>(4)? != 0,
                finished_at: r.get(5)?,
                updated_at: r.get(6)?,
            })
        },
    );
    match row {
        Ok(p) => Ok(Json(p)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(Json(ProgressDto {
            item_id: id,
            audio_position_seconds: None,
            audio_duration_seconds: None,
            ebook_progression: None,
            ebook_locator_json: None,
            is_finished: false,
            finished_at: None,
            updated_at: "1970-01-01T00:00:00Z".into(),
        })),
        Err(e) => Err(e.into()),
    }
}

pub async fn put_progress(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Path(id): Path<String>,
    Json(body): Json<ProgressBody>,
) -> ApiResult<Json<ProgressDto>> {
    item_exists(&state.db, &id)?;
    let incoming_ts = parse_ts(&body.updated_at)?;
    let conn = state.db.conn();

    let existing: Option<(String, Option<f64>, Option<f64>, Option<f64>, Option<String>, i64, Option<String>)> =
        conn
            .query_row(
                "SELECT updated_at, audio_position_seconds, audio_duration_seconds, ebook_progression,
                        ebook_locator_json, is_finished, finished_at
                 FROM progress WHERE item_id = ?1",
                params![id],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                    ))
                },
            )
            .ok();

    if let Some((ref old_ts, _, _, _, _, _, _)) = existing {
        if let Ok(old) = parse_ts(old_ts) {
            if incoming_ts < old {
                // LWW reject older
                return get_progress_inner(&state, &id);
            }
        }
    }

    let (mut pos, mut dur, mut eprog, mut eloc, mut finished, mut finished_at) =
        if let Some((_, p, d, e, l, f, fa)) = existing {
            (p, d, e, l, f != 0, fa)
        } else {
            (None, None, None, None, false, None)
        };

    if let Some(v) = body.audio_position_seconds {
        pos = Some(v);
    }
    if let Some(v) = body.audio_duration_seconds {
        dur = Some(v);
    }
    if let Some(v) = body.ebook_progression {
        eprog = Some(v);
    }
    if let Some(v) = body.ebook_locator_json {
        eloc = Some(v);
    }
    if let Some(v) = body.is_finished {
        finished = v;
        if v && finished_at.is_none() {
            finished_at = Some(body.updated_at.clone());
        }
        if !v {
            finished_at = None;
        }
    }

    conn.execute(
        "INSERT INTO progress (item_id, audio_position_seconds, audio_duration_seconds,
           ebook_progression, ebook_locator_json, is_finished, finished_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(item_id) DO UPDATE SET
           audio_position_seconds = excluded.audio_position_seconds,
           audio_duration_seconds = excluded.audio_duration_seconds,
           ebook_progression = excluded.ebook_progression,
           ebook_locator_json = excluded.ebook_locator_json,
           is_finished = excluded.is_finished,
           finished_at = excluded.finished_at,
           updated_at = excluded.updated_at",
        params![
            id,
            pos,
            dur,
            eprog,
            eloc,
            finished as i64,
            finished_at,
            body.updated_at
        ],
    )?;

    drop(conn);
    get_progress_inner(&state, &id)
}

fn get_progress_inner(state: &AppState, id: &str) -> ApiResult<Json<ProgressDto>> {
    let conn = state.db.conn();
    let p = conn.query_row(
        "SELECT audio_position_seconds, audio_duration_seconds, ebook_progression,
                ebook_locator_json, is_finished, finished_at, updated_at
         FROM progress WHERE item_id = ?1",
        params![id],
        |r| {
            Ok(ProgressDto {
                item_id: id.to_string(),
                audio_position_seconds: r.get(0)?,
                audio_duration_seconds: r.get(1)?,
                ebook_progression: r.get(2)?,
                ebook_locator_json: r.get(3)?,
                is_finished: r.get::<_, i64>(4)? != 0,
                finished_at: r.get(5)?,
                updated_at: r.get(6)?,
            })
        },
    )?;
    Ok(Json(p))
}

pub async fn list_progress(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Query(q): Query<ProgressListQuery>,
) -> ApiResult<Json<serde_json::Value>> {
    let conn = state.db.conn();
    let mut sql = String::from(
        "SELECT item_id, audio_position_seconds, audio_duration_seconds, ebook_progression,
                ebook_locator_json, is_finished, finished_at, updated_at FROM progress",
    );
    if q.updated_since.is_some() {
        sql.push_str(" WHERE updated_at > ?1");
    }
    let mut stmt = conn.prepare(&sql)?;
    let map = |r: &rusqlite::Row| {
        Ok(ProgressDto {
            item_id: r.get(0)?,
            audio_position_seconds: r.get(1)?,
            audio_duration_seconds: r.get(2)?,
            ebook_progression: r.get(3)?,
            ebook_locator_json: r.get(4)?,
            is_finished: r.get::<_, i64>(5)? != 0,
            finished_at: r.get(6)?,
            updated_at: r.get(7)?,
        })
    };
    let rows: Vec<ProgressDto> = if let Some(since) = &q.updated_since {
        stmt.query_map(params![since], map)?
            .collect::<Result<Vec<_>, _>>()?
    } else {
        stmt.query_map([], map)?.collect::<Result<Vec<_>, _>>()?
    };
    Ok(Json(serde_json::json!({ "items": rows })))
}

pub async fn get_item_stats(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<Json<ItemStatsDto>> {
    item_exists(&state.db, &id)?;
    let conn = state.db.conn();
    match conn.query_row(
        "SELECT saved_seconds, listened_seconds, reading_seconds, updated_at
         FROM item_stats WHERE item_id = ?1",
        params![id],
        |r| {
            Ok(ItemStatsDto {
                item_id: id.clone(),
                saved_seconds: r.get(0)?,
                listened_seconds: r.get(1)?,
                reading_seconds: r.get(2)?,
                updated_at: r.get(3)?,
            })
        },
    ) {
        Ok(s) => Ok(Json(s)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(Json(ItemStatsDto {
            item_id: id,
            saved_seconds: 0.0,
            listened_seconds: 0.0,
            reading_seconds: 0.0,
            updated_at: "1970-01-01T00:00:00Z".into(),
        })),
        Err(e) => Err(e.into()),
    }
}

pub async fn put_item_stats(
    State(state): State<Arc<AppState>>,
    _user: AuthUser,
    Path(id): Path<String>,
    Json(body): Json<ItemStatsBody>,
) -> ApiResult<Json<ItemStatsDto>> {
    item_exists(&state.db, &id)?;
    let now = crate::auth::now_rfc3339();
    let conn = state.db.conn();
    let (cur_s, cur_l, cur_r): (f64, f64, f64) = conn
        .query_row(
            "SELECT saved_seconds, listened_seconds, reading_seconds FROM item_stats WHERE item_id = ?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap_or((0.0, 0.0, 0.0));

    let saved = if let Some(v) = body.saved_seconds {
        max_f64(cur_s, v)
    } else {
        cur_s
    };
    let listened = if let Some(v) = body.listened_seconds {
        max_f64(cur_l, v)
    } else {
        cur_l
    };
    let reading = if let Some(v) = body.reading_seconds {
        max_f64(cur_r, v)
    } else {
        cur_r
    };

    conn.execute(
        "INSERT INTO item_stats (item_id, saved_seconds, listened_seconds, reading_seconds, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(item_id) DO UPDATE SET
           saved_seconds = excluded.saved_seconds,
           listened_seconds = excluded.listened_seconds,
           reading_seconds = excluded.reading_seconds,
           updated_at = excluded.updated_at",
        params![id, saved, listened, reading, now],
    )?;
    Ok(Json(ItemStatsDto {
        item_id: id,
        saved_seconds: saved,
        listened_seconds: listened,
        reading_seconds: reading,
        updated_at: now,
    }))
}

pub async fn get_lifetime(
    State(state): State<Arc<AppState>>,
    user: AuthUser,
) -> ApiResult<Json<LifetimeDto>> {
    state
        .db
        .ensure_lifetime_stats(&user.user_id, &crate::auth::now_rfc3339())?;
    let conn = state.db.conn();
    let dto = conn.query_row(
        "SELECT saved_seconds, played_seconds, updated_at FROM lifetime_stats WHERE user_id = ?1",
        params![user.user_id],
        |r| {
            Ok(LifetimeDto {
                saved_seconds: r.get(0)?,
                played_seconds: r.get(1)?,
                updated_at: r.get(2)?,
            })
        },
    )?;
    Ok(Json(dto))
}

pub async fn put_lifetime(
    State(state): State<Arc<AppState>>,
    user: AuthUser,
    Json(body): Json<LifetimeBody>,
) -> ApiResult<Json<LifetimeDto>> {
    let now = crate::auth::now_rfc3339();
    state.db.ensure_lifetime_stats(&user.user_id, &now)?;
    let conn = state.db.conn();
    let (cur_s, cur_p): (f64, f64) = conn.query_row(
        "SELECT saved_seconds, played_seconds FROM lifetime_stats WHERE user_id = ?1",
        params![user.user_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let saved = if let Some(v) = body.saved_seconds {
        max_f64(cur_s, v)
    } else {
        cur_s
    };
    let played = if let Some(v) = body.played_seconds {
        max_f64(cur_p, v)
    } else {
        cur_p
    };
    conn.execute(
        "UPDATE lifetime_stats SET saved_seconds = ?1, played_seconds = ?2, updated_at = ?3
         WHERE user_id = ?4",
        params![saved, played, now, user.user_id],
    )?;
    Ok(Json(LifetimeDto {
        saved_seconds: saved,
        played_seconds: played,
        updated_at: now,
    }))
}
