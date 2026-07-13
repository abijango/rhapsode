use crate::auth::now_rfc3339;
use crate::db::Db;
use crate::error::{ApiError, ApiResult};
use rusqlite::params;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use uuid::Uuid;

const AUDIO_EXT: &[&str] = &["m4b", "m4a", "mp3", "flac", "aac", "ogg", "opus", "wav"];
const EBOOK_EXT: &[&str] = &["epub"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanMode {
    /// Only touch new/changed/deleted files (default).
    Incremental,
    /// Re-upsert every discovered item (manual rebuild).
    Full,
}

impl ScanMode {
    pub fn parse(s: Option<&str>) -> Self {
        match s.map(|s| s.to_ascii_lowercase()).as_deref() {
            Some("full") | Some("rebuild") => Self::Full,
            _ => Self::Incremental,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct PrimaryFileDto {
    pub id: String,
    pub role: String,
    pub name: String,
    pub size_bytes: Option<i64>,
    pub sort_order: i64,
}

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
    /// Primary media file for the item kind (avoids N+1 client list_files).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary_file: Option<PrimaryFileDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MediaFileDto {
    pub id: String,
    pub role: String,
    pub name: String,
    pub size_bytes: Option<i64>,
    pub sort_order: i64,
}

#[derive(Debug, Clone)]
struct DiscoveredFile {
    role: &'static str,
    rel_path: String,
    size: u64,
    mtime_secs: i64,
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
    let rel = parent.strip_prefix(root).ok()?;
    let mut comps = rel.components();
    let first = comps.next()?;
    let name = first.as_os_str().to_str()?.to_string();
    Some(name)
}

fn file_meta(path: &Path) -> (u64, i64) {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return (0, 0),
    };
    let size = meta.len();
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    (size, mtime)
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

    audio_files_here.sort();

    let at_root = dir == root;
    if at_root {
        for path in &audio_files_here {
            out.push(single_audio_item(root, path)?);
        }
    } else if audio_files_here.len() == 1 {
        out.push(single_audio_item(root, &audio_files_here[0])?);
    } else if audio_files_here.len() > 1 {
        let mut files = Vec::new();
        for (i, path) in audio_files_here.iter().enumerate() {
            let rel = path
                .strip_prefix(root)
                .unwrap_or(path)
                .to_string_lossy()
                .replace('\\', "/");
            let (size, mtime_secs) = file_meta(path);
            files.push(DiscoveredFile {
                role: "audio",
                rel_path: rel,
                size,
                mtime_secs,
                sort_order: i as i32,
            });
        }
        let title = dir
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("Unknown")
            .to_string();
        let author = dir
            .parent()
            .filter(|p| *p != root)
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .map(|s| s.to_string());
        // Stable key: directory path, not file sizes (sizes change → would fork items).
        let dir_rel = dir
            .strip_prefix(root)
            .unwrap_or(dir)
            .to_string_lossy()
            .replace('\\', "/");
        let content_key = format!("audio:dir:{dir_rel}");
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

fn single_audio_item(root: &Path, path: &Path) -> ApiResult<DiscoveredItem> {
    let rel = path
        .strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/");
    let (size, mtime_secs) = file_meta(path);
    let files = vec![DiscoveredFile {
        role: "audio",
        rel_path: rel.clone(),
        size,
        mtime_secs,
        sort_order: 0,
    }];
    // Stable key by path (not size) so growth/trim doesn't fork the item.
    Ok(DiscoveredItem {
        content_key: format!("audio:file:{rel}"),
        kind: "audio".into(),
        title: title_from_path(path),
        author: author_from_parent(path, root),
        rel_path: rel,
        files,
    })
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
        let (size, mtime_secs) = file_meta(&path);
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
            mtime_secs,
            sort_order: 0,
        }];
        out.push(DiscoveredItem {
            content_key: format!("ebook:file:{rel}"),
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
    pub skipped_unchanged: usize,
    pub removed: usize,
    pub mode: &'static str,
}

/// Walk disk first (no DB lock), then apply short DB transactions.
/// Incremental mode skips items whose file size+mtime all match the catalogue.
pub fn scan_libraries(
    db: &Db,
    audio_root: &Path,
    ebook_root: &Path,
    mode: ScanMode,
) -> ApiResult<ScanReport> {
    // 1) Expensive FS work without holding SQLite.
    let audio = collect_audio(audio_root)?;
    let ebooks = collect_ebooks(ebook_root)?;
    let audio_count = audio.len();
    let ebook_count = ebooks.len();
    let discovered: Vec<DiscoveredItem> = audio.into_iter().chain(ebooks.into_iter()).collect();
    let now = now_rfc3339();

    // 2) Snapshot existing catalogue under a short lock.
    // by_key: content_key -> item_id
    // by_rel: media rel_path -> item_id (for content_key format migrations)
    // existing_files: rel_path -> (size, mtime)
    let (existing_by_key, by_rel, existing_files) = {
        let conn = db.conn();
        let mut by_key: HashMap<String, String> = HashMap::new();
        let mut stmt = conn.prepare("SELECT id, content_key FROM library_items")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(1)?, r.get::<_, String>(0)?)))?;
        for row in rows {
            let (key, id) = row?;
            by_key.insert(key, id);
        }

        let mut by_rel: HashMap<String, String> = HashMap::new();
        let mut files: HashMap<String, (i64, i64)> = HashMap::new();
        let mut fstmt = conn.prepare(
            "SELECT item_id, rel_path, COALESCE(size_bytes, 0), COALESCE(mtime_secs, 0)
             FROM media_files",
        )?;
        let frows = fstmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })?;
        for row in frows {
            let (item_id, rel, size, mtime) = row?;
            by_rel.entry(rel.clone()).or_insert(item_id);
            files.insert(rel, (size, mtime));
        }
        (by_key, by_rel, files)
    };

    let mut upserted = 0usize;
    let mut skipped = 0usize;
    let mut seen_ids: HashSet<String> = HashSet::new();

    for item in &discovered {
        // Resolve existing row: new stable key, or legacy path match.
        let existing_id = existing_by_key
            .get(&item.content_key)
            .cloned()
            .or_else(|| {
                item.files
                    .first()
                    .and_then(|f| by_rel.get(&f.rel_path).cloned())
            });

        let unchanged = mode == ScanMode::Incremental
            && existing_id.is_some()
            && item_files_unchanged(item, &existing_files);

        if let Some(ref id) = existing_id {
            seen_ids.insert(id.clone());
        }

        if unchanged {
            if let Some(id) = existing_id {
                let conn = db.conn();
                // Refresh content_key to stable form if this was a legacy row.
                conn.execute(
                    "UPDATE library_items SET missing = 0, content_key = ?1, title = ?2, author = ?3
                     WHERE id = ?4",
                    params![item.content_key, item.title, item.author, id],
                )?;
            }
            skipped += 1;
            continue;
        }
        let id = upsert_item(db, item, &now, existing_id.as_deref())?;
        seen_ids.insert(id);
        upserted += 1;
    }

    // 3) Remove items not seen this walk.
    let removed = {
        let conn = db.conn();
        let mut stmt = conn.prepare("SELECT id FROM library_items")?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        let mut gone = 0usize;
        for id in rows {
            if !seen_ids.contains(&id) {
                conn.execute("DELETE FROM library_items WHERE id = ?1", params![id])?;
                gone += 1;
            }
        }
        gone
    };

    Ok(ScanReport {
        audio_items: audio_count,
        ebook_items: ebook_count,
        upserted,
        skipped_unchanged: skipped,
        removed,
        mode: match mode {
            ScanMode::Full => "full",
            ScanMode::Incremental => "incremental",
        },
    })
}

