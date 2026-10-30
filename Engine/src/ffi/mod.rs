#![allow(clippy::missing_safety_doc)]

use std::cell::Cell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::net::{IpAddr, SocketAddr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, RwLock};
use std::thread::JoinHandle;
use std::time::Duration;

use crate::discovery::{self, ConsoleState, DiscoveredHost, DiscoveryConfig, DiscoveryService};
use crate::launch::StreamChoice;
use crate::log::{LogLevel, Logger};
use crate::media::feedback::{button, ControllerState, Touch};
use crate::media::video::MissingReference;
use crate::media::{
    AudioFrame, FeedbackEvent, HapticsFrame, IntensityKind, MediaSink, SampleKind, VideoSample,
};
use crate::nettest::{self, NetworkTestConfig, NetworkTestError, TestStage};
use crate::registration::{
    self, Identity, RegistError, RegistRequest, RegistTimeouts, Registration,
};
use crate::runner::{
    CloudSlot, Connection, ConsoleParams, Session, SessionEvent, SessionRunnerConfig,
};
use crate::session::{ControlError, ControlEvent, ControlHandle, QuitReason};
use crate::stream::{StreamEvent, StreamHandle};
use crate::threads::ThreadRole;
use crate::transport::TransportError;
use crate::{Codec, ConsoleKind, Stage, StopToken, Target};

pub mod abi;
pub use abi::*;

const _: () = {
    assert!(CON_THREAD_IO == ThreadRole::Io as u32);
    assert!(CON_THREAD_SENDER == ThreadRole::Sender as u32);
    assert!(CON_THREAD_SESSION == ThreadRole::Session as u32);
    assert!(CON_THREAD_CONTROL == ThreadRole::Control as u32);
    assert!(CON_THREAD_STATISTICS == ThreadRole::Statistics as u32);
    assert!(CON_THREAD_DISCOVERY == ThreadRole::Discovery as u32);
    assert!(CON_THREAD_REGISTRATION == ThreadRole::Registration as u32);
    assert!(CON_THREAD_PROBE == ThreadRole::Probe as u32);
    assert!(CON_THREAD_CAPTURE == ThreadRole::Capture as u32);
    assert!(CON_THREAD_HELPER == ThreadRole::Helper as u32);
    assert!(CON_BUTTON_CROSS == button::CROSS);
    assert!(CON_BUTTON_CIRCLE == button::CIRCLE);
    assert!(CON_BUTTON_SQUARE == button::SQUARE);
    assert!(CON_BUTTON_TRIANGLE == button::TRIANGLE);
    assert!(CON_BUTTON_LEFT == button::LEFT);
    assert!(CON_BUTTON_RIGHT == button::RIGHT);
    assert!(CON_BUTTON_UP == button::UP);
    assert!(CON_BUTTON_DOWN == button::DOWN);
    assert!(CON_BUTTON_L1 == button::L1);
    assert!(CON_BUTTON_R1 == button::R1);
    assert!(CON_BUTTON_L3 == button::L3);
    assert!(CON_BUTTON_R3 == button::R3);
    assert!(CON_BUTTON_OPTIONS == button::OPTIONS);
    assert!(CON_BUTTON_SHARE == button::SHARE);
    assert!(CON_BUTTON_TOUCHPAD == button::TOUCHPAD);
    assert!(CON_BUTTON_PS == button::PS);
};

fn guard(f: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(CON_ERR_PANIC)
}

fn guard_void(f: impl FnOnce()) {
    let _ = catch_unwind(AssertUnwindSafe(f));
}

fn result(r: Result<(), i32>) -> i32 {
    match r {
        Ok(()) => CON_OK,
        Err(e) => e,
    }
}

fn guarded(f: impl FnOnce() -> Result<(), i32>) -> i32 {
    guard(|| result(f()))
}

unsafe fn finish_start<T>(out: *mut *mut T, make: impl FnOnce() -> Result<T, i32>) -> i32 {
    if out.is_null() {
        return CON_ERR_INVALID_ARGUMENT;
    }
    out.write(std::ptr::null_mut());
    match make() {
        Ok(v) => {
            out.write(Box::into_raw(Box::new(v)));
            CON_OK
        }
        Err(e) => e,
    }
}

fn ptr_or_null<T>(s: &[T]) -> *const T {
    if s.is_empty() {
        std::ptr::null()
    } else {
        s.as_ptr()
    }
}

fn first_address(host: &str, port: u16) -> Option<SocketAddr> {
    crate::net::resolve(host, port).ok()?.first().copied()
}

struct Job {
    stop: StopToken,
    thread: Option<JoinHandle<()>>,
}

impl Job {
    fn new(stop: StopToken, thread: JoinHandle<()>) -> Self {
        Job {
            stop,
            thread: Some(thread),
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        self.stop.stop();
        if let Some(t) = self.thread.take() {
            if t.thread().id() != std::thread::current().id() {
                let _ = t.join();
            }
        }
    }
}

thread_local! {
    static CALLBACK_DEPTH: Cell<u32> = const { Cell::new(0) };
}

struct DepthGuard;

impl Drop for DepthGuard {
    fn drop(&mut self) {
        CALLBACK_DEPTH.with(|d| d.set(d.get().saturating_sub(1)));
    }
}

fn calling_back<R>(f: impl FnOnce() -> R) -> R {
    CALLBACK_DEPTH.with(|d| d.set(d.get() + 1));
    let _g = DepthGuard;
    f()
}

fn inside_callback() -> bool {
    CALLBACK_DEPTH.with(|d| d.get() > 0)
}

fn release<T: Send + 'static>(obj: T) {
    if !inside_callback() {
        drop(obj);
        return;
    }
    let slot = Arc::new(Mutex::new(Some(obj)));
    let theirs = slot.clone();
    let spawned = crate::threads::spawn(ThreadRole::Helper, "con-release", move || {
        drop(crate::sync::lock(&theirs).take())
    });
    if spawned.is_err() {
        std::mem::forget(crate::sync::lock(&slot).take());
    }
}

#[derive(Clone, Copy)]
struct UserPtr(*mut c_void);
unsafe impl Send for UserPtr {}
unsafe impl Sync for UserPtr {}

impl UserPtr {
    fn ptr(self) -> *mut c_void {
        self.0
    }
}

unsafe fn opt_str<'a>(p: *const c_char) -> Result<Option<&'a str>, i32> {
    if p.is_null() {
        return Ok(None);
    }
    CStr::from_ptr(p)
        .to_str()
        .map(Some)
        .map_err(|_| CON_ERR_INVALID_ARGUMENT)
}

unsafe fn req_str<'a>(p: *const c_char) -> Result<&'a str, i32> {
    opt_str(p)?.ok_or(CON_ERR_INVALID_ARGUMENT)
}

unsafe fn key16(p: *const u8) -> Result<[u8; 16], i32> {
    if p.is_null() {
        return Err(CON_ERR_INVALID_ARGUMENT);
    }
    let mut k = [0u8; 16];
    k.copy_from_slice(std::slice::from_raw_parts(p, 16));
    Ok(k)
}

unsafe fn write_out<T>(out: *mut T, v: T) -> Result<(), i32> {
    if out.is_null() {
        return Err(CON_ERR_INVALID_ARGUMENT);
    }
    out.write(v);
    Ok(())
}

fn c_text(s: &str) -> CString {
    CString::new(s.replace('\0', "\u{fffd}")).unwrap_or_default()
}

fn opt_c_text(s: &Option<String>) -> Option<CString> {
    s.as_deref().map(c_text)
}

fn ptr_of(s: &Option<CString>) -> *const c_char {
    s.as_ref().map_or(std::ptr::null(), |c| c.as_ptr())
}

fn kind_from(v: u32) -> Result<ConsoleKind, i32> {
    match v {
        CON_CONSOLE_PS4 => Ok(ConsoleKind::Ps4),
        CON_CONSOLE_PS5 => Ok(ConsoleKind::Ps5),
        _ => Err(CON_ERR_INVALID_ARGUMENT),
    }
}

fn kind_to(k: ConsoleKind) -> u32 {
    match k {
        ConsoleKind::Ps4 => CON_CONSOLE_PS4,
        ConsoleKind::Ps5 => CON_CONSOLE_PS5,
    }
}

