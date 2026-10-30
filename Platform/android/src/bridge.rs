use jni::errors::Result as JniResult;
use jni::objects::{GlobalRef, JByteArray, JClass, JObject, JStaticMethodID, JString};
use jni::signature::{Primitive, ReturnType};
use jni::strings::JavaStr;
use jni::sys::{
    jboolean, jbyteArray, jfloat, jint, jvalue, JNI_ERR, JNI_FALSE, JNI_TRUE, JNI_VERSION_1_6,
};
use jni::{JNIEnv, JavaVM};
use ndk_sys::{ALooper_addFd, ALooper_forThread, ALOOPER_EVENT_INPUT, ALOOPER_POLL_CALLBACK};
use std::ffi::{c_char, c_int, c_void, CStr};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::OnceLock;

extern "C" {
    fn con_start(files: *const c_char, caches: *const c_char) -> i32;
    fn con_text(english: *const c_char, language: *const c_char) -> *mut c_char;
    fn con_state() -> *mut c_char;
    fn con_login_finished(
        address: *const c_char,
        sent_securely: *const c_char,
        sent_plainly: *const c_char,
    );
    fn con_login_closed();
    fn con_store_check() -> i32;
    fn con_act(name: *const c_char, value: *const c_char);
    fn con_ask(name: *const c_char, value: *const c_char) -> *mut c_char;
    #[allow(clippy::too_many_arguments)]
    fn con_touch(
        action: i32,
        finger: i32,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        left: f32,
        right: f32,
    ) -> *mut c_char;
    fn con_pad(
        buttons: i32,
        l2: f32,
        r2: f32,
        left_x: f32,
        left_y: f32,
        right_x: f32,
        right_y: f32,
    );
    fn con_pad_gone();
    fn con_free(text: *mut c_char);
}

struct Java {
    machine: JavaVM,
    shared: GlobalRef,
    store_read: JStaticMethodID,
    store_write: JStaticMethodID,
    store_remove: JStaticMethodID,
    open_login: JStaticMethodID,
    close_login: JStaticMethodID,
    changed: JStaticMethodID,
    keep_awake: JStaticMethodID,
    activate: JStaticMethodID,
}

static JAVA: OnceLock<Java> = OnceLock::new();

impl Java {
    fn class(&self) -> &JClass<'static> {
        <&JClass>::from(self.shared.as_obj())
    }
}

#[no_mangle]
pub unsafe extern "system" fn JNI_OnLoad(
    vm: *mut jni::sys::JavaVM,
    _reserved: *mut c_void,
) -> jint {
    let Ok(machine) = (unsafe { JavaVM::from_raw(vm) }) else {
        return JNI_ERR;
    };
    let (
        shared,
        store_read,
        store_write,
        store_remove,
        open_login,
        close_login,
        changed,
        keep_awake,
        activate,
    ) = {
        let Ok(mut env) = machine.get_env() else {
            return JNI_ERR;
        };
        let Ok(class) = env.find_class("app/con/check/Shared") else {
            return JNI_ERR;
        };
        let Ok(shared) = env.new_global_ref(&class) else {
            return JNI_ERR;
        };
        let mut method =
            |name: &str, signature: &str| env.get_static_method_id(&class, name, signature).ok();
        let methods = (
            method("storeRead", "(Ljava/lang/String;)[B"),
            method("storeWrite", "(Ljava/lang/String;[B)Z"),
            method("storeRemove", "(Ljava/lang/String;)Z"),
            method("openLogin", "(Ljava/lang/String;Ljava/lang/String;)V"),
            method("closeLogin", "()V"),
            method("changed", "()V"),
            method("keepAwake", "(Z)V"),
            method("activate", "(Ljava/lang/String;)V"),
        );
        let (
            Some(store_read),
            Some(store_write),
            Some(store_remove),
            Some(open_login),
            Some(close_login),
            Some(changed),
            Some(keep_awake),
            Some(activate),
        ) = methods
        else {
            return JNI_ERR;
        };
        (
            shared,
            store_read,
            store_write,
            store_remove,
            open_login,
            close_login,
            changed,
            keep_awake,
            activate,
        )
    };
    let _ = JAVA.set(Java {
        machine,
        shared,
        store_read,
        store_write,
        store_remove,
        open_login,
        close_login,
        changed,
        keep_awake,
        activate,
    });
    JNI_VERSION_1_6
}