fn item_files_unchanged(
    item: &DiscoveredItem,
    existing: &HashMap<String, (i64, i64)>,
) -> bool {
    if item.files.is_empty() {
        return false;
    }
    for f in &item.files {
        match existing.get(&f.rel_path) {
            Some(&(size, mtime))
                if size == f.size as i64 && mtime == f.mtime_secs => {}
            _ => return false,
        }
    }
    true
}

fn upsert_item(
    db: &Db,
    item: &DiscoveredItem,
    now: &str,
    existing_id: Option<&str>,
) -> ApiResult<String> {
    let conn = db.conn();
    let existing: Option<String> = existing_id.map(|s| s.to_string()).or_else(|| {
        conn.query_row(
            "SELECT id FROM library_items WHERE content_key = ?1",
            params![item.content_key],
            |r| r.get(0),
        )
        .ok()
    });

    let item_id = if let Some(id) = existing {
        conn.execute(
            "UPDATE library_items SET content_key = ?1, kind = ?2, title = ?3, author = ?4, rel_path = ?5,
             missing = 0, updated_at = ?6 WHERE id = ?7",
            params![
                item.content_key,
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
            "INSERT INTO media_files
             (id, item_id, role, rel_path, size_bytes, duration_seconds, sort_order, mtime_secs)
             VALUES (?1, ?2, ?3, ?4, ?5, NULL, ?6, ?7)",
            params![
                fid,
                item_id,
                f.role,
                f.rel_path,
                f.size as i64,
                f.sort_order,
                f.mtime_secs
            ],
        )?;
    }
    Ok(item_id)
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
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
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

    let mut out = Vec::with_capacity(rows.len());
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
        let role = if kind == "audio" { "audio" } else { "ebook" };
        let primary_file = load_primary_file(&conn, &id, role)?;
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
            primary_file,
        });
    }
    Ok(out)
}

