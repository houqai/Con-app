use super::{field, proto_message, FieldReader, ProtoError, ProtoMessage, RawValue};

pub mod msg_type {
    pub const BIG: u32 = 0;
    pub const BANG: u32 = 1;
    pub const INFO: u32 = 2;
    pub const HEARTBEAT: u32 = 3;
    pub const PACKETLOSS: u32 = 4;
    pub const CORRUPTFRAME: u32 = 5;
    pub const CURSOR: u32 = 6;
    pub const TIMER: u32 = 7;
    pub const DISCONNECT: u32 = 8;
    pub const LOG: u32 = 9;
    pub const HEADERREQUEST: u32 = 10;
    pub const DEBUG: u32 = 11;
    pub const SENKUSHA: u32 = 12;
    pub const STREAMINFO: u32 = 13;
    pub const STREAMINFOACK: u32 = 14;
    pub const XMBCOMMAND: u32 = 15;
    pub const CONNECTIONQUALITY: u32 = 16;
    pub const CLIENTMETRIC: u32 = 17;
    pub const PLAYTIMELEFT: u32 = 18;
    pub const SERVERMESSAGE: u32 = 19;
    pub const FPSCHANGE: u32 = 20;
    pub const CONTROLLERCONNECTION: u32 = 21;
    pub const CLIENTINFO: u32 = 22;
    pub const VIDEOCAPTURE: u32 = 23;
    pub const AUDIOCAPTURE: u32 = 24;
    pub const IDRREQUEST: u32 = 25;
    pub const GKTRACE: u32 = 26;
    pub const PERIODICTIMESTAMP: u32 = 27;
    pub const SERVERSETTINGS: u32 = 28;
    pub const DIRECTMESSAGE: u32 = 29;
    pub const MICCONNECTION: u32 = 30;
    pub const TAKIONPROTOCOLREQUEST: u32 = 31;
    pub const TAKIONPROTOCOLREQUESTACK: u32 = 32;
}

pub fn payload_field(msg_type: u32) -> Option<u32> {
    match msg_type {
        msg_type::BIG => Some(2),
        msg_type::BANG => Some(3),
        msg_type::INFO => Some(4),
        msg_type::PACKETLOSS => Some(5),
        msg_type::CORRUPTFRAME => Some(6),
        msg_type::CURSOR => Some(8),
        msg_type::TIMER => Some(9),
        msg_type::DISCONNECT..=msg_type::STREAMINFO => Some(msg_type + 2),
        msg_type::XMBCOMMAND..=msg_type::AUDIOCAPTURE => Some(msg_type + 1),
        msg_type::GKTRACE..=msg_type::TAKIONPROTOCOLREQUESTACK => Some(msg_type),
        _ => None,
    }
}

proto_message! {
    pub struct EventCode {
        1 req code: String,
        2 opt name: String,
        3 opt description: String,
    }
}

proto_message! {
    pub struct Big {
        1 req version: u32,
        2 req session_key: String,
        3 req launch_spec: String,
        4 req encrypted_key: Vec<u8>,
        5 opt ecdh_public_key: Vec<u8>,
        6 opt ecdh_signature: Vec<u8>,
    }
}

proto_message! {
    pub struct Bang {
        1 req server_version: u32,
        2 req token: u64,
        3 req encrypted_key_accepted: bool,
        4 req version_accepted: bool,
        5 req session_key: String,
        6 opt extended_info: EventCode,
        7 opt server_version_string: String,
        8 opt ecdh_public_key: Vec<u8>,
        9 opt ecdh_signature: Vec<u8>,
    }
}

proto_message! {
    pub struct Resolution {
        1 req width: u32,
        2 req height: u32,
        3 req video_header: Vec<u8>,
    }
}

proto_message! {
    pub struct AudioChannel {
        1 req channel_type: u32,
        2 req audio_header: Vec<u8>,
        3 opt raw_pcm: bool,
    }
}

proto_message! {
    pub struct StreamInfo {
        1 rep resolutions: Resolution,
        2 req audio_header: Vec<u8>,
        3 opt start_timeout: u32,
        4 opt afk_timeout: u32,
        5 opt afk_disconnect_timeout: u32,
        6 opt congestion_control_interval: u32,
        7 rep audio_channels: AudioChannel,
    }
}

proto_message! {
    pub struct ControllerConnection {
        1 opt controller_id: i32,
        2 opt connected: bool,
        3 opt controller_type: u32,
    }
}

proto_message! {
    pub struct Disconnect {
        1 req reason: String,
        2 opt extended_info: EventCode,
    }
}

proto_message! {
    pub struct CorruptFrame {
        1 req start: u32,
        2 req end: u32,
    }
}

