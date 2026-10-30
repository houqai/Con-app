use std::ffi::{c_char, CStr};

#[no_mangle]
pub unsafe extern "C" fn con_secret_store(
    name: *const c_char,
    bytes: *const u8,
    length: i32,
) -> i32 {
    if name.is_null() || length < 0 || (bytes.is_null() && length > 0) {
        return 1;
    }
    let (name, record) = unsafe { (CStr::from_ptr(name), bytes_of(bytes, length)) };
    if system::store(name, record) {
        0
    } else {
        1
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_secret_lookup(
    name: *const c_char,
    length: *mut i32,
    failed: *mut i32,
) -> *mut u8 {
    if length.is_null() || failed.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *length = 0;
        *failed = 0;
    }
    let found = if name.is_null() {
        Err(())
    } else {
        system::lookup(unsafe { CStr::from_ptr(name) })
    };
    let record = match found {
        Ok(Some(record)) => record,
        Ok(None) => return std::ptr::null_mut(),
        Err(()) => {
            unsafe { *failed = 1 };
            return std::ptr::null_mut();
        }
    };
    let copy = crate::c_copy(&record);
    unsafe {
        if copy.is_null() {
            *failed = 1;
        } else {
            *length = record.len() as i32;
        }
    }
    copy
}

#[no_mangle]
pub unsafe extern "C" fn con_secret_clear(name: *const c_char) -> i32 {
    if name.is_null() {
        return 1;
    }
    if system::clear(unsafe { CStr::from_ptr(name) }) {
        0
    } else {
        1
    }
}

unsafe fn bytes_of<'a>(bytes: *const u8, length: i32) -> &'a [u8] {
    if length <= 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, length as usize) }
    }
}

#[cfg(target_os = "linux")]
mod system {
    use std::ffi::{c_char, c_int, c_void, CStr, CString};
    use std::ptr::{null, null_mut};

    #[repr(C)]
    struct SecretSchemaAttribute {
        name: *const c_char,
        kind: c_int,
    }

    #[repr(C)]
    struct SecretSchema {
        name: *const c_char,
        flags: c_int,
        attributes: [SecretSchemaAttribute; 32],
        reserved: c_int,
        reserved1: *mut c_void,
        reserved2: *mut c_void,
        reserved3: *mut c_void,
        reserved4: *mut c_void,
        reserved5: *mut c_void,
        reserved6: *mut c_void,
        reserved7: *mut c_void,
    }

    struct Schema(SecretSchema);
    unsafe impl Sync for Schema {}

    const SECRET_SCHEMA_NONE: c_int = 0;
    const SECRET_SCHEMA_ATTRIBUTE_STRING: c_int = 0;
    const NO_ATTRIBUTE: SecretSchemaAttribute = SecretSchemaAttribute {
        name: null(),
        kind: 0,
    };

    static SCHEMA: Schema = Schema(SecretSchema {
        name: c"app.sole.credentials".as_ptr(),
        flags: SECRET_SCHEMA_NONE,
        attributes: {
            let mut attributes = [NO_ATTRIBUTE; 32];
            attributes[0] = SecretSchemaAttribute {
                name: ACCOUNT_ATTRIBUTE.as_ptr(),
                kind: SECRET_SCHEMA_ATTRIBUTE_STRING,
            };
            attributes
        },
        reserved: 0,
        reserved1: null_mut(),
        reserved2: null_mut(),
        reserved3: null_mut(),
        reserved4: null_mut(),
        reserved5: null_mut(),
        reserved6: null_mut(),
        reserved7: null_mut(),
    });

    const COLLECTION_DEFAULT: &CStr = c"default";
    const ACCOUNT_ATTRIBUTE: &CStr = c"account";

    #[repr(C)]
    struct GError {
        _private: [u8; 0],
    }

    extern "C" {
        fn secret_password_store_sync(
            schema: *const SecretSchema,
            collection: *const c_char,
            label: *const c_char,
            password: *const c_char,
            cancellable: *mut c_void,
            error: *mut *mut GError,
            ...
        ) -> c_int;
        fn secret_password_lookup_sync(
            schema: *const SecretSchema,
            cancellable: *mut c_void,
            error: *mut *mut GError,
            ...
        ) -> *mut c_char;
        fn secret_password_clear_sync(
            schema: *const SecretSchema,
            cancellable: *mut c_void,
            error: *mut *mut GError,
            ...
        ) -> c_int;
        fn secret_password_free(password: *mut c_char);
        fn g_error_free(error: *mut GError);
        fn g_base64_encode(data: *const u8, length: usize) -> *mut c_char;
        fn g_base64_decode(text: *const c_char, length: *mut usize) -> *mut u8;
        fn g_free(memory: *mut c_void);
    }

