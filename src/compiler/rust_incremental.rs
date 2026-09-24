use crate::cache::{Cache, CacheWrite, Storage};
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::path::{Component, Path, PathBuf};

const SNAPSHOT_ENTRY: &str = "snapshot.tar";
const INDEX_ENTRY: &str = "candidates.json";
const MAX_CANDIDATES: usize = 8;
const SNAPSHOT_FORMAT: &str = "rust-incremental-v3";

#[derive(Serialize, Deserialize)]
struct CandidateIndex {
    candidates: Vec<String>,
}

pub(crate) async fn restore(
    storage: &dyn Storage,
    namespace: &str,
    crate_name: &str,
    directory: &Path,
) -> Result<bool> {
    let Cache::Hit(mut cache) = storage.get(&index_key(namespace)).await? else {
        return Ok(false);
    };
    let mut index_bytes = Vec::new();
    cache
        .get_object(INDEX_ENTRY, &mut index_bytes)
        .context("missing Rust incremental candidate index")?;
    let index: CandidateIndex =
        serde_json::from_slice(&index_bytes).context("invalid Rust incremental candidate index")?;
    for object_id in index.candidates.into_iter().take(MAX_CANDIDATES) {
        let Cache::Hit(mut cache) = storage.get(&object_key(namespace, &object_id)).await? else {
            continue;
        };
        let mut bytes = Vec::new();
        if cache.get_object(SNAPSHOT_ENTRY, &mut bytes).is_err()
            || blake3::hash(&bytes).to_hex().as_str() != object_id
        {
            continue;
        }
        std::fs::create_dir_all(directory).context("creating Rust incremental directory")?;
        match unpack_snapshot(&bytes, crate_name, directory) {
            Ok(()) => return Ok(true),
            Err(error) => {
                let _ = discard_crate_state(directory, crate_name);
                return Err(error);
            }
        }
    }
    Ok(false)
}

pub(crate) async fn publish(
    storage: &dyn Storage,
    namespace: &str,
    crate_name: &str,
    directory: &Path,
) -> Result<()> {
    let archive = create_snapshot(crate_name, directory)?;
    let object_id = blake3::hash(&archive).to_hex().to_string();
    let mut entry = CacheWrite::new();
    entry.put_object(SNAPSHOT_ENTRY, &mut Cursor::new(archive), None)?;
    storage
        .put(&object_key(namespace, &object_id), entry)
        .await?;

    let key = index_key(namespace);
    let mut candidates = match storage.get(&key).await? {
        Cache::Hit(mut entry) => {
            let mut bytes = Vec::new();
            let _ = entry.get_object(INDEX_ENTRY, &mut bytes);
            serde_json::from_slice::<CandidateIndex>(&bytes)
                .map(|i| i.candidates)
                .unwrap_or_default()
        }
        _ => Vec::new(),
    };
    candidates.retain(|candidate| candidate != &object_id);
    candidates.insert(0, object_id);
    candidates.truncate(MAX_CANDIDATES);
    let mut entry = CacheWrite::new();
    entry.put_object(
        INDEX_ENTRY,
        &mut Cursor::new(serde_json::to_vec(&CandidateIndex { candidates })?),
        None,
    )?;
    // Concurrent writers can replace this hint. Snapshot objects remain immutable;
    // a lost index update can orphan an object but cannot corrupt another build.
    storage.put(&key, entry).await?;
    Ok(())
}

fn index_key(namespace: &str) -> String {
    format!("{SNAPSHOT_FORMAT}/{namespace}/index")
}
fn object_key(namespace: &str, id: &str) -> String {
    format!("{SNAPSHOT_FORMAT}/{namespace}/objects/{id}")
}

fn crate_state_path(path: &Path, crate_name: &str) -> bool {
    path.file_name().is_some_and(|name| {
        name.to_string_lossy()
            .starts_with(&format!("{crate_name}-"))
    })
}