proto_message! {
    pub struct ConnectionQuality {
        1 opt target_bitrate: u32,
        2 opt upstream_bitrate: u32,
        3 opt upstream_loss: f32,
        4 opt disable_upstream_audio: bool,
        5 opt rtt: f64,
        6 opt loss: u64,
    }
}

proto_message! {
    pub struct TakionProtocolRequest {
        1 rep supported_versions: u32,
    }
}

proto_message! {
    pub struct TakionProtocolRequestAck {
        1 opt version: u32,
    }
}

proto_message! {
    pub struct SenkushaEcho {
        1 req state: bool,
    }
}

proto_message! {
    pub struct SenkushaMtu {
        1 req id: u32,
        2 req requested_mtu: u32,
        3 opt mtu_sent: u32,
        4 opt count: u32,
        5 opt send_delay: u32,
        6 opt delta: u32,
    }
}

proto_message! {
    pub struct SenkushaBandwidth {
        1 req id: u32,
        2 req time: u32,
        3 opt bandwidth: u32,
        4 opt fps: u32,
        5 opt mtu: u32,
        6 opt nal_unit_count: u32,
        7 opt total_sent: u32,
        8 opt upstream: bool,
        9 opt loss: f64,
    }
}

proto_message! {
    pub struct SenkushaClientMtu {
        1 req id: u32,
        2 req requested_mtu: u32,
        3 req state: bool,
        4 opt downstream_mtu: u32,
    }
}

proto_message! {
    pub struct Senkusha {
        1 req command: u32,
        2 opt echo: SenkushaEcho,
        3 opt mtu: SenkushaMtu,
        4 opt bandwidth: SenkushaBandwidth,
        5 opt client_mtu: SenkushaClientMtu,
    }
}

pub mod senkusha_command {
    pub const ECHO: u32 = 0;
    pub const MTU: u32 = 1;
    pub const BANDWIDTH: u32 = 3;
    pub const CLIENT_MTU: u32 = 4;
}

proto_message! {
    pub struct Info {
        1 req effective_bandwidth: u32,
        2 req bitrate: u32,
        3 req min_bitrate: u32,
        4 req target_bitrate: u32,
        5 req corrupt_frame_frequency: u32,
        6 req mtu: u32,
        7 req fps: u32,
        8 req monitor_interval: u32,
        9 req external_overhead: u32,
        10 req internal_overhead: u32,
        11 req timeout_interval: u32,
        12 req min_resume_quality: u32,
        13 req min_fps: u32,
    }
}

proto_message! {
    pub struct PacketLoss {
        1 req start: u32,
        2 req end: u32,
        3 req packets_received: u32,
    }
}

proto_message! {
    pub struct Cursor {
        1 req id: u32,
        2 req width: u32,
        3 req height: u32,
        4 req hotspot_x: u32,
        5 req hotspot_y: u32,
        6 opt pixels: Vec<u8>,
    }
}

proto_message! {
    pub struct Timer {
        1 req seconds_left: u32,
        2 req total_seconds: u32,
    }
}

proto_message! {
    pub struct LogEntry {
        1 req timestamp: i64,
        2 req level: u32,
        3 req component: String,
        4 req message: String,
        5 opt timestamp_double: f64,
    }
}

proto_message! {
    pub struct Log {
        1 rep entries: LogEntry,
    }
}

proto_message! {
    pub struct HeaderRequest {
        1 req header_type: u32,
    }
}

proto_message! {
    pub struct DebugOverlay {
        1 opt enable: bool,
        2 opt toggle: bool,
        3 opt location: u32,
        4 opt level: u32,
    }
}

proto_message! {
    pub struct DebugBitrate {
        1 opt toggle: bool,
        2 opt bitrate_change: f32,
    }
}

proto_message! {
    pub struct DebugCommand {
        1 req debug_type: u32,
        2 opt overlay: DebugOverlay,
        3 opt bitrate: DebugBitrate,
    }
}

proto_message! {
    pub struct XmbCommand {
        1 req command: u32,
        2 opt player_id: u32,
    }
}

proto_message! {
    pub struct ClientMetricEntry {
        1 req category: u32,
        2 req start_frame: i32,
        3 req end_frame: i32,
        5 req count: i32,
        6 req average: f32,
        7 req std_dev: f32,
        8 req min: f32,
        9 req max: f32,
    }
}

proto_message! {
    pub struct ClientMetric {
        1 rep metrics: ClientMetricEntry,
    }
}

proto_message! {
    pub struct PlayTimeLeft {
        1 opt time_left: u32,
        2 opt reason: String,
    }
}

proto_message! {
    pub struct ServerMessage {
        1 opt payload: String,
    }
}