    fn free_error(error: *mut GError) -> bool {
        if error.is_null() {
            return false;
        }
        unsafe { g_error_free(error) };
        true
    }

    pub fn store(name: &CStr, record: &[u8]) -> bool {
        let Ok(label) = CString::new(format!("Con: {}", name.to_string_lossy())) else {
            return false;
        };
        let mut error = null_mut();
        unsafe {
            let text = g_base64_encode(record.as_ptr(), record.len());
            let stored = secret_password_store_sync(
                &SCHEMA.0,
                COLLECTION_DEFAULT.as_ptr(),
                label.as_ptr(),
                text,
                null_mut(),
                &mut error,
                ACCOUNT_ATTRIBUTE.as_ptr(),
                name.as_ptr(),
                null::<c_char>(),
            );
            free_error(error);
            g_free(text as *mut c_void);
            stored != 0
        }
    }

    pub fn lookup(name: &CStr) -> Result<Option<Vec<u8>>, ()> {
        let mut error = null_mut();
        unsafe {
            let text = secret_password_lookup_sync(
                &SCHEMA.0,
                null_mut(),
                &mut error,
                ACCOUNT_ATTRIBUTE.as_ptr(),
                name.as_ptr(),
                null::<c_char>(),
            );
            if free_error(error) {
                if !text.is_null() {
                    secret_password_free(text);
                }
                return Err(());
            }
            if text.is_null() {
                return Ok(None);
            }
            let mut size = 0usize;
            let decoded = g_base64_decode(text, &mut size);
            secret_password_free(text);
            let record = if decoded.is_null() || size == 0 {
                Vec::new()
            } else {
                std::slice::from_raw_parts(decoded, size).to_vec()
            };
            g_free(decoded as *mut c_void);
            Ok(Some(record))
        }
    }

    pub fn clear(name: &CStr) -> bool {
        let mut error = null_mut();
        unsafe {
            secret_password_clear_sync(
                &SCHEMA.0,
                null_mut(),
                &mut error,
                ACCOUNT_ATTRIBUTE.as_ptr(),
                name.as_ptr(),
                null::<c_char>(),
            );
        }
        !free_error(error)
    }
}

#[cfg(windows)]
mod system {
    use std::ffi::CStr;
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND};
    use windows_sys::Win32::Security::Credentials::{
        CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE,
        CRED_TYPE_GENERIC,
    };

    fn target_name(name: &CStr) -> Vec<u16> {
        format!("app.sole.credentials/{}", name.to_string_lossy())
            .encode_utf16()
            .chain(Some(0))
            .collect()
    }

    pub fn store(name: &CStr, record: &[u8]) -> bool {
        let mut target = target_name(name);
        let mut user: Vec<u16> = "Con".encode_utf16().chain(Some(0)).collect();
        let mut credential: CREDENTIALW = unsafe { std::mem::zeroed() };
        credential.Type = CRED_TYPE_GENERIC;
        credential.TargetName = target.as_mut_ptr();
        credential.CredentialBlobSize = record.len() as u32;
        credential.CredentialBlob = record.as_ptr() as *mut u8;
        credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
        credential.UserName = user.as_mut_ptr();
        unsafe { CredWriteW(&credential, 0) != 0 }
    }

    pub fn lookup(name: &CStr) -> Result<Option<Vec<u8>>, ()> {
        let target = target_name(name);
        let mut credential: *mut CREDENTIALW = null_mut();
        unsafe {
            if CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0 {
                return if GetLastError() == ERROR_NOT_FOUND {
                    Ok(None)
                } else {
                    Err(())
                };
            }
            let size = (*credential).CredentialBlobSize as usize;
            let blob = (*credential).CredentialBlob;
            let record = if size == 0 || blob.is_null() {
                Vec::new()
            } else {
                std::slice::from_raw_parts(blob, size).to_vec()
            };
            CredFree(credential as *const _);
            Ok(Some(record))
        }
    }

    pub fn clear(name: &CStr) -> bool {
        let target = target_name(name);
        unsafe {
            CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) != 0
                || GetLastError() == ERROR_NOT_FOUND
        }
    }
}