fn target_from(v: u32) -> Result<Target, i32> {
    match v {
        CON_TARGET_PS4_8 => Ok(Target::Ps4V8),
        CON_TARGET_PS4_9 => Ok(Target::Ps4V9),
        CON_TARGET_PS4_10 => Ok(Target::Ps4V10),
        CON_TARGET_PS5_1 => Ok(Target::Ps5V1),
        _ => Err(CON_ERR_INVALID_ARGUMENT),
    }
}

fn target_to(t: Target) -> u32 {
    match t {
        Target::Ps4V8 => CON_TARGET_PS4_8,
        Target::Ps4V9 => CON_TARGET_PS4_9,
        Target::Ps4V10 => CON_TARGET_PS4_10,
        Target::Ps5V1 => CON_TARGET_PS5_1,
    }
}

fn codec_from(v: u32) -> Result<Codec, i32> {
    match v {
        CON_CODEC_H264 => Ok(Codec::H264),
        CON_CODEC_H265 => Ok(Codec::H265),
        CON_CODEC_H265_HDR => Ok(Codec::H265Hdr),
        _ => Err(CON_ERR_INVALID_ARGUMENT),
    }
}

fn codec_to(c: Codec) -> u32 {
    match c {
        Codec::H264 => CON_CODEC_H264,
        Codec::H265 => CON_CODEC_H265,
        Codec::H265Hdr => CON_CODEC_H265_HDR,
    }
}

fn level_from(l: i32) -> LogLevel {
    match l {
        CON_LOG_ERROR => LogLevel::Error,
        CON_LOG_WARNING => LogLevel::Warning,
        CON_LOG_INFO => LogLevel::Info,
        _ => LogLevel::Debug,
    }
}

fn level_to(l: LogLevel) -> i32 {
    match l {
        LogLevel::Error => CON_LOG_ERROR,
        LogLevel::Warning => CON_LOG_WARNING,
        LogLevel::Info => CON_LOG_INFO,
        LogLevel::Debug => CON_LOG_DEBUG,
    }
}

pub fn quit_reason_code(r: QuitReason) -> u32 {
    match r {
        QuitReason::Stopped => CON_QUIT_STOPPED,
        QuitReason::SessionRequestUnknown => CON_QUIT_SESSION_REQUEST_UNKNOWN,
        QuitReason::SessionRequestConnectionRefused => CON_QUIT_SESSION_REQUEST_CONNECTION_REFUSED,
        QuitReason::SessionRequestInUse => CON_QUIT_SESSION_REQUEST_IN_USE,
        QuitReason::SessionRequestCrashed => CON_QUIT_SESSION_REQUEST_CRASHED,
        QuitReason::SessionRequestVersionMismatch => CON_QUIT_SESSION_REQUEST_VERSION_MISMATCH,
        QuitReason::ControlUnknown => CON_QUIT_CONTROL_UNKNOWN,
        QuitReason::ControlConnectFailed => CON_QUIT_CONTROL_CONNECT_FAILED,
        QuitReason::ControlConnectionRefused => CON_QUIT_CONTROL_CONNECTION_REFUSED,
        QuitReason::StreamUnknown => CON_QUIT_STREAM_UNKNOWN,
        QuitReason::StreamRemoteDisconnected => CON_QUIT_STREAM_REMOTE_DISCONNECTED,
        QuitReason::StreamRemoteShutdown => CON_QUIT_STREAM_REMOTE_SHUTDOWN,
        QuitReason::PsnRegistrationFailed => CON_QUIT_PSN_REGISTRATION_FAILED,
    }
}

pub fn stage_code(s: Stage) -> u32 {
    match s {
        Stage::SessionRequest => CON_STAGE_SESSION_REQUEST,
        Stage::Control => CON_STAGE_CONTROL,
        Stage::NetworkTest => CON_STAGE_NETWORK_TEST,
        Stage::Transport => CON_STAGE_TRANSPORT,
        Stage::KeyExchange => CON_STAGE_KEY_EXCHANGE,
        Stage::StreamInfo => CON_STAGE_STREAM_INFO,
        Stage::Streaming => CON_STAGE_STREAMING,
    }
}

const STAGE_NAMES: [&CStr; 8] = [
    c"unknown",
    c"session request",
    c"control channel",
    c"network test",
    c"stream transport",
    c"key exchange",
    c"stream info",
    c"streaming",
];

const QUIT_NAMES: [&CStr; 13] = [
    c"stopped",
    c"session request: unknown error",
    c"session request: connection refused",
    c"session request: remote play in use",
    c"session request: remote play crashed",
    c"session request: version mismatch",
    c"control: unknown error",
    c"control: connect failed",
    c"control: connection refused",
    c"stream: unknown error",
    c"stream: remote disconnected",
    c"stream: remote shut down",
    c"PSN registration failed",
];

