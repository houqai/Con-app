use std::net::{Ipv4Addr, UdpSocket};

#[cfg(unix)]
use std::os::fd::{FromRawFd, IntoRawFd};
#[cfg(windows)]
use std::os::windows::io::{FromRawSocket, IntoRawSocket};

#[no_mangle]
pub unsafe extern "C" fn con_test_udp_port_hold(port: *mut u16) -> isize {
    if port.is_null() {
        return -1;
    }
    let Ok(socket) = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)) else {
        return -1;
    };
    let number = match socket.local_addr() {
        Ok(address) if address.port() != 0 => address.port(),
        _ => return -1,
    };
    unsafe { port.write(number) };
    #[cfg(unix)]
    let held = socket.into_raw_fd() as isize;
    #[cfg(windows)]
    let held = socket.into_raw_socket() as isize;
    held
}

#[no_mangle]
pub unsafe extern "C" fn con_test_udp_port_release(held: isize) {
    if held < 0 {
        return;
    }
    #[cfg(unix)]
    drop(unsafe { UdpSocket::from_raw_fd(held as std::os::fd::RawFd) });
    #[cfg(windows)]
    drop(unsafe { UdpSocket::from_raw_socket(held as std::os::windows::io::RawSocket) });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn the_port_is_held_and_says_nothing() {
        let mut port = 0u16;
        let held = unsafe { con_test_udp_port_hold(&mut port) };
        assert!(held >= 0 && port != 0);
        assert!(UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port)).is_err());
        let sender = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        sender
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        sender
            .send_to(b"hello", (Ipv4Addr::LOCALHOST, port))
            .unwrap();
        let mut buffer = [0u8; 16];
        assert!(sender.recv_from(&mut buffer).is_err(), "no answer");
        unsafe { con_test_udp_port_release(held) };
        assert_eq!(unsafe { con_test_udp_port_hold(std::ptr::null_mut()) }, -1);
        unsafe { con_test_udp_port_release(-1) };
    }
}
