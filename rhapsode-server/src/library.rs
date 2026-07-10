use crate::auth::now_rfc3339;
use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use rusqlite::params;
use serde::Serialize;
use std::path::{Path, PathBuf};
use uuid::Uuid;

const AUDIO_EXT: &[&str] = &["m4b", "m4a", "mp3", "flac", "aac", "ogg", "opus", "wav"];
const EBOOK_EXT: &[&str] = &["epub"];

#[derive(Debug, Clone, Serialize)]
pub struct LibraryItemDto {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub author: Option<String>,
    pub duration_seconds: Option<f64>,
    pub missing: bool,
    pub has_audio: bool,
    pub has_ebook: bool,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MediaFileDto {
    pub id: String,
    pub role: String,
    pub name: String,
    pub size_bytes: Option<i64>,
    pub sort_order: i64,
}

#[derive(Debug)]
struct DiscoveredFile {
    role: &'static str,
    rel_path: String,
    size: u64,
    sort_order: i32,
}

#[derive(Debug)]
struct DiscoveredItem {
    content_key: String,
    kind: String,
    title: String,
    author: Option<String>,
    rel_path: String,
    files: Vec<DiscoveredFile>,
}

fn is_skipped_name(name: &str) -> bool {
    name.starts_with('.')
        || name == "@eaDir"
        || name == "#recycle"
        || name.eq_ignore_ascii_case("done")
        || name.eq_ignore_ascii_case("watched")
}

fn ext_of(path: &Path) -> Option<String> {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
}

fn title_from_path(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("Unknown")
        .to_string()
}

fn author_from_parent(path: &Path, root: &Path) -> Option<String> {
    let parent = path.parent()?;
    if parent == root {
        return None;
    }
    // Calibre: Author/Title (id)/file.epub → author = Author
    // Flat: root/file.m4b → None
    let rel = parent.strip_prefix(root).ok()?;
    let mut comps = rel.components();
    let first = comps.next()?;
    let name = first.as_os_str().to_str()?.to_string();
    if comps.next().is_some() || path.parent().map(|p| p != root).unwrap_or(false) {
        // if more than one level or we're in a titled folder under author
        return Some(name);
    }
    // single component parent under root: could be Author folder for multi-file
    Some(name)
}

fn collect_audio(root: &Path) -> ApiResult<Vec<DiscoveredItem>> {
    let mut items = Vec::new();
    if !root.exists() {
        return Ok(items);
    }
    walk_audio_dir(root, root, &mut items)?;
    Ok(items)
}

fn walk_audio_dir(root: &Path, dir: &Path, out: &mut Vec<DiscoveredItem>) -> ApiResult<()> {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .map_err(|e| ApiError::Internal(e.into()))?
        .filter_map(|e| e.ok())
        .collect();
    entries.sort_by_key(|e| e.file_name());

    let mut audio_files_here: Vec<PathBuf> = Vec::new();
    let mut subdirs: Vec<PathBuf> = Vec::new();

    for ent in entries {
        let name = ent.file_name().to_string_lossy().to_string();
        if is_skipped_name(&name) {
            continue;
        }
        let path = ent.path();
        if path.is_dir() {
            subdirs.push(path);
        } else if let Some(ext) = ext_of(&path) {
            if AUDIO_EXT.contains(&ext.as_str()) {
                audio_files_here.push(path);
            }
        }
    }

    if !audio_files_here.is_empty() {
        audio_files_here.sort();
        let mut files = Vec::new();
        for (i, path) in audio_files_here.iter().enumerate() {
            let rel = path
                .strip_prefix(root)
                .unwrap_or(path)
                .to_string_lossy()
                .replace('\\', "/");
            let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            files.push(DiscoveredFile {
                role: "audio",
                rel_path: rel,
                size,
                sort_order: i as i32,
            });
        }
        let first = &audio_files_here[0];
        let title = if audio_files_here.len() == 1 {
            title_from_path(first)
        } else {
            dir.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("Unknown")
                .to_string()
        };
        let author = author_from_parent(first, root);
        let content_key = format!(
            "audio:{}",
            files
                .iter()
                .map(|f| format!("{}:{}", f.rel_path, f.size))
                .collect::<Vec<_>>()
                .join("|")
        );
        let rel_path = files[0].rel_path.clone();
        out.push(DiscoveredItem {
            content_key,
            kind: "audio".into(),
            title,
            author,
            rel_path,
            files,
        });
    }

    for sub in subdirs {
        walk_audio_dir(root, &sub, out)?;
    }
    Ok(())
}

fn collect_ebooks(root: &Path) -> ApiResult<Vec<DiscoveredItem>> {
    let mut items = Vec::new();
    if !root.exists() {
        return Ok(items);
    }
    walk_ebook_dir(root, root, &mut items)?;
    Ok(items)
}

fn walk_ebook_dir(root: &Path, dir: &Path, out: &mut Vec<DiscoveredItem>) -> ApiResult<()> {
    let entries = std::fs::read_dir(dir).map_err(|e| ApiError::Internal(e.into()))?;
    for ent in entries.flatten() {
        let name = ent.file_name().to_string_lossy().to_string();
        if is_skipped_name(&name) {
            continue;
        }
        let path = ent.path();
        if path.is_dir() {
            walk_ebook_dir(root, &path, out)?;
            continue;
        }
        let Some(ext) = ext_of(&path) else {
            continue;
        };
        if !EBOOK_EXT.contains(&ext.as_str()) {
            continue;
        }
        let rel = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        // Calibre: Author/Title (n)/file.epub
        let author = path
            .parent()
            .and_then(|p| p.parent())
            .filter(|p| *p != root)
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .map(|s| s.to_string())
            .or_else(|| author_from_parent(&path, root));
        let title = path
            .parent()
            .filter(|p| *p != root)
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .map(|s| {
                // strip trailing " (123)" calibre id
                let s = s.trim();
                if let Some(idx) = s.rfind(" (") {
                    if s.ends_with(')') {
                        return s[..idx].to_string();
                    }
                }
                s.to_string()
            })
            .unwrap_or_else(|| title_from_path(&path));

        let files = vec![DiscoveredFile {
            role: "ebook",
            rel_path: rel.clone(),
            size,
            sort_order: 0,
        }];
        let content_key = format!("ebook:{}:{}", rel, size);
        out.push(DiscoveredItem {
            content_key,
            kind: "ebook".into(),
            title,
            author,
            rel_path: rel,
            files,
        });
    }
    Ok(())
}

pub struct ScanReport {
    pub audio_items: usize,
    pub ebook_items: usize,
    pub upserted: usize,
}

pub fn scan_libraries(db: &Db, audio_root: &Path, ebook_root: &Path) -> ApiResult<ScanReport> {
    let audio = collect_audio(audio_root)?;
    let ebooks = collect_ebooks(ebook_root)?;
    let audio_count = audio.len();
    let ebook_count = ebooks.len();
    let mut upserted = 0usize;
    let now = now_rfc3339();

    // Mark all missing first, clear when seen
    {
        let conn = db.conn();
        conn.execute("UPDATE library_items SET missing = 1", [])?;
    }

    for item in audio.into_iter().chain(ebooks.into_iter()) {
        upsert_item(db, &item, &now)?;
        upserted += 1;
    }

    Ok(ScanReport {
        audio_items: audio_count,
        ebook_items: ebook_count,
        upserted,
    })
}

fn upsert_item(db: &Db, item: &DiscoveredItem, now: &str) -> ApiResult<()> {
    let conn = db.conn();
    let existing: Option<String> = conn
        .query_row(
            "SELECT id FROM library_items WHERE content_key = ?1",
            params![item.content_key],
            |r| r.get(0),
        )
        .ok();

    let item_id = if let Some(id) = existing {
        conn.execute(
            "UPDATE library_items SET kind = ?1, title = ?2, author = ?3, rel_path = ?4,
             missing = 0, updated_at = ?5 WHERE id = ?6",
            params![
                item.kind,
                item.title,
                item.author,
                item.rel_path,
                now,
                id
            ],
        )?;
        conn.execute("DELETE FROM media_files WHERE item_id = ?1", params![id])?;
        id
    } else {
        let id = Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO library_items
             (id, content_key, kind, title, author, duration_seconds, rel_path, missing, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, 0, ?7, ?7)",
            params![
                id,
                item.content_key,
                item.kind,
                item.title,
                item.author,
                item.rel_path,
                now
            ],
        )?;
        id
    };

