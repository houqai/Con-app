use std::io::{self, Read, Write};
use std::net::{
    IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpStream, ToSocketAddrs, UdpSocket,
};
use std::ops::RangeInclusive;
use std::time::{Duration, Instant};

use crate::http::header_end;
use crate::StopToken;

pub(crate) const POLL_STEP: Duration = Duration::from_millis(50);

const ERROR_IO_PENDING: i32 = 997;
const WSAENETRESET: i32 = 10052;
const WSAEMSGSIZE: i32 = 10040;

fn interrupted() -> io::Error {
    io::Error::new(io::ErrorKind::Interrupted, "stopped")
}

fn timed_out() -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, "timed out")
}

fn is_timeout(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    ) || (cfg!(windows) && e.raw_os_error() == Some(ERROR_IO_PENDING))
}

fn is_icmp_error(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::ConnectionRefused | io::ErrorKind::ConnectionReset
    ) || (cfg!(windows) && e.raw_os_error() == Some(WSAENETRESET))
}

fn is_truncated_datagram(e: &io::Error) -> bool {
    cfg!(windows) && e.raw_os_error() == Some(WSAEMSGSIZE)
}

fn step_until(deadline: Instant) -> Option<Duration> {
    let now = Instant::now();
    if now >= deadline {
        return None;
    }
    Some(
        (deadline - now)
            .min(POLL_STEP)
            .max(Duration::from_millis(1)),
    )
}

pub(crate) fn resolve(host: &str, port: u16) -> io::Result<Vec<SocketAddr>> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, port)]);
    }
    let trimmed = host.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = trimmed.parse::<Ipv6Addr>() {
        return Ok(vec![SocketAddr::new(IpAddr::V6(ip), port)]);
    }
    let want_v6 = host.contains(':');
    let addrs: Vec<SocketAddr> = (host, port)
        .to_socket_addrs()?
        .filter(|a| a.is_ipv6() == want_v6)
        .collect();
    if addrs.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "host name has no address in the requested family",
        ));
    }
    Ok(addrs)
}

pub(crate) struct TcpConn {
    stream: TcpStream,
}

impl TcpConn {
    pub fn connect(addr: SocketAddr, timeout: Duration) -> io::Result<Self> {
        let stream = TcpStream::connect_timeout(&addr, timeout)?;
        let _ = stream.set_nodelay(true);
        Ok(Self { stream })
    }

    pub fn try_clone(&self) -> io::Result<Self> {
        Ok(Self {
            stream: self.stream.try_clone()?,
        })
    }

    pub fn send_all(&mut self, data: &[u8], timeout: Duration) -> io::Result<()> {
        self.stream
            .set_write_timeout(Some(timeout.max(Duration::from_millis(1))))?;
        self.stream.write_all(data)
    }

