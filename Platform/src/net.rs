use std::ffi::c_char;
use std::net::Ipv4Addr;

pub(crate) const NETWORKS_MAX: usize = 32;

pub fn broadcast(address: Ipv4Addr, netmask: Ipv4Addr) -> Ipv4Addr {
    Ipv4Addr::from(u32::from(address) | !u32::from(netmask))
}

pub fn broadcast_for_prefix(address: Ipv4Addr, prefix: u8) -> Option<Ipv4Addr> {
    if prefix == 0 || prefix >= 31 {
        return None;
    }
    Some(broadcast(
        address,
        Ipv4Addr::from(u32::MAX << (32 - u32::from(prefix))),
    ))
}

fn add(found: &mut Vec<Ipv4Addr>, capacity: usize, address: Ipv4Addr) {
    if found.len() < capacity && !found.contains(&address) {
        found.push(address);
    }
}

pub fn broadcast_addresses(capacity: usize) -> Vec<Ipv4Addr> {
    let capacity = capacity.min(NETWORKS_MAX);
    let mut found = Vec::with_capacity(capacity);
    if capacity > 0 {
        collect_broadcasts(&mut found, capacity);
    }
    found
}

#[cfg(unix)]
fn collect_broadcasts(found: &mut Vec<Ipv4Addr>, capacity: usize) {
    fn ipv4(address: *const libc::sockaddr) -> Ipv4Addr {
        let address = unsafe { &*(address as *const libc::sockaddr_in) };
        Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr))
    }
    let mut interfaces: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut interfaces) } != 0 {
        return;
    }
    let mut current = interfaces;
    while !current.is_null() && found.len() < capacity {
        let interface = unsafe { &*current };
        current = interface.ifa_next;
        let flags = interface.ifa_flags as libc::c_int;
        if interface.ifa_addr.is_null() || interface.ifa_netmask.is_null() {
            continue;
        }
        if i32::from(unsafe { (*interface.ifa_addr).sa_family }) != libc::AF_INET {
            continue;
        }
        if flags & libc::IFF_LOOPBACK != 0 || flags & libc::IFF_BROADCAST == 0 {
            continue;
        }
        add(
            found,
            capacity,
            broadcast(ipv4(interface.ifa_addr), ipv4(interface.ifa_netmask)),
        );
    }
    unsafe { libc::freeifaddrs(interfaces) };
}

#[cfg(windows)]
fn collect_broadcasts(found: &mut Vec<Ipv4Addr>, capacity: usize) {
    use windows_sys::Win32::Foundation::{ERROR_BUFFER_OVERFLOW, NO_ERROR};
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER,
        GAA_FLAG_SKIP_MULTICAST, IF_TYPE_SOFTWARE_LOOPBACK, IP_ADAPTER_ADDRESSES_LH,
    };
    use windows_sys::Win32::NetworkManagement::Ndis::IfOperStatusUp;
    use windows_sys::Win32::Networking::WinSock::{AF_INET, SOCKADDR_IN};

    let mut size: u32 = 16 * 1024;
    let mut buffer: Vec<u64> = Vec::new();
    let mut result = ERROR_BUFFER_OVERFLOW;
    for _ in 0..3 {
        if result != ERROR_BUFFER_OVERFLOW {
            break;
        }
        buffer = vec![0u64; (size as usize).div_ceil(8)];
        result = unsafe {
            GetAdaptersAddresses(
                u32::from(AF_INET),
                GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
                std::ptr::null(),
                buffer.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH,
                &mut size,
            )
        };
    }
    if result != NO_ERROR {
        return;
    }
    let mut adapter = buffer.as_ptr() as *const IP_ADAPTER_ADDRESSES_LH;
    while !adapter.is_null() && found.len() < capacity {
        let record = unsafe { &*adapter };
        adapter = record.Next;
        if record.OperStatus != IfOperStatusUp || record.IfType == IF_TYPE_SOFTWARE_LOOPBACK {
            continue;
        }
        let mut unicast = record.FirstUnicastAddress;
        while !unicast.is_null() {
            let entry = unsafe { &*unicast };
            unicast = entry.Next;
            let address = entry.Address.lpSockaddr;
            if address.is_null() || unsafe { (*address).sa_family } != AF_INET {
                continue;
            }
            let ip = Ipv4Addr::from(u32::from_be(unsafe {
                (*(address as *const SOCKADDR_IN)).sin_addr.S_un.S_addr
            }));
            if let Some(broadcast) = broadcast_for_prefix(ip, entry.OnLinkPrefixLength) {
                add(found, capacity, broadcast);
            }
        }
    }
}

