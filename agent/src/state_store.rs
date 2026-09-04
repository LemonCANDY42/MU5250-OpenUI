use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use rand_core::{OsRng, RngCore};
use serde::de::DeserializeOwned;
use serde::Serialize;

#[derive(Clone)]
pub struct StateStore {
    root: PathBuf,
}

pub struct StateLock {
    _file: File,
}

impl StateStore {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, String> {
        let root = root.as_ref().to_path_buf();
        match fs::symlink_metadata(&root) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() || !metadata.is_dir() {
                    return Err("state root must be a real directory".into());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir_all(&root).map_err(|error| format!("create state root: {error}"))?;
            }
            Err(error) => return Err(format!("inspect state root: {error}")),
        }
        let root_mode = fs::metadata(&root)
            .map_err(|error| format!("inspect state root: {error}"))?
            .permissions()
            .mode()
            & 0o777;
        if root_mode != 0o700 {
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
                .map_err(|error| format!("protect state root: {error}"))?;
        }
        Ok(Self { root })
    }

    #[cfg(test)]
    fn root(&self) -> &Path {
        &self.root
    }

    pub fn read_json<T: DeserializeOwned>(&self, name: &str) -> Result<Option<T>, String> {
        let path = self.path(name)?;
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
                return Err(format!("state entry {name} is not a regular file"));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(format!("inspect state file {name}: {error}")),
        }
        let mut file = match File::open(&path) {
            Ok(file) => file,
            Err(error) => return Err(format!("open state file {name}: {error}")),
        };
        let metadata = file
            .metadata()
            .map_err(|error| format!("inspect state file {name}: {error}"))?;
        if !metadata.is_file() {
            return Err(format!("state entry {name} is not a regular file"));
        }
        if metadata.permissions().mode() & 0o777 != 0o600 {
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
                .map_err(|error| format!("protect state file {name}: {error}"))?;
        }
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)
            .map_err(|error| format!("read state file {name}: {error}"))?;
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|error| format!("parse state file {name}: {error}"))
    }

    pub fn write_json<T: Serialize>(&self, name: &str, value: &T) -> Result<(), String> {
        let bytes = serde_json::to_vec(value)
            .map_err(|error| format!("serialize state file {name}: {error}"))?;
        self.write_atomic(name, &bytes)
    }

    pub fn remove(&self, name: &str) -> Result<bool, String> {
        let path = self.path(name)?;
        match fs::remove_file(path) {
            Ok(()) => {
                self.sync_root()?;
                Ok(true)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(format!("remove state file {name}: {error}")),
        }
    }

    pub fn lock_exclusive(&self, name: &str) -> Result<StateLock, String> {
        let path = self.path(name)?;
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
                return Err(format!("state lock {name} is not a regular file"));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("inspect state lock {name}: {error}")),
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&path)
            .map_err(|error| format!("open state lock {name}: {error}"))?;
        let mode = file
            .metadata()
            .map_err(|error| format!("inspect state lock {name}: {error}"))?
            .permissions()
            .mode()
            & 0o777;
        if mode != 0o600 {
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
                .map_err(|error| format!("protect state lock {name}: {error}"))?;
        }
        fs2::FileExt::lock_exclusive(&file)
            .map_err(|error| format!("lock state {name}: {error}"))?;
        Ok(StateLock { _file: file })
    }

    pub(crate) fn root_path(&self) -> &Path {
        &self.root
    }

    fn write_atomic(&self, name: &str, bytes: &[u8]) -> Result<(), String> {
        let destination = self.path(name)?;
        let mut random = [0u8; 8];
        OsRng.fill_bytes(&mut random);
        let suffix = random
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let temporary = self.root.join(format!(".{name}.{suffix}.tmp"));

        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)
                .map_err(|error| format!("create temporary state file: {error}"))?;
            file.write_all(bytes)
                .map_err(|error| format!("write temporary state file: {error}"))?;
            file.sync_all()
                .map_err(|error| format!("sync temporary state file: {error}"))?;
            fs::rename(&temporary, &destination)
                .map_err(|error| format!("publish state file {name}: {error}"))?;
            fs::set_permissions(&destination, fs::Permissions::from_mode(0o600))
                .map_err(|error| format!("protect state file {name}: {error}"))?;
            self.sync_root()
        })();

        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    fn sync_root(&self) -> Result<(), String> {
        File::open(&self.root)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("sync state root: {error}"))
    }

    fn path(&self, name: &str) -> Result<PathBuf, String> {
        if name.is_empty()
            || name.contains('/')
            || name.contains('\\')
            || name == "."
            || name == ".."
        {
            return Err("invalid state filename".into());
        }
        Ok(self.root.join(name))
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Serialize, Deserialize, PartialEq)]
    struct Fixture {
        value: String,
    }

    #[test]
    fn state_is_atomic_and_private() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("state");
        let store = StateStore::open(&root).unwrap();
        assert_eq!(
            fs::metadata(store.root()).unwrap().permissions().mode() & 0o777,
            0o700
        );

        store
            .write_json(
                "fixture.json",
                &Fixture {
                    value: "first".into(),
                },
            )
            .unwrap();
        store
            .write_json(
                "fixture.json",
                &Fixture {
                    value: "second".into(),
                },
            )
            .unwrap();

        assert_eq!(
            store.read_json::<Fixture>("fixture.json").unwrap(),
            Some(Fixture {
                value: "second".into()
            })
        );
        assert_eq!(
            fs::metadata(root.join("fixture.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(fs::read_dir(root).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".tmp")));
    }

    #[test]
    fn state_reads_reject_symlinks_and_repair_existing_file_mode() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("state");
        let store = StateStore::open(&root).unwrap();
        let outside = temp.path().join("outside.json");
        fs::write(&outside, br#"{"value":"outside"}"#).unwrap();
        symlink(&outside, root.join("linked.json")).unwrap();
        assert!(store.read_json::<Fixture>("linked.json").is_err());

        let existing = root.join("existing.json");
        fs::write(&existing, br#"{"value":"existing"}"#).unwrap();
        fs::set_permissions(&existing, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            store.read_json::<Fixture>("existing.json").unwrap(),
            Some(Fixture {
                value: "existing".into()
            })
        );
        assert_eq!(
            fs::metadata(existing).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn state_lock_file_is_private_and_reusable() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("state");
        let first = StateStore::open(&root).unwrap();
        let second = StateStore::open(&root).unwrap();
        drop(first.lock_exclusive("auth.lock").unwrap());
        assert!(second.lock_exclusive("auth.lock").is_ok());
        assert_eq!(
            fs::metadata(root.join("auth.lock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