    pub fn read_header(
        &mut self,
        timeout: Duration,
        max_len: usize,
        stop: &StopToken,
    ) -> io::Result<(Vec<u8>, Vec<u8>)> {
        let deadline = Instant::now() + timeout;
        let mut buf = Vec::with_capacity(512);
        let mut chunk = [0u8; 1024];
        loop {
            if let Some(end) = header_end(&buf) {
                let rest = buf.split_off(end);
                return Ok((buf, rest));
            }
            if buf.len() > max_len {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "response header too long",
                ));
            }
            if stop.is_stopped() {
                return Err(interrupted());
            }
            let Some(step) = step_until(deadline) else {
                return Err(timed_out());
            };
            self.stream.set_read_timeout(Some(step))?;
            match self.stream.read(&mut chunk) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "connection closed before the header ended",
                    ))
                }
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
                Err(e) if is_timeout(&e) || e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
    }

    pub fn read_to_len(
        &mut self,
        buf: &mut Vec<u8>,
        total: usize,
        timeout: Duration,
        stop: &StopToken,
    ) -> io::Result<()> {
        let deadline = Instant::now() + timeout;
        let mut chunk = [0u8; 2048];
        while buf.len() < total {
            if stop.is_stopped() {
                return Err(interrupted());
            }
            let Some(step) = step_until(deadline) else {
                return Err(timed_out());
            };
            self.stream.set_read_timeout(Some(step))?;
            let want = (total - buf.len()).min(chunk.len());
            match self.stream.read(&mut chunk[..want]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "connection closed early",
                    ))
                }
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
                Err(e) if is_timeout(&e) || e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    pub fn read_blocking(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.stream.set_read_timeout(None)?;
        loop {
            match self.stream.read(buf) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                other => return other,
            }
        }
    }

    pub fn shutdown(&self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

pub(crate) struct UdpSock {
    sock: UdpSocket,
}

impl UdpSock {
    pub fn bind_for_peer(peer: &SocketAddr) -> io::Result<Self> {
        let local: SocketAddr = match peer {
            SocketAddr::V4(_) => (Ipv4Addr::UNSPECIFIED, 0).into(),
            SocketAddr::V6(_) => (Ipv6Addr::UNSPECIFIED, 0).into(),
        };
        Ok(Self {
            sock: UdpSocket::bind(local)?,
        })
    }

    pub fn bind_in_range(ip: IpAddr, ports: RangeInclusive<u16>) -> io::Result<Self> {
        for port in ports {
            if let Ok(sock) = UdpSocket::bind(SocketAddr::new(ip, port)) {
                return Ok(Self { sock });
            }
        }
        Ok(Self {
            sock: UdpSocket::bind(SocketAddr::new(ip, 0))?,
        })
    }

    pub fn from_std(sock: UdpSocket) -> Self {
        Self { sock }
    }

    pub fn set_recv_buffer(&self, size: usize) -> io::Result<()> {
        socket2::SockRef::from(&self.sock).set_recv_buffer_size(size)
    }

    pub fn set_interactive_video(&self) -> io::Result<()> {
        service_type::set_interactive_video(&self.sock)
    }

    pub fn set_dont_fragment(&self, on: bool) -> io::Result<()> {
        let v6 = self.sock.local_addr()?.is_ipv6();
        dont_fragment::set(&self.sock, v6, on)
    }

    pub fn drain(&self, quiet: Duration, max: Duration) -> io::Result<usize> {
        let end = Instant::now() + max;
        let mut buf = [0u8; 2048];
        let mut n = 0;
        loop {
            let now = Instant::now();
            if now >= end {
                return Ok(n);
            }
            match self.recv_from(&mut buf, quiet.min(end - now))? {
                Some(_) => n += 1,
                None => return Ok(n),
            }
        }
    }

    pub fn recv(&self, buf: &mut [u8], timeout: Duration) -> io::Result<Option<usize>> {
        self.sock
            .set_read_timeout(Some(timeout.max(Duration::from_millis(1))))?;
        match self.sock.recv(buf) {
            Ok(n) => Ok(Some(n)),
            Err(e) if is_timeout(&e) || e.kind() == io::ErrorKind::Interrupted => Ok(None),
            Err(e) if is_icmp_error(&e) => Ok(None),
            Err(e) if is_truncated_datagram(&e) => Ok(Some(buf.len())),
            Err(e) => Err(e),
        }
    }

    pub fn set_broadcast(&self, on: bool) -> io::Result<()> {
        self.sock.set_broadcast(on)
    }

    pub fn connect(&self, addr: SocketAddr) -> io::Result<()> {
        self.sock.connect(addr)
    }

    pub fn send(&self, data: &[u8]) -> io::Result<usize> {
        self.sock.send(data)
    }

    pub fn send_to(&self, data: &[u8], addr: SocketAddr) -> io::Result<usize> {
        self.sock.send_to(data, addr)
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.sock.local_addr()
    }

    pub fn try_clone(&self) -> io::Result<Self> {
        Ok(Self {
            sock: self.sock.try_clone()?,
        })
    }

    pub fn recv_from(
        &self,
        buf: &mut [u8],
        timeout: Duration,
    ) -> io::Result<Option<(usize, SocketAddr)>> {
        self.sock
            .set_read_timeout(Some(timeout.max(Duration::from_millis(1))))?;
        match self.sock.recv_from(buf) {
            Ok(r) => Ok(Some(r)),
            Err(e) if is_timeout(&e) || e.kind() == io::ErrorKind::Interrupted => Ok(None),
            Err(e) if is_icmp_error(&e) => Ok(None),
            Err(e) if is_truncated_datagram(&e) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

mod service_type {
    use std::io;
    use std::net::UdpSocket;

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    pub fn set_interactive_video(sock: &UdpSocket) -> io::Result<()> {
        const SO_NET_SERVICE_TYPE: libc::c_int = 0x1116;
        const NET_SERVICE_TYPE_VI: libc::c_int = 3;
        super::dont_fragment::setsockopt_int(
            sock,
            libc::SOL_SOCKET,
            SO_NET_SERVICE_TYPE,
            NET_SERVICE_TYPE_VI,
        )
    }

    #[cfg(not(any(target_os = "macos", target_os = "ios")))]
    pub fn set_interactive_video(_sock: &UdpSocket) -> io::Result<()> {
        Ok(())
    }
}

#[allow(unsafe_code)]
mod dont_fragment {
    use std::io;
    use std::net::UdpSocket;

    #[cfg(unix)]
    pub(super) fn setsockopt_int(
        sock: &UdpSocket,
        level: libc::c_int,
        name: libc::c_int,
        value: libc::c_int,
    ) -> io::Result<()> {
        use std::os::fd::AsRawFd;
        let r = unsafe {
            libc::setsockopt(
                sock.as_raw_fd(),
                level,
                name,
                (&value as *const libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
        if r == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    pub fn set(sock: &UdpSocket, v6: bool, on: bool) -> io::Result<()> {
        let mode = if on {
            libc::IP_PMTUDISC_DO
        } else {
            libc::IP_PMTUDISC_DONT
        };
        if v6 {
            setsockopt_int(sock, libc::IPPROTO_IPV6, libc::IPV6_MTU_DISCOVER, mode)
        } else {
            setsockopt_int(sock, libc::IPPROTO_IP, libc::IP_MTU_DISCOVER, mode)
        }
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    pub fn set(sock: &UdpSocket, v6: bool, on: bool) -> io::Result<()> {
        let v = libc::c_int::from(on);
        if v6 {
            setsockopt_int(sock, libc::IPPROTO_IPV6, libc::IPV6_DONTFRAG, v)
        } else {
            setsockopt_int(sock, libc::IPPROTO_IP, libc::IP_DONTFRAG, v)
        }
    }

    #[cfg(windows)]
    pub fn set(sock: &UdpSocket, v6: bool, on: bool) -> io::Result<()> {
        use std::os::windows::io::AsRawSocket;
        #[link(name = "ws2_32")]
        extern "system" {
            fn setsockopt(s: usize, level: i32, name: i32, val: *const u8, len: i32) -> i32;
        }
        const IPPROTO_IP: i32 = 0;
        const IPPROTO_IPV6: i32 = 41;
        const IP_DONTFRAGMENT: i32 = 14;
        const IPV6_DONTFRAG: i32 = 14;
        let (level, name) = if v6 {
            (IPPROTO_IPV6, IPV6_DONTFRAG)
        } else {
            (IPPROTO_IP, IP_DONTFRAGMENT)
        };
        let value = u32::from(on);
        let r = unsafe {
            setsockopt(
                sock.as_raw_socket() as usize,
                level,
                name,
                (&value as *const u32).cast(),
                4,
            )
        };
        if r == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    #[cfg(not(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "ios",
        windows
    )))]
    pub fn set(_sock: &UdpSocket, _v6: bool, _on: bool) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "don't-fragment not available",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icmp_notices_of_earlier_datagrams_do_not_end_a_datagram_socket() {
        for kind in [
            io::ErrorKind::ConnectionRefused,
            io::ErrorKind::ConnectionReset,
        ] {
            assert!(is_icmp_error(&io::Error::from(kind)), "{kind:?}");
        }
        assert!(!is_icmp_error(&io::Error::from(
            io::ErrorKind::PermissionDenied
        )));
        assert!(!is_icmp_error(&io::Error::from(
            io::ErrorKind::NotConnected
        )));
        assert_eq!(
            is_icmp_error(&io::Error::from_raw_os_error(WSAENETRESET)),
            cfg!(windows)
        );
    }

    #[test]
    fn a_datagram_socket_takes_the_interactive_video_class() {
        let sock = UdpSock {
            sock: UdpSocket::bind("127.0.0.1:0").expect("socket"),
        };
        sock.set_interactive_video()
            .expect("setting the interactive-video service class must not fail");
    }
}