fn create_snapshot(crate_name: &str, directory: &Path) -> Result<Vec<u8>> {
    let mut archive = tar::Builder::new(Vec::new());
    let mut found_state = false;
    for entry in std::fs::read_dir(directory).context("reading Rust incremental directory")? {
        let entry = entry?;
        let path = entry.path();
        if !crate_state_path(&path, crate_name) {
            continue;
        }
        found_state = true;
        for item in walkdir::WalkDir::new(&path).follow_links(false) {
            let item = item?;
            let item_path = item.path();
            let relative = item_path
                .strip_prefix(directory)
                .context("incremental file escaped its root")?;
            if item.file_type().is_dir() {
                archive.append_dir(relative, item_path)?;
            } else if item.file_type().is_file() {
                archive.append_path_with_name(item_path, relative)?;
            } else {
                return Err(anyhow!(
                    "unsupported file in incremental snapshot: {relative:?}"
                ));
            }
        }
    }
    if !found_state {
        return Err(anyhow!(
            "rustc produced no incremental state for {crate_name}"
        ));
    }
    archive
        .into_inner()
        .context("finishing Rust incremental snapshot")
}

fn unpack_snapshot(bytes: &[u8], crate_name: &str, directory: &Path) -> Result<()> {
    for item in tar::Archive::new(Cursor::new(bytes)).entries()? {
        let mut item = item?;
        let relative = item.path()?.into_owned();
        if relative.as_os_str().is_empty()
            || relative
                .components()
                .any(|component| !matches!(component, Component::Normal(_)))
            || !relative.components().next().is_some_and(|component| {
                component
                    .as_os_str()
                    .to_string_lossy()
                    .starts_with(&format!("{crate_name}-"))
            })
            || !(item.header().entry_type().is_file() || item.header().entry_type().is_dir())
        {
            return Err(anyhow!(
                "unsafe entry in Rust incremental snapshot: {relative:?}"
            ));
        }
        ensure_no_symlink_ancestors(directory, &relative)?;
        let destination = directory.join(PathBuf::from(relative));
        if item.header().entry_type().is_dir() {
            std::fs::create_dir_all(&destination)?;
        } else {
            let parent = destination
                .parent()
                .ok_or_else(|| anyhow!("snapshot file has no parent"))?;
            std::fs::create_dir_all(parent)?;
            item.unpack(&destination)?;
        }
    }
    Ok(())
}

