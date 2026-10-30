use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::ops::RangeInclusive;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::{
    parse_search_response, search_message, wake_datagram, DiscoveredHost, WakeError, CLIENT_PORTS,
    PS4_PORT, PS5_PORT,
};
use crate::net::UdpSock;
use crate::ConsoleKind;

#[derive(Clone, Debug)]
pub struct DiscoveryConfig {
    pub destination: IpAddr,
    pub extra_destinations: Vec<IpAddr>,
    pub ps4_port: u16,
    pub ps5_port: u16,
    pub initial_delay: Duration,
    pub period: Duration,
    pub drop_after_rounds: u64,
    pub max_consoles: usize,
    pub bind_address: IpAddr,
    pub local_ports: RangeInclusive<u16>,
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        Self {
            destination: IpAddr::V4(Ipv4Addr::BROADCAST),
            extra_destinations: Vec::new(),
            ps4_port: PS4_PORT,
            ps5_port: PS5_PORT,
            initial_delay: Duration::from_millis(500),
            period: Duration::from_millis(500),
            drop_after_rounds: 3,
            max_consoles: 16,
            bind_address: IpAddr::V4(Ipv4Addr::UNSPECIFIED),
            local_ports: CLIENT_PORTS,
        }
    }
}

impl DiscoveryConfig {
    pub fn destinations(&self) -> Vec<IpAddr> {
        let mut out = vec![self.destination];
        for d in &self.extra_destinations {
            if !out.contains(d) {
                out.push(*d);
            }
        }
        out
    }

    fn port(&self, kind: ConsoleKind) -> u16 {
        match kind {
            ConsoleKind::Ps4 => self.ps4_port,
            ConsoleKind::Ps5 => self.ps5_port,
        }
    }
}

pub type HostsCallback = Box<dyn FnMut(&[DiscoveredHost]) + Send>;

struct Entry {
    host: DiscoveredHost,
    last_round: u64,
}

pub struct DiscoveryService {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    socket: UdpSock,
    config: DiscoveryConfig,
}

impl DiscoveryService {
    pub fn start(config: DiscoveryConfig, on_change: HostsCallback) -> io::Result<Self> {
        let socket = UdpSock::bind_in_range(config.bind_address, config.local_ports.clone())?;
        socket.set_broadcast(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let worker = Worker {
            socket: socket.try_clone()?,
            config: config.clone(),
            stop: stop.clone(),
            entries: Vec::new(),
            round: 0,
            on_change,
        };
        let thread = crate::threads::spawn(
            crate::threads::ThreadRole::Discovery,
            "con-discovery",
            move || worker.run(),
        )?;
        Ok(Self {
            stop,
            thread: Some(thread),
            socket,
            config,
        })
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.socket.local_addr()
    }

    pub fn wake(
        &self,
        console: IpAddr,
        kind: ConsoleKind,
        regist_key: &[u8; 16],
    ) -> Result<(), WakeError> {
        let datagram = wake_datagram(kind, regist_key)?;
        let to = SocketAddr::new(console, self.config.port(kind));
        self.socket.send_to(&datagram, to)?;
        Ok(())
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for DiscoveryService {
    fn drop(&mut self) {
        self.shutdown();
    }
}

struct Worker {
    socket: UdpSock,
    config: DiscoveryConfig,
    stop: Arc<AtomicBool>,
    entries: Vec<Entry>,
    round: u64,
    on_change: HostsCallback,
}

impl Worker {
    fn run(mut self) {
        let mut next_round = Instant::now() + self.config.initial_delay;
        let mut buf = [0u8; 1500];
        while !self.stop.load(Ordering::SeqCst) {
            let now = Instant::now();
            if now >= next_round {
                self.do_round();
                next_round += self.config.period;
                if next_round < now {
                    next_round = now + self.config.period;
                }
                continue;
            }
            let wait = (next_round - now).min(Duration::from_millis(50));
            match self.socket.recv_from(&mut buf, wait) {
                Ok(Some((n, from))) => {
                    if let Some(host) = parse_search_response(&buf[..n], from.ip()) {
                        self.update(host);
                    }
                }
                Ok(None) => {}
                Err(_) => std::thread::sleep(Duration::from_millis(20)),
            }
        }
    }

    fn do_round(&mut self) {
        self.round += 1;
        let round = self.round;
        let k = self.config.drop_after_rounds;
        let before = self.entries.len();
        self.entries.retain(|e| e.last_round + k >= round);
        if self.entries.len() != before {
            self.report();
        }
        let destinations = self.config.destinations();
        for kind in [ConsoleKind::Ps4, ConsoleKind::Ps5] {
            let msg = search_message(kind);
            let port = self.config.port(kind);
            for d in &destinations {
                let _ = self.socket.send_to(&msg, SocketAddr::new(*d, port));
            }
        }
    }

    fn update(&mut self, host: DiscoveredHost) {
        let round = self.round;
        if let Some(e) = self
            .entries
            .iter_mut()
            .find(|e| e.host.host_id == host.host_id)
        {
            e.last_round = round;
            if e.host != host {
                e.host = host;
                self.report();
            }
        } else if self.entries.len() < self.config.max_consoles {
            self.entries.push(Entry {
                host,
                last_round: round,
            });
            self.report();
        }
    }

    fn report(&mut self) {
        let list: Vec<DiscoveredHost> = self.entries.iter().map(|e| e.host.clone()).collect();
        (self.on_change)(&list);
    }
}