    for f in &item.files {
        let fid = Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO media_files (id, item_id, role, rel_path, size_bytes, duration_seconds, sort_order)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6)",
            params![
                fid,
                item_id,
                f.role,
                f.rel_path,
                f.size as i64,
                f.sort_order
            ],
        )?;
    }
    Ok(())
}

pub fn list_items(db: &Db, kind: Option<&str>) -> ApiResult<Vec<LibraryItemDto>> {
    let conn = db.conn();
    let mut sql = String::from(
        "SELECT id, kind, title, author, duration_seconds, missing, updated_at FROM library_items",
    );
    if kind.is_some() && kind != Some("all") {
        sql.push_str(" WHERE kind = ?1");
    }
    sql.push_str(" ORDER BY title COLLATE NOCASE");

    let mut stmt = conn.prepare(&sql)?;
    let map_row = |r: &rusqlite::Row| {
        let id: String = r.get(0)?;
        let kind: String = r.get(1)?;
        Ok((
            id,
            kind,
            r.get::<_, String>(2)?,
            r.get::<_, Option<String>>(3)?,
            r.get::<_, Option<f64>>(4)?,
            r.get::<_, i64>(5)? != 0,
            r.get::<_, String>(6)?,
        ))
    };

    let rows: Vec<_> = if let Some(k) = kind.filter(|k| *k != "all") {
        stmt.query_map(params![k], map_row)?
            .collect::<Result<Vec<_>, _>>()?
    } else {
        stmt.query_map([], map_row)?.collect::<Result<Vec<_>, _>>()?
    };

    let mut out = Vec::new();
    for (id, kind, title, author, duration_seconds, missing, updated_at) in rows {
        let has_audio: i64 = conn.query_row(
            "SELECT COUNT(*) FROM media_files WHERE item_id = ?1 AND role = 'audio'",
            params![id],
            |r| r.get(0),
        )?;
        let has_ebook: i64 = conn.query_row(
            "SELECT COUNT(*) FROM media_files WHERE item_id = ?1 AND role = 'ebook'",
            params![id],
            |r| r.get(0),
        )?;
        out.push(LibraryItemDto {
            id,
            kind,
            title,
            author,
            duration_seconds,
            missing,
            has_audio: has_audio > 0,
            has_ebook: has_ebook > 0,
            updated_at,
        });
    }
    Ok(out)
}