fn load_primary_file(
    conn: &rusqlite::Connection,
    item_id: &str,
    role: &str,
) -> ApiResult<Option<PrimaryFileDto>> {
    let mut stmt = conn.prepare(
        "SELECT id, role, rel_path, size_bytes, sort_order FROM media_files
         WHERE item_id = ?1 AND role = ?2
         ORDER BY sort_order, rel_path LIMIT 1",
    )?;
    let mut rows = stmt.query(params![item_id, role])?;
    if let Some(r) = rows.next()? {
        let rel: String = r.get(2)?;
        let name = Path::new(&rel)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or(&rel)
            .to_string();
        Ok(Some(PrimaryFileDto {
            id: r.get(0)?,
            role: r.get(1)?,
            name,
            size_bytes: r.get(3)?,
            sort_order: r.get(4)?,
        }))
    } else {
        Ok(None)
    }
}

pub fn get_item(db: &Db, id: &str) -> ApiResult<LibraryItemDto> {
    list_items(db, None)?
        .into_iter()
        .find(|i| i.id == id)
        .ok_or(ApiError::NotFound)
}

pub fn list_files(db: &Db, item_id: &str) -> ApiResult<Vec<MediaFileDto>> {
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
    let full = full.canonicalize().map_err(|_| ApiError::NotFound)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;

    #[test]
    fn flat_m4b_files_are_separate_items() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("audio");
        fs::create_dir_all(&audio).unwrap();
        for name in [
            "Book 1 - Philosopher.m4b",
            "Book 2 - Chamber.m4b",
            "Book 3 - Azkaban.m4b",
        ] {
            let mut f = fs::File::create(audio.join(name)).unwrap();
            f.write_all(b"x").unwrap();
        }
        let ebook = dir.path().join("ebook");
        fs::create_dir_all(&ebook).unwrap();

        let items = collect_audio(&audio).unwrap();
        assert_eq!(items.len(), 3, "each root m4b should be its own book");
        let titles: Vec<_> = items.iter().map(|i| i.title.as_str()).collect();
        assert!(titles.contains(&"Book 1 - Philosopher"));
        assert!(titles.contains(&"Book 2 - Chamber"));
        assert!(!titles.iter().any(|t| *t == "audio"));
    }

    #[test]
    fn incremental_skips_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("audio");
        let ebook = dir.path().join("ebook");
        fs::create_dir_all(&audio).unwrap();
        fs::create_dir_all(&ebook).unwrap();
        fs::write(audio.join("Only.m4b"), b"abc").unwrap();

        let db_path = dir.path().join("t.db");
        let db = Db::open(&db_path).unwrap();
        let r1 = scan_libraries(&db, &audio, &ebook, ScanMode::Full).unwrap();
        assert_eq!(r1.upserted, 1);
        let r2 = scan_libraries(&db, &audio, &ebook, ScanMode::Incremental).unwrap();
        assert_eq!(r2.upserted, 0);
        assert_eq!(r2.skipped_unchanged, 1);

        fs::write(audio.join("Only.m4b"), b"abcd").unwrap();
        let r3 = scan_libraries(&db, &audio, &ebook, ScanMode::Incremental).unwrap();
        assert_eq!(r3.upserted, 1);
    }
}