fn with_java<R>(body: impl FnOnce(&mut JNIEnv, &Java) -> R) -> Option<(R, bool)> {
    let java = JAVA.get()?;
    let mut env = java.machine.attach_current_thread().ok()?;
    let result = body(&mut env, java);
    let no_exception = !env.exception_check().unwrap_or(true);
    if !no_exception {
        let _ = env.exception_clear();
    }
    Some((result, no_exception))
}

fn java_string<'local>(env: &mut JNIEnv<'local>, text: *const c_char) -> Option<JString<'local>> {
    if text.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    env.new_string(&*text).ok()
}

fn call<'local>(
    env: &mut JNIEnv<'local>,
    java: &Java,
    method: JStaticMethodID,
    returns: ReturnType,
    arguments: &[jvalue],
) -> Option<jni::objects::JValueOwned<'local>> {
    unsafe { env.call_static_method_unchecked(java.class(), method, returns, arguments) }.ok()
}

fn object(value: &JObject) -> jvalue {
    jvalue { l: value.as_raw() }
}

#[no_mangle]
pub unsafe extern "C" fn con_java_store_read(
    name: *const c_char,
    length: *mut i32,
    failed: *mut i32,
) -> *mut u8 {
    unsafe {
        *length = 0;
        *failed = 1;
    }
    let Some(((result, count, thrown), no_exception)) = with_java(|env, java| {
        let mut result: *mut u8 = null_mut();
        let mut count = 0;
        let key = java_string(env, name);
        let record = key
            .as_ref()
            .and_then(|key| {
                call(
                    env,
                    java,
                    java.store_read,
                    ReturnType::Array,
                    &[object(key)],
                )
            })
            .and_then(|value| value.l().ok())
            .map(JByteArray::from);
        let mut thrown = env.exception_check().unwrap_or(true);
        if let Some(record) = record
            .as_ref()
            .filter(|record| !thrown && !record.is_null())
        {
            let size = env.get_array_length(record).unwrap_or(0);
            result = unsafe { libc::calloc(size.max(1) as usize, 1) } as *mut u8;
            if !result.is_null() {
                let bytes =
                    unsafe { std::slice::from_raw_parts_mut(result as *mut i8, size as usize) };
                if env.get_byte_array_region(record, 0, bytes).is_ok() {
                    count = size;
                } else {
                    unsafe { libc::free(result as *mut c_void) };
                    result = null_mut();
                    thrown = true;
                }
            }
        }
        if let Some(record) = record {
            let _ = env.delete_local_ref(record);
        }
        if let Some(key) = key {
            let _ = env.delete_local_ref(key);
        }
        (result, count, thrown)
    }) else {
        return null_mut();
    };
    unsafe {
        *length = count;
        if no_exception && !thrown {
            *failed = 0;
        }
    }
    result
}