pub fn get_item(db: &Db, id: &str) -> ApiResult<LibraryItemDto> {
    list_items(db, None)?
        .into_iter()
        .find(|i| i.id == id)
        .ok_or(ApiError::NotFound)
}

pub fn list_files(db: &Db, item_id: &str) -> ApiResult<Vec<MediaFileDto>> {
    // ensure item exists
    let _ = get_item(db, item_id)?;
    let conn = db.conn();
    let mut stmt = conn.prepare(
        "SELECT id, role, rel_path, size_bytes, sort_order FROM media_files
         WHERE item_id = ?1 ORDER BY sort_order, rel_path",
    )?;
    let rows = stmt.query_map(params![item_id], |r| {
        let rel: String = r.get(2)?;
        let name = Path::new(&rel)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(&rel)
            .to_string();
        Ok(MediaFileDto {
            id: r.get(0)?,
            role: r.get(1)?,
            name,
            size_bytes: r.get(3)?,
            sort_order: r.get(4)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

pub fn resolve_file_path(
    db: &Db,
    audio_root: &Path,
    ebook_root: &Path,
    item_id: &str,
    file_id: &str,
) -> ApiResult<PathBuf> {
    let conn = db.conn();
    let (role, rel_path): (String, String) = conn
        .query_row(
            "SELECT role, rel_path FROM media_files WHERE id = ?1 AND item_id = ?2",
            params![file_id, item_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|_| ApiError::NotFound)?;

    let root = match role.as_str() {
        "audio" => audio_root,
        "ebook" => ebook_root,
        _ => return Err(ApiError::NotFound),
    };
    let full = root.join(&rel_path);
    // path traversal guard
    let full = full
        .canonicalize()
        .map_err(|_| ApiError::NotFound)?;
    let root_c = root
        .canonicalize()
        .map_err(|e| ApiError::Internal(e.into()))?;
    if !full.starts_with(&root_c) {
        return Err(ApiError::Forbidden("path outside library".into()));
    }
    if !full.is_file() {
        return Err(ApiError::NotFound);
    }
    Ok(full)
}
