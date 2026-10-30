use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use super::abi::*;

macro_rules! c_functions {
    ($( fn $name:ident($($arg:ident: $t:ty),* $(,)?) $(-> $r:ty)?; )*) => {
        #[allow(improper_ctypes)]
        extern "C" {
            $( pub fn $name($($arg: $t),*) $(-> $r)?; )*
        }

        #[test]
        fn declarations_have_the_types_of_the_library_functions() {
            $(
                let _: unsafe extern "C" fn($($t),*) $(-> $r)? = con_engine::ffi::$name;
                let _: unsafe extern "C" fn($($t),*) $(-> $r)? = $name;
            )*
        }

        pub fn all_functions() -> Vec<(&'static str, usize)> {
            vec![$((stringify!($name), $name as *const () as usize)),*]
        }
    };
}

c_functions! {
    fn con_engine_version() -> *const c_char;
    fn con_engine_abi_version() -> u32;
    fn con_quit_reason_name(reason: u32) -> *const c_char;
    fn con_stage_name(stage: u32) -> *const c_char;
    fn con_set_thread_callback(callback: ConThreadCallback, user: *mut c_void) -> i32;
    fn con_thread_set_interactive() -> i32;
    fn con_discovery_config_default(out: *mut ConDiscoveryConfig) -> i32;
    fn con_discovery_start(
        config: *const ConDiscoveryConfig,
        callback: ConHostsCallback,
        user: *mut c_void,
        out: *mut *mut ConDiscovery,
    ) -> i32;
    fn con_discovery_wake(
        discovery: *mut ConDiscovery,
        address: *const c_char,
        kind: u32,
        regist_key: *const u8,
    ) -> i32;
    fn con_discovery_stop(discovery: *mut ConDiscovery);
    fn con_wake(address: *const c_char, port: u16, kind: u32, regist_key: *const u8) -> i32;
    fn con_registration_request_default(out: *mut ConRegistrationRequest) -> i32;
    fn con_registration_start(
        request: *const ConRegistrationRequest,
        callback: ConRegistrationCallback,
        user: *mut c_void,
        out: *mut *mut ConRegistration,
    ) -> i32;
    fn con_registration_cancel(registration: *mut ConRegistration);
    fn con_registration_free(registration: *mut ConRegistration);
    fn con_console_config_default(out: *mut ConConsoleConfig) -> i32;
    fn con_cloud_config_default(out: *mut ConCloudConfig) -> i32;
    fn con_session_options_default(out: *mut ConSessionOptions) -> i32;
    fn con_session_start_console(
        config: *const ConConsoleConfig,
        options: *const ConSessionOptions,
        callback: ConEventCallback,
        user: *mut c_void,
        out: *mut *mut ConSession,
    ) -> i32;
    fn con_session_start_cloud(
        config: *const ConCloudConfig,
        options: *const ConSessionOptions,
        callback: ConEventCallback,
        user: *mut c_void,
        out: *mut *mut ConSession,
    ) -> i32;
    fn con_session_stop(session: *mut ConSession);
    fn con_session_is_finished(session: *mut ConSession) -> i32;
    fn con_session_free(session: *mut ConSession);
    fn con_session_submit_pin(session: *mut ConSession, pin: *const c_char) -> i32;
    fn con_session_keyboard_set_text(session: *mut ConSession, text: *const c_char) -> i32;
    fn con_session_keyboard_accept(session: *mut ConSession) -> i32;
    fn con_session_keyboard_cancel(session: *mut ConSession) -> i32;
    fn con_session_sleep(session: *mut ConSession) -> i32;
    fn con_session_go_home(session: *mut ConSession) -> i32;
    fn con_session_microphone_connect(session: *mut ConSession) -> i32;
    fn con_session_set_microphone_muted(session: *mut ConSession, muted: i32) -> i32;
    fn con_session_send_microphone_pcm(session: *mut ConSession, pcm: *const i16, count: usize) -> i32;
    fn con_controller_state_idle(out: *mut ConControllerState) -> i32;
    fn con_session_set_controller_state(
        session: *mut ConSession,
        state: *const ConControllerState,
    ) -> i32;
    fn con_session_request_keyframe(session: *mut ConSession) -> i32;
    fn con_session_report_corrupt_frames(session: *mut ConSession, start: u16, end: u16) -> i32;
    fn con_session_stats(session: *mut ConSession, out: *mut ConStats) -> i32;
    fn con_session_set_video_capture(session: *mut ConSession, path: *const c_char) -> i32;
    fn con_session_set_audio_capture(session: *mut ConSession, path: *const c_char) -> i32;
    fn con_session_set_reference_repair(session: *mut ConSession, repair: i32) -> i32;
    fn con_session_video_hidden(session: *mut ConSession, frames: *mut u64, runs: *mut u64) -> i32;
    fn con_session_video_withheld(
        session: *mut ConSession,
        frames: *mut u64,
        periods: *mut u64,
    ) -> i32;
    fn con_cloud_probe_config_default(out: *mut ConCloudProbeConfig) -> i32;
    fn con_cloud_probe_run(config: *const ConCloudProbeConfig, out: *mut ConCloudProbeResult) -> i32;
    fn con_cloud_probe_start(
        config: *const ConCloudProbeConfig,
        callback: ConCloudProbeCallback,
        user: *mut c_void,
        out: *mut *mut ConCloudProbe,
    ) -> i32;
    fn con_cloud_probe_cancel(probe: *mut ConCloudProbe);
    fn con_cloud_probe_free(probe: *mut ConCloudProbe);
}