#[no_mangle]
pub unsafe extern "C" fn con_java_store_write(
    name: *const c_char,
    bytes: *const u8,
    length: i32,
) -> i32 {
    let answer = with_java(|env, java| {
        let mut written = false;
        let key = java_string(env, name);
        let record = env.new_byte_array(length).ok();
        if let (Some(key), Some(record)) = (key.as_ref(), record.as_ref()) {
            let given: &[i8] = if length > 0 && !bytes.is_null() {
                unsafe { std::slice::from_raw_parts(bytes as *const i8, length as usize) }
            } else {
                &[]
            };
            let _ = env.set_byte_array_region(record, 0, given);
            written = call(
                env,
                java,
                java.store_write,
                ReturnType::Primitive(Primitive::Boolean),
                &[object(key), object(record)],
            )
            .and_then(|value| value.z().ok())
            .unwrap_or(false);
        }
        if let Some(record) = record {
            let _ = env.delete_local_ref(record);
        }
        if let Some(key) = key {
            let _ = env.delete_local_ref(key);
        }
        written
    });
    match answer {
        Some((true, true)) => 0,
        _ => 1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_java_store_remove(name: *const c_char) -> i32 {
    let answer = with_java(|env, java| {
        let key = java_string(env, name);
        let removed = key
            .as_ref()
            .and_then(|key| {
                call(
                    env,
                    java,
                    java.store_remove,
                    ReturnType::Primitive(Primitive::Boolean),
                    &[object(key)],
                )
            })
            .and_then(|value| value.z().ok())
            .unwrap_or(false);
        if let Some(key) = key {
            let _ = env.delete_local_ref(key);
        }
        removed
    });
    match answer {
        Some((true, true)) => 0,
        _ => 1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_java_open_login(address: *const c_char, scheme: *const c_char) {
    with_java(|env, java| {
        let address_text = java_string(env, address);
        let scheme_text = java_string(env, scheme);
        if let (Some(address_text), Some(scheme_text)) =
            (address_text.as_ref(), scheme_text.as_ref())
        {
            call(
                env,
                java,
                java.open_login,
                ReturnType::Primitive(Primitive::Void),
                &[object(address_text), object(scheme_text)],
            );
        }
        if let Some(address_text) = address_text {
            let _ = env.delete_local_ref(address_text);
        }
        if let Some(scheme_text) = scheme_text {
            let _ = env.delete_local_ref(scheme_text);
        }
    });
}

fn call_void(method: impl Fn(&Java) -> JStaticMethodID, arguments: &[jvalue]) {
    with_java(|env, java| {
        call(
            env,
            java,
            method(java),
            ReturnType::Primitive(Primitive::Void),
            arguments,
        );
    });
}

#[no_mangle]
pub extern "C" fn con_java_keep_awake(on: i32) {
    call_void(
        |java| java.keep_awake,
        &[jvalue {
            z: if on != 0 { JNI_TRUE } else { JNI_FALSE },
        }],
    );
}

#[no_mangle]
pub extern "C" fn con_java_close_login() {
    call_void(|java| java.close_login, &[]);
}

#[no_mangle]
pub extern "C" fn con_java_changed() {
    call_void(|java| java.changed, &[]);
}

#[no_mangle]
pub unsafe extern "C" fn con_java_activate(target: *const c_char) {
    with_java(|env, java| {
        if let Some(name) = java_string(env, target) {
            call(
                env,
                java,
                java.activate,
                ReturnType::Primitive(Primitive::Void),
                &[object(&name)],
            );
            let _ = env.delete_local_ref(name);
        }
    });
}

extern "C" {
    fn _dispatch_get_main_queue_handle_4CF() -> c_int;
    fn _dispatch_main_queue_callback_4CF(message: *mut c_void);
}

unsafe extern "C" fn serve_main_queue(handle: c_int, _events: c_int, _data: *mut c_void) -> c_int {
    let mut ready = libc::pollfd {
        fd: handle,
        events: libc::POLLIN,
        revents: 0,
    };
    let mut count: u64 = 0;
    unsafe {
        if libc::poll(&mut ready, 1, 0) > 0 {
            let _ = libc::read(
                handle,
                &mut count as *mut u64 as *mut c_void,
                std::mem::size_of::<u64>(),
            );
        }
        _dispatch_main_queue_callback_4CF(null_mut());
    }
    1
}

#[no_mangle]
pub extern "C" fn con_main_queue_attach() {
    static ATTACHED: AtomicBool = AtomicBool::new(false);
    unsafe {
        let looper = ALooper_forThread();
        if ATTACHED.load(SeqCst) || looper.is_null() {
            return;
        }
        let added = ALooper_addFd(
            looper,
            _dispatch_get_main_queue_handle_4CF(),
            ALOOPER_POLL_CALLBACK,
            ALOOPER_EVENT_INPUT as c_int,
            Some(serve_main_queue),
            null_mut(),
        );
        ATTACHED.store(added == 1, SeqCst);
    }
}

unsafe fn into_byte_array(env: &mut JNIEnv, text: *mut c_char) -> jbyteArray {
    let text_bytes: &[u8] = if text.is_null() {
        b""
    } else {
        unsafe { CStr::from_ptr(text) }.to_bytes()
    };
    let result = env
        .byte_array_from_slice(text_bytes)
        .map(|array| array.into_raw())
        .unwrap_or(null_mut());
    unsafe { con_free(text) };
    result
}

fn chars<'a, 'local>(
    env: &JNIEnv<'local>,
    text: &'a JString<'a>,
) -> JniResult<JavaStr<'local, 'a, 'a>> {
    unsafe { env.get_string_unchecked(text) }
}

fn raw(text: &JniResult<JavaStr>) -> *const c_char {
    text.as_ref().map(|text| text.get_raw()).unwrap_or(null())
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_start(
    env: JNIEnv,
    _type: JClass,
    files: JString,
    caches: JString,
) -> jint {
    let files_path = chars(&env, &files);
    let caches_path = chars(&env, &caches);
    con_main_queue_attach();
    unsafe { con_start(raw(&files_path), raw(&caches_path)) }
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_text(
    mut env: JNIEnv,
    _type: JClass,
    english: JString,
    language: JString,
) -> jbyteArray {
    let text = chars(&env, &english);
    let code = chars(&env, &language);
    let answer = unsafe { con_text(raw(&text), raw(&code)) };
    drop((text, code));
    unsafe { into_byte_array(&mut env, answer) }
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_state(
    mut env: JNIEnv,
    _type: JClass,
) -> jbyteArray {
    unsafe { into_byte_array(&mut env, con_state()) }
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_loginClosed(_env: JNIEnv, _type: JClass) {
    unsafe { con_login_closed() }
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_storeCheck(
    _env: JNIEnv,
    _type: JClass,
) -> jboolean {
    if unsafe { con_store_check() } == 0 {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

fn utf8(env: &JNIEnv, text: &JByteArray) -> Vec<u8> {
    let length = if text.is_null() {
        0
    } else {
        env.get_array_length(text).unwrap_or(0).max(0) as usize
    };
    let mut result = vec![0u8; length + 1];
    if length > 0 {
        let part =
            unsafe { std::slice::from_raw_parts_mut(result.as_mut_ptr() as *mut i8, length) };
        let _ = env.get_byte_array_region(text, 0, part);
    }
    result
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_act(
    env: JNIEnv,
    _type: JClass,
    name: JByteArray,
    value: JByteArray,
) {
    let what = utf8(&env, &name);
    let with = utf8(&env, &value);
    unsafe {
        con_act(
            what.as_ptr() as *const c_char,
            with.as_ptr() as *const c_char,
        )
    }
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_ask(
    mut env: JNIEnv,
    _type: JClass,
    name: JByteArray,
    value: JByteArray,
) -> jbyteArray {
    let what = utf8(&env, &name);
    let with = utf8(&env, &value);
    unsafe {
        let answer = con_ask(
            what.as_ptr() as *const c_char,
            with.as_ptr() as *const c_char,
        );
        into_byte_array(&mut env, answer)
    }
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "system" fn Java_app_con_check_Shared_pad(
    _env: JNIEnv,
    _type: JClass,
    buttons: jint,
    l2: jfloat,
    r2: jfloat,
    left_x: jfloat,
    left_y: jfloat,
    right_x: jfloat,
    right_y: jfloat,
) {
    unsafe { con_pad(buttons, l2, r2, left_x, left_y, right_x, right_y) }
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "system" fn Java_app_con_check_Shared_touch(
    mut env: JNIEnv,
    _type: JClass,
    action: jint,
    finger: jint,
    x: jfloat,
    y: jfloat,
    width: jfloat,
    height: jfloat,
    left: jfloat,
    right: jfloat,
) -> jbyteArray {
    unsafe {
        into_byte_array(
            &mut env,
            con_touch(action, finger, x, y, width, height, left, right),
        )
    }
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_padGone(_env: JNIEnv, _type: JClass) {
    unsafe { con_pad_gone() }
}

#[no_mangle]
pub unsafe extern "system" fn Java_app_con_check_Shared_loginFinished(
    env: JNIEnv,
    _type: JClass,
    address: JString,
    secure: JString,
    plain: JString,
) {
    let address_text = chars(&env, &address);
    let securely = chars(&env, &secure);
    let plainly = chars(&env, &plain);
    unsafe { con_login_finished(raw(&address_text), raw(&securely), raw(&plainly)) }
}
