use crate::cache::{Cache, CacheWrite, Storage};
use anyhow::{Context, Result, anyhow};
use std::io::Cursor;
use std::path::{Component, Path, PathBuf};

const SNAPSHOT_ENTRY: &str = "snapshot.tar";

pub(crate) async fn restore(storage: &dyn Storage, key: &str, directory: &Path) -> Result<bool> {
    let Cache::Hit(mut cache) = storage.get(key).await? else {
        return Ok(false);
    };
    let mut bytes = Vec::new();
    cache
        .get_object(SNAPSHOT_ENTRY, &mut bytes)
        .context("missing Rust incremental snapshot archive")?;

    std::fs::create_dir_all(directory).context("creating Rust incremental directory")?;
    let result = unpack_snapshot(&bytes, directory);
    if let Err(error) = result {
        let _ = std::fs::remove_dir_all(directory);
        return Err(error);
    }
    Ok(true)
}

pub(crate) async fn publish(storage: &dyn Storage, key: &str, directory: &Path) -> Result<()> {
    let archive = create_snapshot(directory)?;
    let mut entry = CacheWrite::new();
    entry.put_object(SNAPSHOT_ENTRY, &mut Cursor::new(archive), None)?;
    storage.put(key, entry).await?;
    Ok(())
}

fn create_snapshot(directory: &Path) -> Result<Vec<u8>> {
    let mut archive = tar::Builder::new(Vec::new());
    for item in walkdir::WalkDir::new(directory).follow_links(false) {
        let item = item?;
        let path = item.path();
        if path == directory {
            continue;
        }
        let relative = path
            .strip_prefix(directory)
            .context("incremental file escaped its root")?;
        if item.file_type().is_dir() {
            archive.append_dir(relative, path)?;
        } else if item.file_type().is_file() {
            archive.append_path_with_name(path, relative)?;
        } else {
            return Err(anyhow!(
                "unsupported file in incremental snapshot: {relative:?}"
            ));
        }
    }
    archive
        .into_inner()
        .context("finishing Rust incremental snapshot")
}

fn unpack_snapshot(bytes: &[u8], directory: &Path) -> Result<()> {
    for item in tar::Archive::new(Cursor::new(bytes)).entries()? {
        let mut item = item?;
        let relative = item.path()?.into_owned();
        if relative.as_os_str().is_empty()
            || relative
                .components()
                .any(|component| !matches!(component, Component::Normal(_)))
            || !(item.header().entry_type().is_file() || item.header().entry_type().is_dir())
        {
            return Err(anyhow!(
                "unsafe entry in Rust incremental snapshot: {relative:?}"
            ));
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_round_trip_preserves_incremental_files() {
        let source = tempfile::tempdir().unwrap();
        std::fs::create_dir(source.path().join("session")).unwrap();
        std::fs::write(source.path().join("session/dep-graph.bin"), b"state").unwrap();

        let archive = create_snapshot(source.path()).unwrap();
        let restored = tempfile::tempdir().unwrap();
        unpack_snapshot(&archive, restored.path()).unwrap();

        assert_eq!(
            std::fs::read(restored.path().join("session/dep-graph.bin")).unwrap(),
            b"state"
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

        assert!(unpack_snapshot(&archive, restored.path()).is_err());
        assert!(!restored.path().parent().unwrap().join("escape").exists());
    }
}
