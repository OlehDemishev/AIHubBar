//! API keys (docs/specs/SPEC-windows.md §3, §5): Windows' Credential Manager, a generic credential «ClaudePult API
//! key/<provider>» encrypted by DPAPI under the user — never a file, never `settings.json` or a `.claudepult` export.
//! Linux's Secret Service is not here yet; there (and in the Mac build for developing this one) keys aren't kept and
//! only servers without a key work.

use std::io;

/// The credential's name in Credential Manager.
pub fn target(provider: &str) -> String {
    format!("ClaudePult API key/{provider}")
}

/// Whether this system has somewhere to keep a key.
pub fn available() -> bool {
    cfg!(windows)
}

pub fn read(provider: &str) -> Option<String> {
    imp::read(&target(provider)).filter(|key| !key.is_empty())
}

pub fn save(provider: &str, key: &str) -> io::Result<()> {
    let key = key.trim();
    if key.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty key"));
    }
    imp::save(&target(provider), key)
}

pub fn delete(provider: &str) -> io::Result<()> {
    imp::delete(&target(provider))
}

#[cfg(windows)]
mod imp {
    use std::io;
    use windows_sys::Win32::Security::Credentials::{CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC};

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }

    pub fn save(target: &str, key: &str) -> io::Result<()> {
        let mut name = wide(target);
        let mut user = wide("AIHubBar");
        let mut blob = key.as_bytes().to_vec();
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: name.as_mut_ptr(),
            CredentialBlobSize: u32::try_from(blob.len()).map_err(io::Error::other)?,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: user.as_mut_ptr(),
            ..CREDENTIALW::default()
        };
        // SAFETY: every pointer is to a live buffer of this function; Windows copies them.
        if unsafe { CredWriteW(&credential, 0) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub fn read(target: &str) -> Option<String> {
        let name = wide(target);
        let mut found: *mut CREDENTIALW = std::ptr::null_mut();
        // SAFETY: `found` is set by Windows and freed with CredFree; the blob is read before that.
        unsafe {
            if CredReadW(name.as_ptr(), CRED_TYPE_GENERIC, 0, &mut found) == 0 || found.is_null() {
                return None;
            }
            let credential = &*found;
            let bytes = std::slice::from_raw_parts(credential.CredentialBlob, credential.CredentialBlobSize as usize);
            let key = String::from_utf8(bytes.to_vec()).ok();
            CredFree(found.cast());
            key
        }
    }

    pub fn delete(target: &str) -> io::Result<()> {
        let name = wide(target);
        // SAFETY: a live, NUL-ended name.
        if unsafe { CredDeleteW(name.as_ptr(), CRED_TYPE_GENERIC, 0) } == 0 {
            let error = io::Error::last_os_error();
            // ERROR_NOT_FOUND: nothing to delete is fine.
            if error.raw_os_error() != Some(1168) {
                return Err(error);
            }
        }
        Ok(())
    }
}

#[cfg(not(windows))]
mod imp {
    use std::io;

    pub fn save(_target: &str, _key: &str) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "no key store on this system yet"))
    }

    pub fn read(_target: &str) -> Option<String> {
        None
    }

    pub fn delete(_target: &str) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_in_the_system_store() {
        let provider = format!("test-{}", std::process::id());
        assert_eq!(target("openai"), "ClaudePult API key/openai");
        assert!(save(&provider, "  ").is_err(), "an empty key is refused");
        if available() {
            save(&provider, "sk-тест-123").unwrap();
            assert_eq!(read(&provider).as_deref(), Some("sk-тест-123"));
            save(&provider, "sk-new").unwrap();
            assert_eq!(read(&provider).as_deref(), Some("sk-new"), "saving again replaces");
            delete(&provider).unwrap();
            assert_eq!(read(&provider), None);
            delete(&provider).unwrap();
        } else {
            assert!(save(&provider, "k").is_err());
            assert_eq!(read(&provider), None);
        }
    }
}