fn ensure_no_symlink_ancestors(directory: &Path, relative: &Path) -> Result<()> {
    let mut path = directory.to_owned();
    if let Ok(metadata) = std::fs::symlink_metadata(&path) {
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(anyhow!("unsafe Rust incremental restore root: {path:?}"));
        }
    }
    let components = relative.components().collect::<Vec<_>>();
    for (index, component) in components.iter().enumerate() {
        path.push(component.as_os_str());
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink()
                    || (index + 1 < components.len() && !metadata.is_dir())
                {
                    return Err(anyhow!("unsafe Rust incremental restore path: {path:?}"));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

pub(crate) fn discard_crate_state(directory: &Path, crate_name: &str) -> Result<()> {
    let entries = match std::fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    for entry in entries {
        let path = entry?.path();
        if crate_state_path(&path, crate_name) {
            if std::fs::symlink_metadata(&path)?.file_type().is_dir() {
                std::fs::remove_dir_all(path)?;
            } else {
                std::fs::remove_file(path)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::CacheRead;
    use crate::config::PreprocessorCacheModeConfig;
    use async_trait::async_trait;
    use std::collections::HashMap;
    use std::sync::Mutex;
    use std::time::Duration;

    #[derive(Default)]
    struct MemoryStorage(
        Mutex<HashMap<String, Vec<u8>>>,
        Mutex<Option<std::sync::Arc<tokio::sync::Barrier>>>,
    );

    #[async_trait]
    impl Storage for MemoryStorage {
        async fn get(&self, key: &str) -> Result<Cache> {
            let value = self.0.lock().unwrap().get(key).cloned();
            let barrier = self.1.lock().unwrap().clone();
            if key == index_key("namespace")
                && let Some(barrier) = barrier
            {
                barrier.wait().await;
            }
            match value {
                Some(bytes) => Ok(Cache::Hit(CacheRead::from(Cursor::new(bytes))?)),
                None => Ok(Cache::Miss),
            }
        }

        async fn put(&self, key: &str, entry: CacheWrite) -> Result<Duration> {
            self.0
                .lock()
                .unwrap()
                .insert(key.to_owned(), entry.finish()?);
            Ok(Duration::ZERO)
        }

        async fn current_size(&self) -> Result<Option<u64>> {
            Ok(None)
        }
        async fn max_size(&self) -> Result<Option<u64>> {
            Ok(None)
        }
        fn location(&self) -> String {
            "memory test storage".to_owned()
        }
        fn preprocessor_cache_mode_config(&self) -> PreprocessorCacheModeConfig {
            PreprocessorCacheModeConfig::default()
        }
    }

    #[test]
    fn snapshot_round_trip_preserves_incremental_files() {
        let source = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(source.path().join("probe-hash/session")).unwrap();
        std::fs::write(
            source.path().join("probe-hash/session/dep-graph.bin"),
            b"state",
        )
        .unwrap();
        std::fs::create_dir_all(source.path().join("other-hash")).unwrap();
        std::fs::write(source.path().join("other-hash/untouched"), b"other crate").unwrap();

        let archive = create_snapshot("probe", source.path()).unwrap();
        let restored = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(restored.path().join("other-hash")).unwrap();
        std::fs::write(
            restored.path().join("other-hash/untouched"),
            b"local sibling",
        )
        .unwrap();
        unpack_snapshot(&archive, "probe", restored.path()).unwrap();

        assert_eq!(
            std::fs::read(restored.path().join("probe-hash/session/dep-graph.bin")).unwrap(),
            b"state"
        );
        assert_eq!(
            std::fs::read(restored.path().join("other-hash/untouched")).unwrap(),
            b"local sibling"
        );
    }

    #[test]
    fn snapshot_rejects_parent_traversal() {
        let mut archive = tar::Builder::new(Vec::new());
        let mut header = tar::Header::new_gnu();
        header.set_path("escape").unwrap();
        header.set_size(1);
        header.set_mode(0o600);
        header.set_cksum();
        archive.append(&header, &b"x"[..]).unwrap();
        let mut archive = archive.into_inner().unwrap();
        archive[..100].fill(0);
        archive[..9].copy_from_slice(b"../escape");
        archive[148..156].fill(b' ');
        let checksum: u32 = archive[..512].iter().map(|byte| u32::from(*byte)).sum();
        archive[148..156].copy_from_slice(format!("{checksum:06o}\0 ").as_bytes());
        let restored = tempfile::tempdir().unwrap();

        assert!(unpack_snapshot(&archive, "probe", restored.path()).is_err());
        assert!(!restored.path().parent().unwrap().join("escape").exists());
    }

    #[cfg(unix)]
    #[test]
    fn snapshot_rejects_preexisting_symlink_escape() {
        let source = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(source.path().join("probe-hash/session")).unwrap();
        std::fs::write(source.path().join("probe-hash/session/state"), b"payload").unwrap();
        let archive = create_snapshot("probe", source.path()).unwrap();

        let restored = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), restored.path().join("probe-hash")).unwrap();

        assert!(unpack_snapshot(&archive, "probe", restored.path()).is_err());
        assert!(!outside.path().join("session/state").exists());
    }

    #[tokio::test]
    async fn immutable_publication_restores_and_skips_evicted_or_corrupt_objects() {
        let storage = MemoryStorage::default();
        let source = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(source.path().join("probe-hash/session")).unwrap();
        std::fs::write(
            source.path().join("probe-hash/session/dep-graph.bin"),
            b"state",
        )
        .unwrap();
        publish(&storage, "namespace", "probe", source.path())
            .await
            .unwrap();

        let (object_key, object_bytes) = {
            let entries = storage.0.lock().unwrap();
            let (key, bytes) = entries
                .iter()
                .find(|(key, _)| key.contains("/objects/"))
                .unwrap();
            (key.clone(), bytes.clone())
        };
        let restored = tempfile::tempdir().unwrap();
        assert!(
            restore(&storage, "namespace", "probe", restored.path())
                .await
                .unwrap()
        );
        assert_eq!(
            std::fs::read(restored.path().join("probe-hash/session/dep-graph.bin")).unwrap(),
            b"state"
        );

        // An evicted object is a normal miss; it must not make the build fail.
        storage.0.lock().unwrap().remove(&object_key);
        let evicted = tempfile::tempdir().unwrap();
        assert!(
            !restore(&storage, "namespace", "probe", evicted.path())
                .await
                .unwrap()
        );

        // Corrupt bytes under the immutable id fail its digest check and are skipped.
        storage
            .0
            .lock()
            .unwrap()
            .insert(object_key.clone(), object_bytes);
        let mut corrupted = CacheWrite::new();
        corrupted
            .put_object(SNAPSHOT_ENTRY, &mut Cursor::new(b"truncated"), None)
            .unwrap();
        storage
            .0
            .lock()
            .unwrap()
            .insert(object_key, corrupted.finish().unwrap());
        let rejected = tempfile::tempdir().unwrap();
        assert!(
            !restore(&storage, "namespace", "probe", rejected.path())
                .await
                .unwrap()
        );
        assert!(std::fs::read_dir(rejected.path()).unwrap().next().is_none());
    }

    #[tokio::test]
    async fn concurrent_index_race_keeps_both_immutable_objects_and_a_usable_candidate() {
        let storage = std::sync::Arc::new(MemoryStorage::default());
        *storage.1.lock().unwrap() = Some(std::sync::Arc::new(tokio::sync::Barrier::new(2)));
        let first = tempfile::tempdir().unwrap();
        let second = tempfile::tempdir().unwrap();
        for (directory, value) in [
            (first.path(), &b"first"[..]),
            (second.path(), &b"second"[..]),
        ] {
            let crate_directory = directory.join("probe-hash/session");
            std::fs::create_dir_all(&crate_directory).unwrap();
            std::fs::write(crate_directory.join("work-product.o"), value).unwrap();
        }

        let (first_result, second_result) = tokio::join!(
            publish(storage.as_ref(), "namespace", "probe", first.path()),
            publish(storage.as_ref(), "namespace", "probe", second.path()),
        );
        first_result.unwrap();
        second_result.unwrap();
        *storage.1.lock().unwrap() = None;

        let entries = storage.0.lock().unwrap();
        let object_count = entries
            .keys()
            .filter(|key| key.contains("/objects/"))
            .count();
        let index_bytes = entries.get(&index_key("namespace")).unwrap();
        let mut cache = CacheRead::from(Cursor::new(index_bytes.clone())).unwrap();
        let mut index = Vec::new();
        cache.get_object(INDEX_ENTRY, &mut index).unwrap();
        let candidates: CandidateIndex = serde_json::from_slice(&index).unwrap();
        drop(entries);

        assert_eq!(object_count, 2);
        assert_eq!(candidates.candidates.len(), 1);
        let restored = tempfile::tempdir().unwrap();
        assert!(
            restore(storage.as_ref(), "namespace", "probe", restored.path())
                .await
                .unwrap()
        );
        let restored_value =
            std::fs::read(restored.path().join("probe-hash/session/work-product.o")).unwrap();
        assert!(restored_value == b"first" || restored_value == b"second");
    }

    #[tokio::test]
    async fn truncated_snapshot_with_valid_object_id_is_rejected_cleanly() {
        let storage = MemoryStorage::default();
        let source = tempfile::tempdir().unwrap();
        std::fs::create_dir(source.path().join("probe-hash")).unwrap();
        std::fs::write(source.path().join("probe-hash/state"), vec![b'x'; 4096]).unwrap();
        let mut archive = create_snapshot("probe", source.path()).unwrap();
        archive.truncate(600);
        let object_id = blake3::hash(&archive).to_hex().to_string();

        let mut object = CacheWrite::new();
        object
            .put_object(SNAPSHOT_ENTRY, &mut Cursor::new(archive), None)
            .unwrap();
        storage
            .put(&object_key("namespace", &object_id), object)
            .await
            .unwrap();
        let mut index = CacheWrite::new();
        index
            .put_object(
                INDEX_ENTRY,
                &mut Cursor::new(
                    serde_json::to_vec(&CandidateIndex {
                        candidates: vec![object_id],
                    })
                    .unwrap(),
                ),
                None,
            )
            .unwrap();
        storage.put(&index_key("namespace"), index).await.unwrap();

        let private = tempfile::tempdir().unwrap();
        assert!(
            restore(&storage, "namespace", "probe", private.path())
                .await
                .is_err()
        );
        assert!(!private.path().join("probe-hash").exists());
    }
}