proto_message! {
    pub struct FpsChange {
        1 req fps: u32,
    }
}

proto_message! {
    pub struct ClientInfo {
        1 req session_key: String,
        2 opt gcm_tag: u64,
        3 opt key_position: u64,
    }
}

proto_message! {
    pub struct VideoCapture {
        1 opt server_side: bool,
        2 opt idr_period: u32,
    }
}

proto_message! {
    pub struct AudioCapture {
        1 opt server_side: bool,
    }
}

proto_message! {
    pub struct GkTrace {
        1 req sequence_number: u64,
        2 req gcm_tag: u64,
        3 req key_position: u64,
    }
}

proto_message! {
    pub struct PeriodicTimestamp {
        1 req timestamp_info: Vec<u8>,
        2 req version: u32,
    }
}

proto_message! {
    pub struct ServerSettings {
        1 opt idr_period: u32,
        2 opt send_periodic_timestamp: bool,
    }
}

proto_message! {
    pub struct DirectMessage {
        1 req message_type: u32,
        2 req destination: u32,
        3 opt data: Vec<u8>,
    }
}

proto_message! {
    pub struct MicConnection {
        1 req controller_id: i32,
        2 req connected: bool,
        3 opt result: bool,
    }
}

proto_message! {
    pub struct DeepLink {
        1 req link_type: u32,
        2 opt request_id: u32,
        3 opt pad_unique_id: u64,
        4 opt invitation_id: String,
        5 opt session_id: String,
        6 opt item_id: String,
        7 opt system_ui_overlaid: String,
        8 opt result: u32,
        9 opt should_show: bool,
        10 opt raw_data: String,
    }
}