pub const KEY_TEXT: [u8; 16] = *b"1a2b3c4d\0\0\0\0\0\0\0\0";

pub fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

pub unsafe fn text(p: *const c_char) -> Option<String> {
    (!p.is_null()).then(|| CStr::from_ptr(p).to_string_lossy().into_owned())
}

pub fn user<T>(state: &'static T) -> *mut c_void {
    state as *const T as *mut c_void
}

pub unsafe fn state<'a, T>(user: *mut c_void) -> &'a T {
    &*(user as *const T)
}

pub fn wait(ms: u64, cond: impl Fn() -> bool) -> bool {
    let end = Instant::now() + Duration::from_millis(ms);
    while Instant::now() < end {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    cond()
}

#[derive(Default)]
pub struct Checks {
    pub failures: Vec<String>,
    pub lines: Vec<String>,
}

impl Checks {
    pub fn check(&mut self, ok: bool, what: &str, line: u32) {
        if !ok {
            self.failures.push(format!("FAIL line {line}: {what}"));
        }
    }

    pub fn say(&mut self, line: String) {
        self.lines.push(line);
    }
}

macro_rules! check {
    ($c:ident, $cond:expr) => {
        $c.check($cond, stringify!($cond), line!())
    };
}

#[derive(Default)]
struct SelfTestSeen {
    regist_done: AtomicBool,
    regist_status: AtomicU32,
    regist_error: Mutex<String>,
    quit_seen: AtomicBool,
    quit: Mutex<Option<(u32, u32, u8)>>,
}

unsafe extern "C" fn selftest_hosts(
    _user: *mut c_void,
    _hosts: *const ConDiscoveredHost,
    _n: usize,
) {
}

unsafe extern "C" fn selftest_registration(user: *mut c_void, r: *const ConRegistrationResult) {
    let s: &SelfTestSeen = state(user);
    let r = &*r;
    *s.regist_error.lock().unwrap() = text(r.error_text).unwrap_or_default();
    s.regist_status.store(r.status, Ordering::SeqCst);
    s.regist_done.store(true, Ordering::SeqCst);
}

unsafe extern "C" fn selftest_event(user: *mut c_void, e: *mut ConEvent) {
    let s: &SelfTestSeen = state(user);
    let e = &*e;
    if e.type_ == CON_EVENT_QUIT {
        let q = e.data.quit;
        *s.quit.lock().unwrap() = Some((q.reason, q.stage, q.is_error));
        s.quit_seen.store(true, Ordering::SeqCst);
    }
}

pub fn selftest() -> Checks {
    let mut c = Checks::default();
    let seen: &'static SelfTestSeen = Box::leak(Box::default());
    unsafe {
        let version = text(con_engine_version()).unwrap_or_default();
        c.say(format!(
            "version {version} abi {}",
            con_engine_abi_version()
        ));
        check!(c, con_engine_abi_version() == CON_ENGINE_ABI_VERSION);
        check!(
            c,
            text(con_quit_reason_name(CON_QUIT_STREAM_REMOTE_SHUTDOWN)).as_deref()
                == Some("stream: remote shut down")
        );
        check!(
            c,
            text(con_quit_reason_name(999)).as_deref() == Some("unknown")
        );
        check!(
            c,
            text(con_stage_name(CON_STAGE_STREAMING)).as_deref() == Some("streaming")
        );
        check!(c, text(con_stage_name(99)).as_deref() == Some("unknown"));

        let mut dc: ConDiscoveryConfig = std::mem::zeroed();
        check!(c, con_discovery_config_default(&mut dc) == CON_OK);
        let local = cstr("127.0.0.1");
        dc.bind_address = local.as_ptr();
        dc.destination = local.as_ptr();
        dc.ps4_port = 1;
        dc.ps5_port = 1;
        dc.initial_delay_ms = 10;
        dc.period_ms = 50;
        let mut d: *mut ConDiscovery = std::ptr::null_mut();
        check!(
            c,
            con_discovery_start(&dc, Some(selftest_hosts), user(seen), &mut d) == CON_OK
        );
        std::thread::sleep(Duration::from_millis(300));
        con_discovery_stop(d);
        let bad_key = *b"x\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0";
        check!(
            c,
            con_wake(local.as_ptr(), 1, CON_CONSOLE_PS5, bad_key.as_ptr())
                == CON_ERR_BAD_CREDENTIAL
        );
        check!(
            c,
            con_wake(local.as_ptr(), 1, CON_CONSOLE_PS5, KEY_TEXT.as_ptr()) == CON_OK
        );

        let mut rq: ConRegistrationRequest = std::mem::zeroed();
        check!(c, con_registration_request_default(&mut rq) == CON_OK);
        let pin = cstr("12345678");
        rq.host = local.as_ptr();
        rq.port = 1;
        rq.pin = pin.as_ptr();
        rq.probe_timeout_ms = 300;
        let mut r: *mut ConRegistration = std::ptr::null_mut();
        check!(
            c,
            con_registration_start(&rq, Some(selftest_registration), user(seen), &mut r) == CON_OK
        );
        check!(c, wait(15_000, || seen.regist_done.load(Ordering::SeqCst)));
        con_registration_free(r);
        let status = seen.regist_status.load(Ordering::SeqCst);
        c.say(format!(
            "registration status={status} error={}",
            seen.regist_error.lock().unwrap()
        ));
        check!(
            c,
            status == CON_REGIST_NO_PROBE_REPLY || status == CON_REGIST_NETWORK
        );

        let mut cc: ConConsoleConfig = std::mem::zeroed();
        check!(c, con_console_config_default(&mut cc) == CON_OK);
        cc.host = local.as_ptr();
        cc.session_port = 1;
        let mut s: *mut ConSession = std::ptr::null_mut();
        check!(
            c,
            con_session_start_console(
                std::ptr::null(),
                std::ptr::null(),
                Some(selftest_event),
                user(seen),
                &mut s
            ) == CON_ERR_INVALID_ARGUMENT
        );
        check!(c, s.is_null());
        check!(
            c,
            con_session_start_console(
                &cc,
                std::ptr::null(),
                Some(selftest_event),
                user(seen),
                &mut s
            ) == CON_OK
        );
        check!(c, wait(30_000, || seen.quit_seen.load(Ordering::SeqCst)));
        con_session_free(s);
        let quit = *seen.quit.lock().unwrap();
        if let Some((reason, stage, is_error)) = quit {
            c.say(format!(
                "quit {reason} {} is_error={is_error} stage={stage} {}",
                text(con_quit_reason_name(reason)).unwrap_or_default(),
                text(con_stage_name(stage)).unwrap_or_default()
            ));
        }
        check!(c, quit.is_some_and(|(_, _, is_error)| is_error == 1));
        check!(
            c,
            quit.is_some_and(|(_, stage, _)| stage == CON_STAGE_SESSION_REQUEST)
        );
    }
    c
}