fn write_text(slot: &mut [u8], address: Ipv4Addr) {
    let Some(room) = slot.len().checked_sub(1) else {
        return;
    };
    let text = address.to_string();
    let length = text.len().min(room);
    slot[..length].copy_from_slice(&text.as_bytes()[..length]);
    slot[length] = 0;
}

#[no_mangle]
pub unsafe extern "C" fn con_broadcast_address_texts(
    texts: *mut c_char,
    stride: usize,
    capacity: usize,
) -> usize {
    if texts.is_null() || stride < 16 || capacity == 0 {
        return 0;
    }
    let found = broadcast_addresses(capacity);
    for (index, address) in found.iter().enumerate() {
        let slot = unsafe {
            std::slice::from_raw_parts_mut(texts.cast::<u8>().add(index * stride), stride)
        };
        write_text(slot, *address);
    }
    found.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn broadcast_sets_the_host_bits() {
        let address = Ipv4Addr::new(192, 168, 1, 23);
        assert_eq!(
            broadcast(address, Ipv4Addr::new(255, 255, 255, 0)),
            Ipv4Addr::new(192, 168, 1, 255)
        );
        assert_eq!(
            broadcast(address, Ipv4Addr::new(255, 255, 0, 0)),
            Ipv4Addr::new(192, 168, 255, 255)
        );
        assert_eq!(
            broadcast_for_prefix(Ipv4Addr::new(10, 1, 2, 3), 8),
            Some(Ipv4Addr::new(10, 255, 255, 255))
        );
        assert_eq!(
            broadcast_for_prefix(Ipv4Addr::new(10, 1, 2, 3), 30),
            Some(Ipv4Addr::new(10, 1, 2, 3))
        );
        assert_eq!(
            broadcast_for_prefix(Ipv4Addr::new(172, 16, 5, 4), 20),
            Some(Ipv4Addr::new(172, 16, 15, 255))
        );
    }

    #[test]
    fn point_to_point_links_have_no_broadcast() {
        for prefix in [0, 31, 32] {
            assert_eq!(
                broadcast_for_prefix(Ipv4Addr::new(10, 0, 0, 1), prefix),
                None,
                "/{prefix}"
            );
        }
    }

    #[test]
    fn each_address_once_and_within_capacity() {
        let mut found = Vec::new();
        add(&mut found, 2, Ipv4Addr::new(10, 0, 0, 255));
        add(&mut found, 2, Ipv4Addr::new(10, 0, 0, 255));
        add(&mut found, 2, Ipv4Addr::new(10, 0, 1, 255));
        add(&mut found, 2, Ipv4Addr::new(10, 0, 2, 255));
        assert_eq!(
            found,
            [Ipv4Addr::new(10, 0, 0, 255), Ipv4Addr::new(10, 0, 1, 255)]
        );
    }

    #[test]
    fn the_networks_found_are_not_loopback_and_each_once() {
        let found = broadcast_addresses(NETWORKS_MAX);
        for address in &found {
            assert!(!address.is_loopback(), "{address}");
            assert_eq!(found.iter().filter(|other| *other == address).count(), 1);
        }
        assert!(broadcast_addresses(0).is_empty());
        assert!(broadcast_addresses(1).len() <= 1);
    }

    #[test]
    fn text_is_terminated_and_cut_short_like_snprintf() {
        let mut slot = [0xffu8; 16];
        write_text(&mut slot, Ipv4Addr::new(255, 255, 255, 255));
        assert_eq!(&slot[..16], b"255.255.255.255\0");
        let mut short = [0xffu8; 5];
        write_text(&mut short, Ipv4Addr::new(192, 168, 1, 255));
        assert_eq!(&short, b"192.\0");
    }

    #[test]
    fn the_c_interface_writes_one_text_per_network() {
        let stride = 16;
        let mut buffer = vec![0x55u8; stride * NETWORKS_MAX];
        let count = unsafe {
            con_broadcast_address_texts(buffer.as_mut_ptr() as *mut c_char, stride, NETWORKS_MAX)
        };
        let expected = broadcast_addresses(NETWORKS_MAX);
        assert_eq!(count, expected.len());
        for (index, address) in expected.iter().enumerate() {
            let slot = &buffer[index * stride..(index + 1) * stride];
            let end = slot.iter().position(|&byte| byte == 0).expect("terminated");
            assert_eq!(
                std::str::from_utf8(&slot[..end]).unwrap(),
                address.to_string()
            );
        }
        assert_eq!(
            unsafe { con_broadcast_address_texts(std::ptr::null_mut(), 16, 4) },
            0
        );
        assert_eq!(
            unsafe { con_broadcast_address_texts(buffer.as_mut_ptr() as *mut c_char, 15, 4) },
            0
        );
        assert_eq!(
            unsafe { con_broadcast_address_texts(buffer.as_mut_ptr() as *mut c_char, 16, 0) },
            0
        );
    }
}