proto_message! {
    pub struct MicInfo {
        1 req info_type: u32,
        2 opt controller_id: i32,
        3 opt connected: bool,
        4 opt muted: bool,
        5 opt result: bool,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Envelope {
    pub msg_type: u32,
    pub payload: Option<Vec<u8>>,
    pub present: Vec<u32>,
}

impl Envelope {
    pub fn decode(data: &[u8]) -> Result<Self, ProtoError> {
        let mut msg_type: Option<u32> = None;
        let mut fields: Vec<(u32, Vec<u8>)> = Vec::new();
        let mut r = FieldReader::new(data);
        while let Some((num, raw)) = r.next_field()? {
            match (num, raw) {
                (1, raw) => field::get_one(&mut msg_type, 1, raw)?,
                (n, RawValue::Len(b)) => fields.push((n, b.to_vec())),
                _ => {}
            }
        }
        let msg_type = field::required(msg_type, "Envelope", 1)?;
        let want = payload_field(msg_type);
        let present = fields.iter().map(|(n, _)| *n).collect();
        let payload = fields
            .into_iter()
            .rev()
            .find(|(n, _)| Some(*n) == want)
            .map(|(_, b)| b);
        Ok(Self {
            msg_type,
            payload,
            present,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    Big(Big),
    Bang(Bang),
    Info(Info),
    Heartbeat,
    PacketLoss(PacketLoss),
    CorruptFrame(CorruptFrame),
    Cursor(Cursor),
    Timer(Timer),
    Disconnect(Disconnect),
    Log(Log),
    HeaderRequest(HeaderRequest),
    Debug(DebugCommand),
    Senkusha(Senkusha),
    StreamInfo(StreamInfo),
    StreamInfoAck,
    XmbCommand(XmbCommand),
    ConnectionQuality(ConnectionQuality),
    ClientMetric(ClientMetric),
    PlayTimeLeft(PlayTimeLeft),
    ServerMessage(ServerMessage),
    FpsChange(FpsChange),
    ControllerConnection(ControllerConnection),
    ClientInfo(ClientInfo),
    VideoCapture(VideoCapture),
    AudioCapture(AudioCapture),
    IdrRequest,
    GkTrace(GkTrace),
    PeriodicTimestamp(PeriodicTimestamp),
    ServerSettings(ServerSettings),
    DirectMessage(DirectMessage),
    MicConnection(MicConnection),
    TakionProtocolRequest(TakionProtocolRequest),
    TakionProtocolRequestAck(TakionProtocolRequestAck),
    Unknown { msg_type: u32 },
}

macro_rules! message_table {
    ($( $ty:path => $variant:ident ($payload:ident) ),* ; $( $nty:path => $nvariant:ident ),*) => {
        impl Message {
            pub fn msg_type(&self) -> u32 {
                match self {
                    $( Message::$variant(_) => $ty, )*
                    $( Message::$nvariant => $nty, )*
                    Message::Unknown { msg_type } => *msg_type,
                }
            }

            pub fn encode(&self) -> Vec<u8> {
                let mut out = Vec::new();
                field::put_one(&mut out, 1, &self.msg_type());
                match self {
                    $( Message::$variant(p) => {
                        field::put_one(&mut out, payload_field($ty).expect("payload field"), p);
                    } )*
                    _ => {}
                }
                out
            }

            pub fn from_envelope(env: &Envelope) -> Result<Message, ProtoError> {
                let p: &[u8] = env.payload.as_deref().unwrap_or(&[]);
                Ok(match env.msg_type {
                    $( $ty => Message::$variant($payload::decode(p)?), )*
                    $( $nty => Message::$nvariant, )*
                    other => Message::Unknown { msg_type: other },
                })
            }
        }
    };
}

message_table! {
    msg_type::BIG => Big(Big),
    msg_type::BANG => Bang(Bang),
    msg_type::INFO => Info(Info),
    msg_type::PACKETLOSS => PacketLoss(PacketLoss),
    msg_type::CORRUPTFRAME => CorruptFrame(CorruptFrame),
    msg_type::CURSOR => Cursor(Cursor),
    msg_type::TIMER => Timer(Timer),
    msg_type::DISCONNECT => Disconnect(Disconnect),
    msg_type::LOG => Log(Log),
    msg_type::HEADERREQUEST => HeaderRequest(HeaderRequest),
    msg_type::DEBUG => Debug(DebugCommand),
    msg_type::SENKUSHA => Senkusha(Senkusha),
    msg_type::STREAMINFO => StreamInfo(StreamInfo),
    msg_type::XMBCOMMAND => XmbCommand(XmbCommand),
    msg_type::CONNECTIONQUALITY => ConnectionQuality(ConnectionQuality),
    msg_type::CLIENTMETRIC => ClientMetric(ClientMetric),
    msg_type::PLAYTIMELEFT => PlayTimeLeft(PlayTimeLeft),
    msg_type::SERVERMESSAGE => ServerMessage(ServerMessage),
    msg_type::FPSCHANGE => FpsChange(FpsChange),
    msg_type::CONTROLLERCONNECTION => ControllerConnection(ControllerConnection),
    msg_type::CLIENTINFO => ClientInfo(ClientInfo),
    msg_type::VIDEOCAPTURE => VideoCapture(VideoCapture),
    msg_type::AUDIOCAPTURE => AudioCapture(AudioCapture),
    msg_type::GKTRACE => GkTrace(GkTrace),
    msg_type::PERIODICTIMESTAMP => PeriodicTimestamp(PeriodicTimestamp),
    msg_type::SERVERSETTINGS => ServerSettings(ServerSettings),
    msg_type::DIRECTMESSAGE => DirectMessage(DirectMessage),
    msg_type::MICCONNECTION => MicConnection(MicConnection),
    msg_type::TAKIONPROTOCOLREQUEST => TakionProtocolRequest(TakionProtocolRequest),
    msg_type::TAKIONPROTOCOLREQUESTACK => TakionProtocolRequestAck(TakionProtocolRequestAck);
    msg_type::HEARTBEAT => Heartbeat,
    msg_type::STREAMINFOACK => StreamInfoAck,
    msg_type::IDRREQUEST => IdrRequest
}

impl Message {
    pub fn decode(data: &[u8]) -> Result<Message, ProtoError> {
        Message::from_envelope(&Envelope::decode(data)?)
    }
}

pub const CLIENT_DISCONNECT_REASON: &str = "Client Disconnecting";

pub const SERVER_SHUTDOWN_REASON: &str = "Server shutting down";

pub const CLIENT_MIC_AUDIO_HEADER: [u8; 14] = [
    0x01, 0x10, 0x00, 0x00, 0xbb, 0x80, 0x00, 0x00, 0x01, 0xe0, 0x00, 0x00, 0x00, 0x00,
];

pub fn client_stream_info() -> Message {
    Message::StreamInfo(StreamInfo {
        audio_header: CLIENT_MIC_AUDIO_HEADER.to_vec(),
        ..Default::default()
    })
}

pub fn client_disconnect() -> Message {
    Message::Disconnect(Disconnect {
        reason: CLIENT_DISCONNECT_REASON.into(),
        extended_info: None,
    })
}

const CONTROLLER_TYPE_DUALSENSE: u32 = 6;
const CONTROLLER_TYPE_DUALSHOCK4: u32 = 2;

pub fn controller_connection(dualsense: bool) -> Message {
    Message::ControllerConnection(ControllerConnection {
        controller_id: None,
        connected: Some(true),
        controller_type: Some(if dualsense {
            CONTROLLER_TYPE_DUALSENSE
        } else {
            CONTROLLER_TYPE_DUALSHOCK4
        }),
    })
}
