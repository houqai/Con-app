pub mod control;
pub mod messages;
pub mod request;

use std::net::SocketAddr;
use std::time::Duration;

pub use control::{
    ControlChannel, ControlConfig, ControlError, ControlEvent, ControlHandle, ControlInfo,
    ControlTimeouts, EventSink, SessionId,
};
pub use request::{
    request_session, RequestTimeouts, SessionGrant, SessionRequestError, SESSION_PORT,
};

use crate::crypto::rp::RpCipher;
use crate::{Codec, ConsoleKind, Stage, StopToken, Target};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum QuitReason {
    Stopped,
    SessionRequestUnknown,
    SessionRequestConnectionRefused,
    SessionRequestInUse,
    SessionRequestCrashed,
    SessionRequestVersionMismatch,
    ControlUnknown,
    ControlConnectFailed,
    ControlConnectionRefused,
    StreamUnknown,
    StreamRemoteDisconnected,
    StreamRemoteShutdown,
    PsnRegistrationFailed,
}

impl QuitReason {
    pub fn is_error(self) -> bool {
        !matches!(self, Self::Stopped | Self::StreamRemoteShutdown)
    }

    pub fn for_remote_disconnect(text: &str) -> Self {
        if text == crate::proto::SERVER_SHUTDOWN_REASON {
            Self::StreamRemoteShutdown
        } else {
            Self::StreamRemoteDisconnected
        }
    }
}

impl From<&SessionRequestError> for QuitReason {
    fn from(e: &SessionRequestError) -> Self {
        match e {
            SessionRequestError::Stopped => Self::Stopped,
            SessionRequestError::ConnectionRefused => Self::SessionRequestConnectionRefused,
            SessionRequestError::InUse => Self::SessionRequestInUse,
            SessionRequestError::Crashed => Self::SessionRequestCrashed,
            SessionRequestError::VersionMismatch => Self::SessionRequestVersionMismatch,
            SessionRequestError::Unknown(_) => Self::SessionRequestUnknown,
        }
    }
}

impl From<&ControlError> for QuitReason {
    fn from(e: &ControlError) -> Self {
        match e {
            ControlError::Stopped => Self::Stopped,
            ControlError::ConnectFailed(_) => Self::ControlConnectFailed,
            ControlError::Failed(_) => Self::ControlUnknown,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{reason:?}: {detail}")]
pub struct StartError {
    pub reason: QuitReason,
    pub stage: Stage,
    pub detail: String,
}

#[derive(Clone)]
pub struct SessionConfig {
    pub host: String,
    pub port: u16,
    pub kind: ConsoleKind,
    pub regist_key: [u8; 16],
    pub rp_key: [u8; 16],
    pub codec: Codec,
    pub dualsense: bool,
    pub keyboard: bool,
    pub request_timeouts: RequestTimeouts,
    pub control_timeouts: ControlTimeouts,
    pub control_pause: Duration,
}

impl std::fmt::Debug for SessionConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("kind", &self.kind)
            .field("codec", &self.codec)
            .finish_non_exhaustive()
    }
}

impl SessionConfig {
    pub fn new(
        host: impl Into<String>,
        kind: ConsoleKind,
        regist_key: [u8; 16],
        rp_key: [u8; 16],
    ) -> Self {
        Self {
            host: host.into(),
            port: SESSION_PORT,
            kind,
            regist_key,
            rp_key,
            codec: Codec::H264,
            dualsense: false,
            keyboard: false,
            request_timeouts: RequestTimeouts::default(),
            control_timeouts: ControlTimeouts::default(),
            control_pause: Duration::from_millis(10),
        }
    }
}

pub struct StartedSession {
    pub target: Target,
    pub console_addr: SocketAddr,
    pub cipher: RpCipher,
    pub control: ControlChannel,
    pub session_id: SessionId,
}

pub fn start(
    config: &SessionConfig,
    events: EventSink,
    on_control: impl FnOnce(ControlHandle),
    stop: &StopToken,
) -> Result<StartedSession, StartError> {
    let fail = |reason: QuitReason, stage: Stage, detail: String| StartError {
        reason,
        stage,
        detail,
    };
    let stopped = || fail(QuitReason::Stopped, Stage::Control, "stopped".into());
    let grant = request_session(
        &config.host,
        config.port,
        config.kind,
        &config.regist_key,
        config.request_timeouts,
        stop,
    )
    .map_err(|e| fail(QuitReason::from(&e), Stage::SessionRequest, e.to_string()))?;

    let cipher = RpCipher::for_session(grant.target, &grant.nonce, &config.rp_key);
    if !stop.sleep(config.control_pause) {
        return Err(stopped());
    }

    let control_config = ControlConfig {
        console_addr: grant.console_addr,
        target: grant.target,
        regist_key: config.regist_key,
        cipher: cipher.clone(),
        codec: config.codec,
        dualsense: config.dualsense,
        keyboard: config.keyboard,
        device_id: messages::new_device_id(),
        timeouts: config.control_timeouts,
    };
    let control = ControlChannel::connect(&control_config, events, stop).map_err(|e| match e {
        ControlError::Stopped => stopped(),
        other => fail(
            QuitReason::ControlConnectFailed,
            Stage::Control,
            other.to_string(),
        ),
    })?;
    on_control(control.handle());
    let session_id = control
        .wait_session_id(stop)
        .map_err(|e| fail(QuitReason::from(&e), Stage::Control, e.to_string()))?;
    Ok(StartedSession {
        target: grant.target,
        console_addr: grant.console_addr,
        cipher,
        control,
        session_id,
    })
}