#[no_mangle]
pub extern "C" fn con_engine_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[no_mangle]
pub extern "C" fn con_engine_abi_version() -> u32 {
    CON_ENGINE_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn con_quit_reason_name(reason: u32) -> *const c_char {
    QUIT_NAMES
        .get(reason as usize)
        .copied()
        .unwrap_or(c"unknown")
        .as_ptr()
}

#[no_mangle]
pub extern "C" fn con_stage_name(stage: u32) -> *const c_char {
    STAGE_NAMES
        .get(stage as usize)
        .copied()
        .unwrap_or(c"unknown")
        .as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn con_set_thread_callback(
    callback: ConThreadCallback,
    user: *mut c_void,
) -> i32 {
    guard(|| {
        match callback {
            None => crate::threads::set_hook(None),
            Some(cb) => {
                let user = UserPtr(user);
                crate::threads::set_hook(Some(Arc::new(move |role: ThreadRole, name: &str| {
                    let name = c_text(name);
                    calling_back(|| unsafe { cb(user.ptr(), role as u32, name.as_ptr()) });
                })));
            }
        }
        CON_OK
    })
}

#[no_mangle]
pub extern "C" fn con_thread_set_interactive() -> i32 {
    guard(|| match crate::threads::set_current_thread_interactive() {
        Ok(()) => CON_OK,
        Err(_) if crate::threads::INTERACTIVE_SUPPORTED => CON_ERR_IO,
        Err(_) => CON_ERR_UNSUPPORTED,
    })
}

pub struct ConDiscovery {
    service: DiscoveryService,
}

fn discovery_defaults() -> ConDiscoveryConfig {
    let d = DiscoveryConfig::default();
    ConDiscoveryConfig {
        bind_address: std::ptr::null(),
        destination: std::ptr::null(),
        extra_destinations: std::ptr::null(),
        extra_destination_count: 0,
        initial_delay_ms: d.initial_delay.as_millis() as u32,
        period_ms: d.period.as_millis() as u32,
        drop_after_rounds: d.drop_after_rounds as u32,
        max_consoles: d.max_consoles as u32,
        ps4_port: d.ps4_port,
        ps5_port: d.ps5_port,
        local_port_first: *d.local_ports.start(),
        local_port_last: *d.local_ports.end(),
    }
}

unsafe fn ip_arg(p: *const c_char) -> Result<Option<IpAddr>, i32> {
    match opt_str(p)? {
        None => Ok(None),
        Some(s) => s
            .trim()
            .parse()
            .map(Some)
            .map_err(|_| CON_ERR_INVALID_ARGUMENT),
    }
}

unsafe fn discovery_config(c: &ConDiscoveryConfig) -> Result<DiscoveryConfig, i32> {
    let mut d = DiscoveryConfig::default();
    if let Some(ip) = ip_arg(c.bind_address)? {
        d.bind_address = ip;
    }
    if let Some(ip) = ip_arg(c.destination)? {
        d.destination = ip;
    }
    if c.extra_destination_count > 0 {
        if c.extra_destinations.is_null() {
            return Err(CON_ERR_INVALID_ARGUMENT);
        }
        for p in std::slice::from_raw_parts(c.extra_destinations, c.extra_destination_count) {
            d.extra_destinations
                .push(ip_arg(*p)?.ok_or(CON_ERR_INVALID_ARGUMENT)?);
        }
    }
    d.initial_delay = Duration::from_millis(u64::from(c.initial_delay_ms));
    d.period = Duration::from_millis(u64::from(c.period_ms.max(1)));
    d.drop_after_rounds = u64::from(c.drop_after_rounds);
    d.max_consoles = c.max_consoles as usize;
    d.ps4_port = c.ps4_port;
    d.ps5_port = c.ps5_port;
    d.local_ports = c.local_port_first..=c.local_port_last;
    Ok(d)
}

struct HostTexts {
    address: CString,
    host_id: CString,
    host_name: Option<CString>,
    host_type: Option<CString>,
    system_version: Option<CString>,
    protocol_version: Option<CString>,
    title_id: Option<CString>,
    app_name: Option<CString>,
}

fn report_hosts(
    cb: unsafe extern "C" fn(*mut c_void, *const ConDiscoveredHost, usize),
    user: UserPtr,
    hosts: &[DiscoveredHost],
) {
    let texts: Vec<HostTexts> = hosts
        .iter()
        .map(|h| HostTexts {
            address: c_text(&h.address.to_string()),
            host_id: c_text(&h.host_id),
            host_name: opt_c_text(&h.host_name),
            host_type: opt_c_text(&h.host_type),
            system_version: opt_c_text(&h.system_version),
            protocol_version: opt_c_text(&h.protocol_version),
            title_id: opt_c_text(&h.running_app_title_id),
            app_name: opt_c_text(&h.running_app_name),
        })
        .collect();
    let list: Vec<ConDiscoveredHost> = hosts
        .iter()
        .zip(&texts)
        .map(|(h, t)| ConDiscoveredHost {
            address: t.address.as_ptr(),
            host_id: t.host_id.as_ptr(),
            host_name: ptr_of(&t.host_name),
            host_type: ptr_of(&t.host_type),
            system_version: ptr_of(&t.system_version),
            protocol_version: ptr_of(&t.protocol_version),
            running_app_title_id: ptr_of(&t.title_id),
            running_app_name: ptr_of(&t.app_name),
            state: match h.state {
                ConsoleState::Ready => CON_CONSOLE_STATE_READY,
                ConsoleState::Standby => CON_CONSOLE_STATE_STANDBY,
                ConsoleState::Unknown => CON_CONSOLE_STATE_UNKNOWN,
            },
            kind: kind_to(h.kind()),
            generation: h.generation().map_or(CON_TARGET_UNKNOWN, target_to),
            target: target_to(h.target()),
            status: h.status,
            request_port: h.request_port.unwrap_or(0),
        })
        .collect();
    calling_back(|| unsafe { cb(user.ptr(), ptr_or_null(&list), list.len()) });
}

#[no_mangle]
pub unsafe extern "C" fn con_discovery_config_default(out: *mut ConDiscoveryConfig) -> i32 {
    guarded(|| write_out(out, discovery_defaults()))
}

#[no_mangle]
pub unsafe extern "C" fn con_discovery_start(
    config: *const ConDiscoveryConfig,
    callback: ConHostsCallback,
    user: *mut c_void,
    out: *mut *mut ConDiscovery,
) -> i32 {
    guard(|| {
        finish_start(out, || {
            let cb = callback.ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let c = if config.is_null() {
                discovery_defaults()
            } else {
                *config
            };
            let cfg = discovery_config(&c)?;
            let user = UserPtr(user);
            let service = DiscoveryService::start(
                cfg,
                Box::new(move |hosts: &[DiscoveredHost]| report_hosts(cb, user, hosts)),
            )
            .map_err(|_| CON_ERR_IO)?;
            Ok(ConDiscovery { service })
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_discovery_wake(
    discovery: *mut ConDiscovery,
    address: *const c_char,
    kind: u32,
    regist_key: *const u8,
) -> i32 {
    guarded(|| {
        let d = discovery.as_ref().ok_or(CON_ERR_INVALID_ARGUMENT)?;
        let ip = ip_arg(address)?.ok_or(CON_ERR_INVALID_ARGUMENT)?;
        let kind = kind_from(kind)?;
        let key = key16(regist_key)?;
        d.service.wake(ip, kind, &key).map_err(wake_error)
    })
}

fn wake_error(e: discovery::WakeError) -> i32 {
    match e {
        discovery::WakeError::BadCredential => CON_ERR_BAD_CREDENTIAL,
        discovery::WakeError::Io(_) => CON_ERR_IO,
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_discovery_stop(discovery: *mut ConDiscovery) {
    guard_void(|| {
        if !discovery.is_null() {
            release(Box::from_raw(discovery));
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_wake(
    address: *const c_char,
    port: u16,
    kind: u32,
    regist_key: *const u8,
) -> i32 {
    guarded(|| {
        let host = req_str(address)?;
        let kind = kind_from(kind)?;
        let key = key16(regist_key)?;
        let port = if port == 0 {
            discovery::console_port(kind)
        } else {
            port
        };
        let addr = first_address(host, port).ok_or(CON_ERR_IO)?;
        discovery::wake(addr, kind, &key).map_err(wake_error)
    })
}

pub struct ConRegistration {
    job: Job,
}

struct RegistFailure {
    status: u32,
    text: String,
    http_status: u32,
    app_reason: u32,
}

impl RegistFailure {
    fn new(status: u32, text: String) -> Self {
        RegistFailure {
            status,
            text,
            http_status: 0,
            app_reason: 0,
        }
    }
}

fn regist_status(e: &RegistError) -> u32 {
    match e {
        RegistError::Stopped => CON_REGIST_CANCELLED,
        RegistError::InvalidPin => CON_REGIST_INVALID_PIN,
        RegistError::AccountIdRequired => CON_REGIST_ACCOUNT_ID_REQUIRED,
        RegistError::NoProbeReply => CON_REGIST_NO_PROBE_REPLY,
        RegistError::Connect(_) => CON_REGIST_CONNECT_FAILED,
        RegistError::Io(_) => CON_REGIST_NETWORK,
        RegistError::Rejected { .. } => CON_REGIST_REJECTED,
        RegistError::InvalidResponse(_) | RegistError::MissingField(_) => {
            CON_REGIST_INVALID_RESPONSE
        }
    }
}

fn report_registration(
    cb: unsafe extern "C" fn(*mut c_void, *const ConRegistrationResult),
    user: UserPtr,
    target: Target,
    outcome: Result<Registration, RegistFailure>,
) {
    let empty = ConRegistrationResult {
        error_text: std::ptr::null(),
        nickname: std::ptr::null(),
        ap_ssid: std::ptr::null(),
        ap_bssid: std::ptr::null(),
        ap_key: std::ptr::null(),
        ap_name: std::ptr::null(),
        key_type: 0,
        support_cmd: 0,
        status: CON_REGIST_OK,
        target: target_to(target),
        http_status: 0,
        app_reason: 0,
        regist_key: [0; 16],
        rp_key: [0; 16],
        mac: [0; 6],
        has_key_type: 0,
        has_support_cmd: 0,
    };
    match outcome {
        Ok(r) => {
            let texts = [
                opt_c_text(&r.nickname),
                opt_c_text(&r.ap_ssid),
                opt_c_text(&r.ap_bssid),
                opt_c_text(&r.ap_key),
                opt_c_text(&r.ap_name),
            ];
            let res = ConRegistrationResult {
                nickname: ptr_of(&texts[0]),
                ap_ssid: ptr_of(&texts[1]),
                ap_bssid: ptr_of(&texts[2]),
                ap_key: ptr_of(&texts[3]),
                ap_name: ptr_of(&texts[4]),
                key_type: r.key_type.unwrap_or(0),
                support_cmd: r.support_cmd.unwrap_or(0),
                target: target_to(r.target),
                regist_key: r.regist_key,
                rp_key: r.rp_key,
                mac: r.mac,
                has_key_type: u8::from(r.key_type.is_some()),
                has_support_cmd: u8::from(r.support_cmd.is_some()),
                ..empty
            };
            calling_back(|| unsafe { cb(user.ptr(), &res) });
        }
        Err(f) => {
            let text = c_text(&f.text);
            let res = ConRegistrationResult {
                error_text: text.as_ptr(),
                status: f.status,
                http_status: f.http_status,
                app_reason: f.app_reason,
                ..empty
            };
            calling_back(|| unsafe { cb(user.ptr(), &res) });
        }
    }
}

fn run_registration(
    host: String,
    port: u16,
    request: RegistRequest,
    timeouts: RegistTimeouts,
    stop: StopToken,
) -> Result<Registration, RegistFailure> {
    let addr = first_address(&host, port).ok_or_else(|| {
        RegistFailure::new(CON_REGIST_HOST_NOT_FOUND, format!("cannot resolve {host}"))
    })?;
    registration::register(addr, &request, timeouts, &stop).map_err(|e| {
        let (http_status, app_reason) = match &e {
            RegistError::Rejected { status, reason } => {
                (u32::from(*status), reason.map_or(0, |r| r.code()))
            }
            _ => (0, 0),
        };
        RegistFailure {
            http_status,
            app_reason,
            ..RegistFailure::new(regist_status(&e), e.to_string())
        }
    })
}

fn regist_defaults() -> ConRegistrationRequest {
    let t = RegistTimeouts::default();
    ConRegistrationRequest {
        host: std::ptr::null(),
        pin: std::ptr::null(),
        online_id: std::ptr::null(),
        target: CON_TARGET_PS5_1,
        probe_timeout_ms: t.probe.as_millis() as u32,
        io_timeout_ms: t.io.as_millis() as u32,
        port: registration::REGIST_PORT,
        account_id: [0; 8],
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_registration_request_default(out: *mut ConRegistrationRequest) -> i32 {
    guarded(|| write_out(out, regist_defaults()))
}

#[no_mangle]
pub unsafe extern "C" fn con_registration_start(
    request: *const ConRegistrationRequest,
    callback: ConRegistrationCallback,
    user: *mut c_void,
    out: *mut *mut ConRegistration,
) -> i32 {
    guard(|| {
        finish_start(out, || {
            let r = request.as_ref().ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let cb = callback.ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let host = req_str(r.host)?.to_string();
            let pin = req_str(r.pin)?;
            let target = target_from(r.target)?;
            let identity = match opt_str(r.online_id)? {
                Some(name) => Identity::OnlineId(name.to_string()),
                None => Identity::AccountId(r.account_id),
            };
            let user = UserPtr(user);
            let stop = StopToken::new();
            let timeouts = RegistTimeouts {
                probe: Duration::from_millis(u64::from(r.probe_timeout_ms)),
                io: Duration::from_millis(u64::from(r.io_timeout_ms)),
                ..RegistTimeouts::default()
            };
            let port = if r.port == 0 {
                registration::REGIST_PORT
            } else {
                r.port
            };
            let regist_request =
                registration::parse_pin(pin).map(|p| RegistRequest::new(target, identity, p));
            let thread = {
                let stop = stop.clone();
                crate::threads::spawn(ThreadRole::Registration, "con-registration", move || {
                    let outcome = match regist_request {
                        Some(req) => run_registration(host, port, req, timeouts, stop),
                        None => Err(RegistFailure::new(
                            CON_REGIST_INVALID_PIN,
                            RegistError::InvalidPin.to_string(),
                        )),
                    };
                    report_registration(cb, user, target, outcome);
                })
                .map_err(|_| CON_ERR_IO)?
            };
            Ok(ConRegistration {
                job: Job::new(stop, thread),
            })
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_registration_cancel(registration: *mut ConRegistration) {
    guard_void(|| {
        if let Some(r) = registration.as_ref() {
            r.job.stop.stop();
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_registration_free(registration: *mut ConRegistration) {
    guard_void(|| {
        if !registration.is_null() {
            release(Box::from_raw(registration));
        }
    })
}

fn console_defaults() -> ConConsoleConfig {
    ConConsoleConfig {
        host: std::ptr::null(),
        kind: CON_CONSOLE_PS5,
        codec: CON_CODEC_H264,
        video_height: 720,
        max_fps: 60,
        bitrate_kbps: 0,
        session_port: crate::session::SESSION_PORT,
        network_test_port: crate::transport::NETWORK_TEST_PORT,
        stream_port: crate::transport::STREAM_PORT,
        auto_downgrade: 1,
        video_disabled: 0,
        keyboard: 0,
        network_test: 1,
        regist_key: [0; 16],
        rp_key: [0; 16],
    }
}

fn cloud_defaults() -> ConCloudConfig {
    ConCloudConfig {
        address: std::ptr::null(),
        session_id: std::ptr::null(),
        launch_spec: std::ptr::null(),
        codec: CON_CODEC_H264,
        max_fps: 60,
        mtu_in: 0,
        mtu_out: 0,
        rtt_us: 0,
        port: 0,
        prefix: 0,
        ps5: 0,
        handshake_key: [0; 16],
    }
}

fn options_defaults() -> ConSessionOptions {
    ConSessionOptions {
        loss_ceiling: 0.0,
        video_capture_path: std::ptr::null(),
        dualsense: -1,
        log_level: CON_LOG_INFO,
        stats_interval_ms: 0,
        discard_video: 0,
        discard_audio: 0,
        idr_on_fec_failure: 0,
        decode_audio: 1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_console_config_default(out: *mut ConConsoleConfig) -> i32 {
    guarded(|| write_out(out, console_defaults()))
}

#[no_mangle]
pub unsafe extern "C" fn con_cloud_config_default(out: *mut ConCloudConfig) -> i32 {
    guarded(|| write_out(out, cloud_defaults()))
}

#[no_mangle]
pub unsafe extern "C" fn con_session_options_default(out: *mut ConSessionOptions) -> i32 {
    guarded(|| write_out(out, options_defaults()))
}

fn no_data() -> ConEventData {
    unsafe { std::mem::zeroed() }
}

fn opt_i64<T: Into<i64>>(v: Option<T>) -> i64 {
    v.map_or(-1, Into::into)
}

struct Dispatcher {
    callback: unsafe extern "C" fn(*mut c_void, *mut ConEvent),
    user: UserPtr,
    log_level: i32,
    quit: Mutex<bool>,
    quit_sent: RwLock<bool>,
}

impl Dispatcher {
    fn emit(&self, type_: u32, data: ConEventData) -> ConEvent {
        let mut ev = ConEvent { type_, data };
        let user = self.user;
        calling_back(|| unsafe { (self.callback)(user.ptr(), &mut ev) });
        ev
    }

    fn log(&self, level: LogLevel, line: &str) {
        let level = level_to(level);
        if level > self.log_level {
            return;
        }
        let quit_sent = self.quit_sent.read().unwrap_or_else(|p| p.into_inner());
        if *quit_sent {
            return;
        }
        let text = c_text(line);
        self.emit(
            CON_EVENT_LOG,
            ConEventData {
                log: ConLogEvent {
                    text: text.as_ptr(),
                    level,
                },
            },
        );
        drop(quit_sent);
    }

    fn stats(&self, stats: &ConStats) {
        let quit = crate::sync::lock(&self.quit);
        if *quit {
            return;
        }
        self.emit(
            CON_EVENT_STATS,
            ConEventData {
                stats: ConStatsEvent { stats },
            },
        );
        drop(quit);
    }

    fn feedback(&self, f: FeedbackEvent) {
        let (t, d) = match f {
            FeedbackEvent::Rumble { left, right } => (
                CON_EVENT_RUMBLE,
                ConEventData {
                    rumble: ConRumbleEvent { left, right },
                },
            ),
            FeedbackEvent::TriggerEffects { left, right } => (
                CON_EVENT_TRIGGER_EFFECTS,
                ConEventData {
                    trigger_effects: ConTriggerEffectsEvent { left, right },
                },
            ),
            FeedbackEvent::LightBar { r, g, b } => (
                CON_EVENT_LIGHT_BAR,
                ConEventData {
                    light_bar: ConLightBarEvent { r, g, b },
                },
            ),
            FeedbackEvent::PlayerIndex(index) => (
                CON_EVENT_PLAYER_INDEX,
                ConEventData {
                    player_index: ConPlayerIndexEvent { index },
                },
            ),
            FeedbackEvent::EffectIntensity { kind, value } => (
                CON_EVENT_EFFECT_INTENSITY,
                ConEventData {
                    effect_intensity: ConEffectIntensityEvent {
                        kind: match kind {
                            IntensityKind::Haptic => CON_INTENSITY_HAPTIC,
                            IntensityKind::Trigger => CON_INTENSITY_TRIGGER,
                        },
                        value,
                    },
                },
            ),
            FeedbackEvent::MotionReset => (CON_EVENT_MOTION_RESET, no_data()),
        };
        self.emit(t, d);
    }

    fn keyboard(&self, type_: u32, text: &str) {
        let text = c_text(text);
        self.emit(
            type_,
            ConEventData {
                keyboard: ConKeyboardEvent {
                    text: text.as_ptr(),
                },
            },
        );
    }

    fn control(&self, e: ControlEvent) {
        match e {
            ControlEvent::PinRequested { previous_wrong } => {
                self.emit(
                    CON_EVENT_PIN_REQUESTED,
                    ConEventData {
                        pin: ConPinEvent {
                            previous_wrong: u8::from(previous_wrong),
                        },
                    },
                );
            }
            ControlEvent::KeyboardOpened(text) => self.keyboard(CON_EVENT_KEYBOARD_OPENED, &text),
            ControlEvent::KeyboardTextChanged(text) => {
                self.keyboard(CON_EVENT_KEYBOARD_TEXT_CHANGED, &text)
            }
            ControlEvent::KeyboardClosedRemotely => {
                self.emit(CON_EVENT_KEYBOARD_CLOSED, no_data());
            }
            ControlEvent::CannotDisplay(v) => {
                self.emit(
                    CON_EVENT_CANNOT_DISPLAY,
                    ConEventData {
                        display: ConDisplayEvent {
                            cannot_display: u8::from(v),
                        },
                    },
                );
            }
        }
    }

    fn stream(&self, e: StreamEvent) {
        match e {
            StreamEvent::StreamInfo(info) => {
                let profiles: Vec<ConVideoProfile> = info
                    .resolutions
                    .iter()
                    .map(|r| ConVideoProfile {
                        header: r.video_header.as_ptr(),
                        header_size: r.video_header.len(),
                        width: r.width,
                        height: r.height,
                    })
                    .collect();
                let h = crate::media::AudioHeader::parse(&info.audio_header);
                self.emit(
                    CON_EVENT_STREAM_INFO,
                    ConEventData {
                        stream_info: ConStreamInfoEvent {
                            profiles: ptr_or_null(&profiles),
                            profile_count: profiles.len(),
                            start_timeout: opt_i64(info.start_timeout),
                            afk_timeout: opt_i64(info.afk_timeout),
                            afk_disconnect_timeout: opt_i64(info.afk_disconnect_timeout),
                            congestion_control_interval: opt_i64(info.congestion_control_interval),
                            audio_rate: h.map_or(0, |h| h.rate),
                            audio_frame_size: h.map_or(0, |h| h.frame_size),
                            audio_channels: h.map_or(0, |h| h.channels),
                            audio_bits: h.map_or(0, |h| h.bits),
                            audio_header: info.audio_header,
                        },
                    },
                );
            }
            StreamEvent::Connected => {
                self.emit(CON_EVENT_CONNECTED, no_data());
            }
            StreamEvent::ConnectionQuality(q) => {
                self.emit(
                    CON_EVENT_CONNECTION_QUALITY,
                    ConEventData {
                        connection_quality: ConConnectionQualityEvent {
                            upstream_loss: q.upstream_loss.map_or(f64::NAN, f64::from),
                            rtt: q.rtt.unwrap_or(f64::NAN),
                            target_bitrate: opt_i64(q.target_bitrate),
                            upstream_bitrate: opt_i64(q.upstream_bitrate),
                            loss: q.loss.map_or(-1, |l| i64::try_from(l).unwrap_or(i64::MAX)),
                            disable_upstream_audio: q.disable_upstream_audio.map_or(-1, i32::from),
                        },
                    },
                );
            }
            StreamEvent::ServerCorruptFrame(c) => {
                self.emit(
                    CON_EVENT_SERVER_CORRUPT_FRAME,
                    ConEventData {
                        corrupt_frame: ConCorruptFrameEvent {
                            start: c.start,
                            end: c.end,
                        },
                    },
                );
            }
            StreamEvent::CloudPrelude {
                msg_type,
                has_stream_info,
                size,
            } => {
                self.emit(
                    CON_EVENT_CLOUD_PRELUDE,
                    ConEventData {
                        cloud_prelude: ConCloudPreludeEvent {
                            size,
                            msg_type,
                            has_stream_info: u8::from(has_stream_info),
                        },
                    },
                );
            }
            StreamEvent::Feedback(f) => self.feedback(f),
            StreamEvent::FecFailure {
                frame_index,
                idr_requested,
            } => {
                self.emit(
                    CON_EVENT_FEC_FAILURE,
                    ConEventData {
                        fec_failure: ConFecFailureEvent {
                            frame_index,
                            idr_requested: u8::from(idr_requested),
                        },
                    },
                );
            }
        }
    }

    fn session_event(&self, e: SessionEvent) {
        match e {
            SessionEvent::Control(c) => self.control(c),
            SessionEvent::NetworkTest { result, fallback } => {
                self.emit(
                    CON_EVENT_NETWORK_TEST,
                    ConEventData {
                        network_test: ConNetworkTestEvent {
                            rtt_us: result.rtt_us,
                            rtt_samples: result.rtt_samples,
                            mtu_in: result.mtu_in,
                            mtu_out: result.mtu_out,
                            fallback: u8::from(fallback),
                        },
                    },
                );
            }
            SessionEvent::Stream(s) => self.stream(s),
            SessionEvent::Quit {
                reason,
                text,
                stage,
            } => {
                let text = opt_c_text(&text);
                let mut quit = crate::sync::lock(&self.quit);
                *quit = true;
                *self.quit_sent.write().unwrap_or_else(|p| p.into_inner()) = true;
                self.emit(
                    CON_EVENT_QUIT,
                    ConEventData {
                        quit: ConQuitEvent {
                            text: ptr_of(&text),
                            reason: quit_reason_code(reason),
                            stage: stage_code(stage),
                            is_error: u8::from(reason.is_error()),
                        },
                    },
                );
                drop(quit);
            }
        }
    }
}

impl MediaSink for Dispatcher {
    fn video(&self, s: &VideoSample<'_>) -> bool {
        let ev = self.emit(
            CON_EVENT_VIDEO,
            ConEventData {
                video: ConVideoEvent {
                    data: s.padded.as_ptr(),
                    size: s.data.len(),
                    padded_size: s.padded.len(),
                    frames_lost: s.frames_lost,
                    codec: codec_to(s.codec),
                    width: s.width,
                    height: s.height,
                    kind: match s.kind {
                        SampleKind::ParameterSets => CON_VIDEO_PARAMETER_SETS,
                        SampleKind::Picture => CON_VIDEO_PICTURE,
                    },
                    frame_index: s.frame_index,
                    profile: s.profile,
                    recovered: u8::from(s.recovered),
                    fec_recovered: u8::from(s.fec_recovered),
                    keyframe: u8::from(s.keyframe),
                    accepted: 1,
                    flags: if s.decode_only {
                        CON_VIDEO_FLAG_DECODE_ONLY as u8
                    } else {
                        0
                    },
                },
            },
        );
        unsafe { ev.data.video.accepted != 0 }
    }

    fn audio(&self, f: &AudioFrame<'_>) {
        self.emit(
            CON_EVENT_AUDIO,
            ConEventData {
                audio: ConAudioEvent {
                    pcm: ptr_or_null(f.pcm),
                    pcm_count: f.pcm.len(),
                    opus: ptr_or_null(f.opus),
                    opus_size: f.opus.len(),
                    samples_per_channel: f.samples,
                    sample_rate: f.sample_rate,
                    frame_index: f.frame_index,
                    channels: f.channels,
                    decoded: u8::from(f.decoded),
                    concealed: u8::from(f.concealed),
                },
            },
        );
    }

    fn haptics(&self, f: &HapticsFrame<'_>) {
        self.emit(
            CON_EVENT_HAPTICS,
            ConEventData {
                haptics: ConHapticsEvent {
                    pcm: f.pcm.as_ptr(),
                    size: f.pcm.len(),
                    sample_rate: f.sample_rate,
                    frame_index: f.frame_index,
                    channels: f.channels,
                },
            },
        );
    }
}

fn stats_of(stream: &StreamHandle) -> ConStats {
    let t = stream.stats();
    let m = stream.media_stats();
    let v = m.video;
    let a = m.audio;
    let f = m.feedback;
    ConStats {
        rtt_latest_us: t.rtt_latest_us,
        rtt_median_us: t.rtt_median_us,
        rtt_samples: t.rtt_samples,
        datagrams_sent: t.datagrams_sent,
        datagrams_received: t.datagrams_received,
        retransmissions: t.retransmissions,
        given_up: t.given_up,
        tag_failures: t.tag_failures,
        dropped: t.dropped,
        held_media_dropped: t.held_media_dropped,
        messages_delivered: t.messages_delivered,
        media_delivered: t.media_delivered,
        congestion_reports: t.congestion_reports,
        report_received: u64::from(t.last_report.0),
        report_lost: u64::from(t.last_report.1),
        video_packets: v.packets,
        video_packets_dropped: v.packets_dropped,
        video_units_received: v.units_received,
        video_units_rejected: v.units_rejected,
        video_units_late: v.units_late,
        video_profile_switches: v.profile_switches,
        video_frames_complete: v.frames_complete,
        video_frames_fec_recovered: v.frames_fec_recovered,
        video_frames_fec_failed: v.frames_fec_failed,
        video_frames_failed: v.frames_failed,
        video_frames_delivered: v.frames_delivered,
        video_frames_rejected: v.frames_rejected,
        video_frames_skipped_waiting_idr: v.frames_skipped_waiting_idr,
        video_frames_reference_missing: v.frames_reference_missing,
        video_frames_reference_repaired: v.frames_reference_repaired,
        video_frames_unchecked: v.frames_unchecked,
        video_frames_lost: v.frames_lost,
        video_corrupt_reports: v.corrupt_reports,
        video_idr_requests: v.idr_requests,
        video_bytes_delivered: v.bytes_delivered,
        audio_datagrams: a.datagrams,
        audio_datagrams_dropped: a.datagrams_dropped,
        audio_frames_offered: a.frames_offered,
        audio_frames_discarded: a.frames_discarded,
        audio_frames_played: a.frames_played,
        audio_frames_concealed: a.frames_concealed,
        audio_decode_errors: a.decode_errors,
        haptics_datagrams: a.haptics_datagrams,
        haptics_frames: a.haptics_frames,
        haptics_dropped: a.haptics_dropped,
        feedback_state_sent: f.state_sent,
        feedback_history_sent: f.history_sent,
        feedback_history_dropped: f.history_dropped,
        feedback_refreshes: f.refreshes,
        measured_bitrate: m.measured_bitrate,
        running_bitrate: m.running_bitrate,
        audio_decoded: u8::from(m.audio_decoded),
    }
}

pub struct ConSession {
    session: Arc<Session>,
    stats: Option<(StopToken, JoinHandle<()>)>,
}

impl Drop for ConSession {
    fn drop(&mut self) {
        self.session.stop();
        if let Some((stop, thread)) = self.stats.take() {
            stop.stop();
            let _ = thread.join();
        }
    }
}

unsafe fn options_arg(p: *const ConSessionOptions) -> ConSessionOptions {
    if p.is_null() {
        options_defaults()
    } else {
        *p
    }
}

fn apply_options(config: &mut SessionRunnerConfig, o: &ConSessionOptions, d: &Arc<Dispatcher>) {
    if o.loss_ceiling > 0.0 {
        config.loss_ceiling = o.loss_ceiling;
    }
    match o.dualsense {
        0 => config.dualsense = false,
        1 => config.dualsense = true,
        _ => {}
    }
    config.discard_video = o.discard_video != 0;
    config.discard_audio = o.discard_audio != 0;
    config.idr_on_fec_failure = o.idr_on_fec_failure != 0;
    config.decode_audio = o.decode_audio != 0 && cfg!(feature = "opus");
    if o.log_level >= 0 {
        let d = d.clone();
        config.log = Some(Arc::new(move |level, line: &str| d.log(level, line)));
        config.log_max = level_from(o.log_level);
    }
}

fn start_session(
    mut config: SessionRunnerConfig,
    options: &ConSessionOptions,
    callback: unsafe extern "C" fn(*mut c_void, *mut ConEvent),
    user: *mut c_void,
) -> Result<ConSession, i32> {
    let d = Arc::new(Dispatcher {
        callback,
        user: UserPtr(user),
        log_level: options.log_level,
        quit: Mutex::new(false),
        quit_sent: Default::default(),
    });
    apply_options(&mut config, options, &d);
    if let Some(path) = unsafe { opt_str(options.video_capture_path)? } {
        config
            .capture
            .start(
                std::path::Path::new(path),
                Logger::with_max(config.log.clone(), config.log_max),
            )
            .map_err(|_| CON_ERR_IO)?;
    }
    let events = {
        let d = d.clone();
        Arc::new(move |e| d.session_event(e))
    };
    let session = Arc::new(Session::start(config, events, d.clone()));
    let stats = if options.stats_interval_ms > 0 {
        let stop = StopToken::new();
        let interval = Duration::from_millis(u64::from(options.stats_interval_ms));
        let s = session.clone();
        let st = stop.clone();
        let thread = crate::threads::spawn(ThreadRole::Statistics, "con-stats", move || {
            while st.sleep(interval) && !s.is_finished() {
                if let Some(h) = s.stream() {
                    d.stats(&stats_of(&h));
                }
            }
        });
        thread.ok().map(|t| (stop, t))
    } else {
        None
    };
    Ok(ConSession { session, stats })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_start_console(
    config: *const ConConsoleConfig,
    options: *const ConSessionOptions,
    callback: ConEventCallback,
    user: *mut c_void,
    out: *mut *mut ConSession,
) -> i32 {
    guard(|| {
        finish_start(out, || {
            let c = config.as_ref().ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let cb = callback.ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let host = req_str(c.host)?;
            let kind = kind_from(c.kind)?;
            let codec = codec_from(c.codec)?;
            let mut choice = if c.video_disabled != 0 {
                StreamChoice::video_disabled(codec)
            } else {
                let mut choice = StreamChoice::new(c.video_height, c.max_fps, codec);
                choice.auto_downgrade = c.auto_downgrade != 0;
                choice
            };
            if c.bitrate_kbps > 0 {
                choice.preset.bitrate_kbps = c.bitrate_kbps;
            }
            let mut p = ConsoleParams::new(host, kind, c.regist_key, c.rp_key, choice);
            p.keyboard = c.keyboard != 0;
            p.network_test = c.network_test != 0;
            if c.session_port != 0 {
                p.session_port = c.session_port;
            }
            if c.network_test_port != 0 {
                p.network_test_port = c.network_test_port;
            }
            if c.stream_port != 0 {
                p.stream_port = c.stream_port;
            }
            let o = options_arg(options);
            start_session(
                SessionRunnerConfig::new(Connection::Console(p)),
                &o,
                cb,
                user,
            )
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_start_cloud(
    config: *const ConCloudConfig,
    options: *const ConSessionOptions,
    callback: ConEventCallback,
    user: *mut c_void,
    out: *mut *mut ConSession,
) -> i32 {
    guard(|| {
        finish_start(out, || {
            let c = config.as_ref().ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let cb = callback.ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let host = req_str(c.address)?;
            if c.port == 0 {
                return Err(CON_ERR_INVALID_ARGUMENT);
            }
            let addr = first_address(host, c.port).ok_or(CON_ERR_IO)?;
            let session_id = req_str(c.session_id)?.to_string();
            if session_id.len() > 127 {
                return Err(CON_ERR_INVALID_ARGUMENT);
            }
            let slot = CloudSlot {
                addr,
                prefix: c.prefix,
                ps5: c.ps5 != 0,
                session_id,
                handshake_key: c.handshake_key,
                launch_spec: req_str(c.launch_spec)?.to_string(),
                mtu_in: (c.mtu_in != 0).then_some(c.mtu_in),
                mtu_out: (c.mtu_out != 0).then_some(c.mtu_out),
                rtt_us: (c.rtt_us != 0).then_some(u64::from(c.rtt_us)),
                codec: codec_from(c.codec)?,
                max_fps: c.max_fps,
            };
            let o = options_arg(options);
            start_session(
                SessionRunnerConfig::new(Connection::Cloud(slot)),
                &o,
                cb,
                user,
            )
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_stop(session: *mut ConSession) {
    guard_void(|| {
        if let Some(s) = session.as_ref() {
            s.session.stop();
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_is_finished(session: *mut ConSession) -> i32 {
    guard(|| match session.as_ref() {
        Some(s) => i32::from(s.session.is_finished()),
        None => CON_ERR_INVALID_ARGUMENT,
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_free(session: *mut ConSession) {
    guard_void(|| {
        if !session.is_null() {
            let s = Box::from_raw(session);
            s.session.stop();
            release(s);
        }
    })
}

unsafe fn with_control(
    session: *mut ConSession,
    f: impl FnOnce(&ControlHandle) -> Result<(), ControlError>,
) -> i32 {
    guard(|| {
        let Some(s) = session.as_ref() else {
            return CON_ERR_INVALID_ARGUMENT;
        };
        match s.session.control() {
            None => CON_ERR_NOT_READY,
            Some(c) => match f(&c) {
                Ok(()) => CON_OK,
                Err(_) => CON_ERR_SEND_FAILED,
            },
        }
    })
}

unsafe fn with_stream(
    session: *mut ConSession,
    f: impl FnOnce(&StreamHandle) -> Result<(), i32>,
) -> i32 {
    guard(|| {
        let Some(s) = session.as_ref() else {
            return CON_ERR_INVALID_ARGUMENT;
        };
        match s.session.stream() {
            None => CON_ERR_NOT_READY,
            Some(h) => result(f(&h)),
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_submit_pin(
    session: *mut ConSession,
    pin: *const c_char,
) -> i32 {
    match req_str(pin) {
        Ok(p) => with_control(session, |c| c.submit_pin(p)),
        Err(e) => e,
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_session_keyboard_set_text(
    session: *mut ConSession,
    text: *const c_char,
) -> i32 {
    match req_str(text) {
        Ok(t) => with_control(session, |c| c.keyboard_set_text(t)),
        Err(e) => e,
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_session_keyboard_accept(session: *mut ConSession) -> i32 {
    with_control(session, |c| c.keyboard_accept())
}

#[no_mangle]
pub unsafe extern "C" fn con_session_keyboard_cancel(session: *mut ConSession) -> i32 {
    with_control(session, |c| c.keyboard_cancel())
}

#[no_mangle]
pub unsafe extern "C" fn con_session_sleep(session: *mut ConSession) -> i32 {
    with_control(session, |c| c.sleep())
}

#[no_mangle]
pub unsafe extern "C" fn con_session_go_home(session: *mut ConSession) -> i32 {
    with_control(session, |c| c.go_home())
}

#[no_mangle]
pub unsafe extern "C" fn con_session_microphone_connect(session: *mut ConSession) -> i32 {
    with_control(session, |c| c.microphone_connect())
}

#[no_mangle]
pub unsafe extern "C" fn con_session_set_microphone_muted(
    session: *mut ConSession,
    muted: i32,
) -> i32 {
    with_control(session, |c| c.set_microphone_muted(muted != 0))
}

#[no_mangle]
pub unsafe extern "C" fn con_session_send_microphone_pcm(
    session: *mut ConSession,
    pcm: *const i16,
    count: usize,
) -> i32 {
    if pcm.is_null() || count == 0 || !count.is_multiple_of(480) {
        return CON_ERR_INVALID_ARGUMENT;
    }
    let samples = std::slice::from_raw_parts(pcm, count);
    with_stream(session, |h| send_mic(h, samples))
}

fn send_mic(h: &StreamHandle, samples: &[i16]) -> Result<(), i32> {
    #[cfg(feature = "opus")]
    {
        for frame in samples.chunks(480) {
            h.send_microphone_pcm(frame)
                .map_err(|_| CON_ERR_SEND_FAILED)?;
        }
        Ok(())
    }
    #[cfg(not(feature = "opus"))]
    {
        let _ = (h, samples);
        Err(CON_ERR_UNSUPPORTED)
    }
}

fn controller_to_c(s: &ControllerState) -> ConControllerState {
    let t = |t: &Touch| ConTouch {
        id: t.id,
        x: t.x,
        y: t.y,
    };
    ConControllerState {
        buttons: s.buttons,
        left_x: s.left_x,
        left_y: s.left_y,
        right_x: s.right_x,
        right_y: s.right_y,
        touches: [t(&s.touches[0]), t(&s.touches[1])],
        gyro: s.gyro,
        accel: s.accel,
        orientation: s.orientation,
        l2: s.l2,
        r2: s.r2,
    }
}

fn controller_from_c(c: &ConControllerState) -> ControllerState {
    let t = |t: &ConTouch| Touch {
        id: t.id.clamp(-1, 127),
        x: t.x,
        y: t.y,
    };
    ControllerState {
        buttons: c.buttons & 0xffff,
        l2: c.l2,
        r2: c.r2,
        left_x: c.left_x,
        left_y: c.left_y,
        right_x: c.right_x,
        right_y: c.right_y,
        touches: [t(&c.touches[0]), t(&c.touches[1])],
        gyro: c.gyro,
        accel: c.accel,
        orientation: c.orientation,
    }
}

#[no_mangle]
pub unsafe extern "C" fn con_controller_state_idle(out: *mut ConControllerState) -> i32 {
    guarded(|| write_out(out, controller_to_c(&ControllerState::IDLE)))
}

#[no_mangle]
pub unsafe extern "C" fn con_session_set_controller_state(
    session: *mut ConSession,
    state: *const ConControllerState,
) -> i32 {
    let Some(st) = state.as_ref() else {
        return CON_ERR_INVALID_ARGUMENT;
    };
    let st = controller_from_c(st);
    with_stream(session, |h| {
        h.set_controller_state(st);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_request_keyframe(session: *mut ConSession) -> i32 {
    with_stream(session, |h| {
        h.request_idr().map_err(|_| CON_ERR_SEND_FAILED)
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_report_corrupt_frames(
    session: *mut ConSession,
    start: u16,
    end: u16,
) -> i32 {
    with_stream(session, |h| {
        h.report_corrupt_frames(start, end)
            .map_err(|_| CON_ERR_SEND_FAILED)
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_stats(session: *mut ConSession, out: *mut ConStats) -> i32 {
    if out.is_null() {
        return CON_ERR_INVALID_ARGUMENT;
    }
    with_stream(session, |h| {
        out.write(stats_of(h));
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_set_video_capture(
    session: *mut ConSession,
    path: *const c_char,
) -> i32 {
    guarded(|| {
        let s = session.as_ref().ok_or(CON_ERR_INVALID_ARGUMENT)?;
        let path = opt_str(path)?;
        s.session
            .set_video_capture(path.map(std::path::Path::new))
            .map_err(|_| CON_ERR_IO)
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_set_audio_capture(
    session: *mut ConSession,
    path: *const c_char,
) -> i32 {
    guarded(|| {
        let s = session.as_ref().ok_or(CON_ERR_INVALID_ARGUMENT)?;
        let path = opt_str(path)?;
        s.session
            .set_audio_capture(path.map(std::path::Path::new))
            .map_err(|_| CON_ERR_IO)
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_set_reference_repair(
    session: *mut ConSession,
    repair: i32,
) -> i32 {
    guard(|| {
        let Some(s) = session.as_ref() else {
            return CON_ERR_INVALID_ARGUMENT;
        };
        s.session.set_missing_reference(match repair {
            CON_MISSING_REFERENCE_WITHHOLD => MissingReference::Withhold,
            CON_MISSING_REFERENCE_REPAIR_HIDE => MissingReference::Hide,
            _ => MissingReference::Repair,
        });
        CON_OK
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_video_hidden(
    session: *mut ConSession,
    frames: *mut u64,
    runs: *mut u64,
) -> i32 {
    with_stream(session, |h| {
        let v = h.media_stats().video;
        if !frames.is_null() {
            frames.write(v.frames_hidden);
        }
        if !runs.is_null() {
            runs.write(v.hide_runs);
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_session_video_withheld(
    session: *mut ConSession,
    frames: *mut u64,
    periods: *mut u64,
) -> i32 {
    with_stream(session, |h| {
        let v = h.media_stats().video;
        if !frames.is_null() {
            frames.write(v.frames_withheld);
        }
        if !periods.is_null() {
            periods.write(v.withhold_periods);
        }
        Ok(())
    })
}

pub struct ConCloudProbe {
    job: Job,
}

fn probe_defaults() -> ConCloudProbeConfig {
    let t = nettest::Timings::cloud();
    let ms = |d: Duration| d.as_millis() as u32;
    ConCloudProbeConfig {
        address: std::ptr::null(),
        credential: std::ptr::null(),
        connect_timeout_ms: ms(t.connect),
        hello_echo_ms: ms(t.hello_echo),
        pings: t.pings,
        pong_timeout_ms: ms(t.pong),
        mtu_attempts: t.mtu_attempts,
        mtu_wait_min_ms: ms(t.mtu_wait_min),
        mtu_wait_max_ms: ms(t.mtu_wait_max),
        client_mtu_reply_ms: ms(t.client_mtu_reply),
        port: 0,
        prefix: 0,
        measure_mtu: 1,
    }
}

struct ProbeJob {
    host: String,
    port: u16,
    credential: String,
    prefix: u8,
    timings: nettest::Timings,
    measure_mtu: bool,
}

unsafe fn probe_job(c: &ConCloudProbeConfig) -> Result<ProbeJob, i32> {
    if c.port == 0 {
        return Err(CON_ERR_INVALID_ARGUMENT);
    }
    let mut t = nettest::Timings::cloud();
    let or_default = |v: u32, d: Duration| {
        if v == 0 {
            d
        } else {
            Duration::from_millis(u64::from(v))
        }
    };
    t.connect = or_default(c.connect_timeout_ms, t.connect);
    t.hello_echo = or_default(c.hello_echo_ms, t.hello_echo);
    if c.pings > 0 {
        t.pings = c.pings.min(100);
    }
    t.pong = or_default(c.pong_timeout_ms, t.pong);
    if c.mtu_attempts > 0 {
        t.mtu_attempts = c.mtu_attempts.min(10);
    }
    t.mtu_wait_min = or_default(c.mtu_wait_min_ms, t.mtu_wait_min);
    t.mtu_wait_max = or_default(c.mtu_wait_max_ms, t.mtu_wait_max).max(t.mtu_wait_min);
    t.client_mtu_reply = or_default(c.client_mtu_reply_ms, t.client_mtu_reply);
    Ok(ProbeJob {
        host: req_str(c.address)?.to_string(),
        port: c.port,
        credential: req_str(c.credential)?.to_string(),
        prefix: c.prefix,
        timings: t,
        measure_mtu: c.measure_mtu != 0,
    })
}

fn probe_stage_code(s: TestStage) -> u32 {
    match s {
        TestStage::Connect => CON_PROBE_STAGE_CONNECT,
        TestStage::ProtocolRequest | TestStage::Hello => CON_PROBE_STAGE_HELLO,
        TestStage::Rtt => CON_PROBE_STAGE_RTT,
        TestStage::MtuIn => CON_PROBE_STAGE_MTU_IN,
        TestStage::MtuOut => CON_PROBE_STAGE_MTU_OUT,
        TestStage::Done => CON_PROBE_STAGE_DONE,
    }
}

fn probe_status(e: &NetworkTestError, stage: TestStage) -> u32 {
    match e {
        NetworkTestError::Stopped | NetworkTestError::Transport(TransportError::Stopped) => {
            CON_PROBE_CANCELLED
        }
        NetworkTestError::NoRtt => CON_PROBE_NO_RTT,
        NetworkTestError::NoReply(_) => CON_PROBE_NO_CONNECTION,
        NetworkTestError::Transport(_) if stage == TestStage::Connect => CON_PROBE_NO_CONNECTION,
        NetworkTestError::Transport(_) => CON_PROBE_NETWORK,
    }
}

fn empty_probe_result() -> ConCloudProbeResult {
    ConCloudProbeResult {
        rtt_us: 0,
        rtt_samples: 0,
        mtu_in: 0,
        mtu_out: 0,
        status: CON_PROBE_INTERNAL,
        stage: CON_PROBE_STAGE_CONNECT,
        hello_echoed: 0,
        error_text: [0; 128],
    }
}

fn set_error_text(r: &mut ConCloudProbeResult, text: &str) {
    let mut n = text.len().min(r.error_text.len() - 1);
    while !text.is_char_boundary(n) {
        n -= 1;
    }
    for (d, &b) in r.error_text.iter_mut().zip(&text.as_bytes()[..n]) {
        *d = if b == 0 { b'?' as c_char } else { b as c_char };
    }
    r.error_text[n] = 0;
}

fn run_probe(job: ProbeJob, stop: &StopToken) -> ConCloudProbeResult {
    let mut out = empty_probe_result();
    let Some(addr) = first_address(&job.host, job.port) else {
        out.status = CON_PROBE_HOST_NOT_FOUND;
        set_error_text(&mut out, &format!("cannot resolve {}", job.host));
        return out;
    };
    let mut config = NetworkTestConfig::cloud_probe(addr, job.credential, job.prefix);
    config.timings = job.timings;
    config.measure_mtu = job.measure_mtu;
    let report = nettest::run_report(config, stop);
    out.stage = probe_stage_code(report.stage);
    out.hello_echoed = u8::from(report.hello_echoed == Some(true));
    match report.result {
        Ok(r) => {
            out.status = CON_PROBE_OK;
            out.rtt_us = r.rtt_us;
            out.rtt_samples = r.rtt_samples;
            out.mtu_in = r.mtu_in;
            out.mtu_out = r.mtu_out;
        }
        Err(e) => {
            out.status = probe_status(&e, report.stage);
            set_error_text(&mut out, &e.to_string());
        }
    }
    out
}

#[no_mangle]
pub unsafe extern "C" fn con_cloud_probe_config_default(out: *mut ConCloudProbeConfig) -> i32 {
    guarded(|| write_out(out, probe_defaults()))
}

#[no_mangle]
pub unsafe extern "C" fn con_cloud_probe_run(
    config: *const ConCloudProbeConfig,
    out: *mut ConCloudProbeResult,
) -> i32 {
    guarded(|| {
        let c = config.as_ref().ok_or(CON_ERR_INVALID_ARGUMENT)?;
        if out.is_null() {
            return Err(CON_ERR_INVALID_ARGUMENT);
        }
        let job = probe_job(c)?;
        out.write(run_probe(job, &StopToken::new()));
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_cloud_probe_start(
    config: *const ConCloudProbeConfig,
    callback: ConCloudProbeCallback,
    user: *mut c_void,
    out: *mut *mut ConCloudProbe,
) -> i32 {
    guard(|| {
        finish_start(out, || {
            let c = config.as_ref().ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let cb = callback.ok_or(CON_ERR_INVALID_ARGUMENT)?;
            let job = probe_job(c)?;
            let user = UserPtr(user);
            let stop = StopToken::new();
            let thread = {
                let stop = stop.clone();
                crate::threads::spawn(ThreadRole::Probe, "con-probe", move || {
                    let r = catch_unwind(AssertUnwindSafe(|| run_probe(job, &stop)))
                        .unwrap_or_else(|_| empty_probe_result());
                    calling_back(|| unsafe { cb(user.ptr(), &r) });
                })
                .map_err(|_| CON_ERR_IO)?
            };
            Ok(ConCloudProbe {
                job: Job::new(stop, thread),
            })
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_cloud_probe_cancel(probe: *mut ConCloudProbe) {
    guard_void(|| {
        if let Some(p) = probe.as_ref() {
            p.job.stop.stop();
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn con_cloud_probe_free(probe: *mut ConCloudProbe) {
    guard_void(|| {
        if !probe.is_null() {
            release(Box::from_raw(probe));
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panic_never_crosses_the_boundary() {
        assert_eq!(
            guard(|| panic!("a deliberate panic inside guard")),
            CON_ERR_PANIC
        );
        let mut ran = false;
        guard_void(|| {
            ran = true;
            panic!("a deliberate panic inside guard_void")
        });
        assert!(ran);
        assert_eq!(guard(|| CON_OK), CON_OK);
    }
}
