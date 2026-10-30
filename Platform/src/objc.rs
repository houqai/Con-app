use std::ffi::c_void;

#[no_mangle]
pub unsafe extern "C" fn con_objc_catch(
    body: Option<unsafe extern "C-unwind" fn(context: *mut c_void)>,
    context: *mut c_void,
    exception: *mut *mut c_void,
) -> bool {
    if !exception.is_null() {
        unsafe { exception.write(std::ptr::null_mut()) };
    }
    let Some(body) = body else { return false };
    let Some(raised) = run(body, context) else {
        return false;
    };
    if !exception.is_null() {
        unsafe { exception.write(raised.unwrap_or(std::ptr::null_mut())) };
    }
    true
}

#[cfg(target_vendor = "apple")]
fn run(
    body: unsafe extern "C-unwind" fn(*mut c_void),
    context: *mut c_void,
) -> Option<Option<*mut c_void>> {
    use objc2::rc::Retained;
    use std::panic::AssertUnwindSafe;
    match objc2::exception::catch(AssertUnwindSafe(|| unsafe { body(context) })) {
        Ok(()) => None,
        Err(object) => Some(object.map(|object| Retained::into_raw(object) as *mut c_void)),
    }
}

#[cfg(not(target_vendor = "apple"))]
fn run(
    body: unsafe extern "C-unwind" fn(*mut c_void),
    context: *mut c_void,
) -> Option<Option<*mut c_void>> {
    unsafe { body(context) };
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C-unwind" fn count(context: *mut c_void) {
        unsafe { *(context as *mut u32) += 1 };
    }

    #[test]
    fn a_call_that_finishes_raises_nothing() {
        let mut runs = 0u32;
        let mut exception = std::ptr::dangling_mut::<c_void>();
        assert!(!unsafe {
            con_objc_catch(
                Some(count),
                &mut runs as *mut u32 as *mut c_void,
                &mut exception,
            )
        });
        assert_eq!(runs, 1);
        assert!(exception.is_null());
        assert!(!unsafe { con_objc_catch(None, std::ptr::null_mut(), &mut exception) });
        assert!(!unsafe {
            con_objc_catch(
                Some(count),
                &mut runs as *mut u32 as *mut c_void,
                std::ptr::null_mut(),
            )
        });
        assert_eq!(runs, 2);
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn what_was_raised_comes_back() {
        use objc2::rc::Retained;
        use objc2_foundation::{NSException, NSString};

        unsafe extern "C-unwind" fn raise(_: *mut c_void) {
            let name = NSString::from_str("com.apple.coreaudio.avfaudio");
            let reason = NSString::from_str("player did not see an IO cycle.");
            NSException::new(&name, Some(&reason), None)
                .expect("an exception")
                .raise();
        }
        let mut exception = std::ptr::null_mut();
        assert!(unsafe { con_objc_catch(Some(raise), std::ptr::null_mut(), &mut exception) });
        assert!(!exception.is_null());
        let exception =
            unsafe { Retained::from_raw(exception as *mut NSException) }.expect("an exception");
        assert_eq!(
            exception
                .reason()
                .map(|reason| reason.to_string())
                .as_deref(),
            Some("player did not see an IO cycle.")
        );
        assert_eq!(exception.name().to_string(), "com.apple.coreaudio.avfaudio");
    }
}
