use std::{convert::TryFrom, net::IpAddr, ptr};

use bitflags::bitflags;

#[cfg(target_os = "windows")]
use windows_sys::Win32::Networking::WinSock;

use crate::{
    capture::{Active, Capture},
    cstr_to_string, raw, Error,
};

bitflags! {
    /// Network device flags.
    pub struct IfFlags: u32 {
        /// Set if the device is a loopback interface
        const LOOPBACK = raw::PCAP_IF_LOOPBACK;
        /// Set if the device is up
        const UP = raw::PCAP_IF_UP;
        /// Set if the device is running
        const RUNNING = raw::PCAP_IF_RUNNING;
        /// Set if the device is a wireless interface; this includes IrDA as well as radio-based
        /// networks such as IEEE 802.15.4 and IEEE 802.11, so it doesn't just mean Wi-Fi
        const WIRELESS = raw::PCAP_IF_WIRELESS;
    }
}

impl From<u32> for IfFlags {
    fn from(flags: u32) -> Self {
        IfFlags::from_bits_truncate(flags)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// Indication of whether the adapter is connected or not; for wireless interfaces, "connected"
/// means "associated with a network".
pub enum ConnectionStatus {
    /// It's unknown whether the adapter is connected or not
    Unknown,
    /// The adapter is connected
    Connected,
    /// The adapter is disconnected
    Disconnected,
    /// The notion of "connected" and "disconnected" don't apply to this interface; for example, it
    /// doesn't apply to a loopback device
    NotApplicable,
}

impl From<u32> for ConnectionStatus {
    fn from(flags: u32) -> Self {
        match flags & raw::PCAP_IF_CONNECTION_STATUS {
            raw::PCAP_IF_CONNECTION_STATUS_UNKNOWN => ConnectionStatus::Unknown,
            raw::PCAP_IF_CONNECTION_STATUS_CONNECTED => ConnectionStatus::Connected,
            raw::PCAP_IF_CONNECTION_STATUS_DISCONNECTED => ConnectionStatus::Disconnected,
            raw::PCAP_IF_CONNECTION_STATUS_NOT_APPLICABLE => ConnectionStatus::NotApplicable,
            // DeviceFlags::CONNECTION_STATUS should be a 2-bit mask which means that the four
            // values should cover all the possibilities.
            // GRCOV_EXCL_START
            _ => unreachable!(),
            // GRCOV_EXCL_STOP
        }
    }
}

#[derive(Debug, Clone)]
pub struct DeviceFlags {
    pub if_flags: IfFlags,
    pub connection_status: ConnectionStatus,
}

impl From<u32> for DeviceFlags {
    fn from(flags: u32) -> Self {
        DeviceFlags {
            if_flags: flags.into(),
            connection_status: flags.into(),
        }
    }
}

impl DeviceFlags {
    pub fn empty() -> Self {
        DeviceFlags {
            if_flags: IfFlags::empty(),
            connection_status: ConnectionStatus::Unknown,
        }
    }

    pub fn contains(&self, if_flags: IfFlags) -> bool {
        self.if_flags.contains(if_flags)
    }

    pub fn is_loopback(&self) -> bool {
        self.contains(IfFlags::LOOPBACK)
    }

    pub fn is_up(&self) -> bool {
        self.contains(IfFlags::UP)
    }

    pub fn is_running(&self) -> bool {
        self.contains(IfFlags::RUNNING)
    }

    pub fn is_wireless(&self) -> bool {
        self.contains(IfFlags::WIRELESS)
    }
}

#[derive(Debug, Clone)]
/// A network device name and pcap's description of it.
pub struct Device {
    /// The name of the interface
    pub name: String,
    /// A textual description of the interface, if available
    pub desc: Option<String>,
    /// Addresses associated with this interface
    pub addresses: Vec<Address>,
    /// Interface flags
    pub flags: DeviceFlags,
}

impl Device {
    fn new(
        name: String,
        desc: Option<String>,
        addresses: Vec<Address>,
        flags: DeviceFlags,
    ) -> Device {
        Device {
            name,
            desc,
            addresses,
            flags,
        }
    }

    /// Opens a `Capture<Active>` on this device.
    pub fn open(self) -> Result<Capture<Active>, Error> {
        Capture::from_device(self)?.open()
    }

    /// Returns the default Device suitable for captures according to pcap_findalldevs,
    /// or an error from pcap. Note that there may be no suitable devices.
    pub fn lookup() -> Result<Option<Device>, Error> {
        unsafe {
            Device::with_all_devs(|all_devs| {
                let dev = all_devs;
                Ok(if !dev.is_null() {
                    Some(Device::try_from(&*dev)?)
                } else {
                    None
                })
            })
        }
    }

    /// Returns a vector of `Device`s known by pcap via pcap_findalldevs.
    pub fn list() -> Result<Vec<Device>, Error> {
        unsafe {
            Device::with_all_devs(|all_devs| {
                let mut devices = vec![];
                let mut dev = all_devs;
                while !dev.is_null() {
                    devices.push(Device::try_from(&*dev)?);
                    dev = (*dev).next;
                }
                Ok(devices)
            })
        }
    }

    unsafe fn with_all_devs<T, F>(func: F) -> Result<T, Error>
    where
        F: FnOnce(*mut raw::pcap_if_t) -> Result<T, Error>,
    {
        let all_devs = Error::with_errbuf(|err| {
            let mut all_devs: *mut raw::pcap_if_t = ptr::null_mut();
            if raw::pcap_findalldevs(&mut all_devs, err) != 0 {
                return Err(Error::new(err));
            }
            Ok(all_devs)
        })?;
        let result = func(all_devs);
        raw::pcap_freealldevs(all_devs);
        result
    }
}

impl From<&str> for Device {
    fn from(name: &str) -> Self {
        Device::new(name.into(), None, Vec::new(), DeviceFlags::empty())
    }
}

impl TryFrom<&raw::pcap_if_t> for Device {
    type Error = Error;

    fn try_from(dev: &raw::pcap_if_t) -> Result<Self, Error> {
        Ok(Device::new(
            unsafe { cstr_to_string(dev.name)?.ok_or(Error::InvalidString)? },
            unsafe { cstr_to_string(dev.description)? },
            unsafe { Address::new_vec(dev.addresses) },
            DeviceFlags::from(dev.flags),
        ))
    }
}

#[derive(Debug, Clone)]
/// Address information for an interface
pub struct Address {
    /// The address
    pub addr: IpAddr,
    /// Network mask for this address
    pub netmask: Option<IpAddr>,
    /// Broadcast address for this address
    pub broadcast_addr: Option<IpAddr>,
    /// P2P destination address for this address
    pub dst_addr: Option<IpAddr>,
}

impl Address {
    unsafe fn new_vec(mut ptr: *const raw::pcap_addr_t) -> Vec<Address> {
        let mut vec = Vec::new();
        while !ptr.is_null() {
            if let Some(addr) = Address::new(ptr) {
                vec.push(addr);
            }
            ptr = (*ptr).next;
        }
        vec
    }

    unsafe fn new(ptr: *const raw::pcap_addr_t) -> Option<Address> {
        Self::convert_sockaddr((*ptr).addr).map(|addr| Address {
            addr,
            netmask: Self::convert_sockaddr((*ptr).netmask),
            broadcast_addr: Self::convert_sockaddr((*ptr).broadaddr),
            dst_addr: Self::convert_sockaddr((*ptr).dstaddr),
        })
    }

    #[cfg(not(windows))]
    unsafe fn convert_sockaddr(ptr: *const libc::sockaddr) -> Option<IpAddr> {
        if ptr.is_null() {
            return None;
        }

        match (*ptr).sa_family as i32 {
            libc::AF_INET => {
                let ptr: *const libc::sockaddr_in = std::mem::transmute(ptr);
                Some(IpAddr::V4(u32::from_be((*ptr).sin_addr.s_addr).into()))
            }

            libc::AF_INET6 => {
                let ptr: *const libc::sockaddr_in6 = std::mem::transmute(ptr);
                Some(IpAddr::V6((*ptr).sin6_addr.s6_addr.into()))
            }

            _ => None,
        }
    }

    #[cfg(windows)]
    unsafe fn convert_sockaddr(ptr: *const libc::sockaddr) -> Option<IpAddr> {
        if ptr.is_null() {
            return None;
        }

        match (*ptr).sa_family as u32 {
            WinSock::AF_INET => {
                let ptr: *const WinSock::SOCKADDR_IN = std::mem::transmute(ptr);
                let addr: [u8; 4] = ((*ptr).sin_addr.S_un.S_addr).to_ne_bytes();
                Some(IpAddr::from(addr))
            }
            WinSock::AF_INET6 => {
                let ptr: *const WinSock::SOCKADDR_IN6 = std::mem::transmute(ptr);
                let addr = (*ptr).sin6_addr.u.Byte;
                Some(IpAddr::from(addr))
            }

            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::CString;

    use crate::raw::testmod::{as_pcap_t, RAWMTX};

    use super::*;

    #[cfg(not(windows))]
    enum Sockaddr {
        SockaddrIn(libc::sockaddr_in),
        SockaddrIn6(libc::sockaddr_in6),
    }

    #[cfg(windows)]
    enum Sockaddr {
        SockaddrIn(WinSock::SOCKADDR_IN),
        SockaddrIn6(WinSock::SOCKADDR_IN6),
    }

    impl Sockaddr {
        fn as_mut_ptr(&mut self) -> *mut libc::sockaddr {
            match self {
                Sockaddr::SockaddrIn(ref mut sin) => sin as *mut _ as _,
                Sockaddr::SockaddrIn6(ref mut sin6) => sin6 as *mut _ as _,
            }
        }

        fn set_family(&mut self, family: u16) {
            // Annoyingly this differs between Linux (u16) and Mac (u8).
            #[cfg(not(windows))]
            let family = family as libc::sa_family_t;

            match self {
                Sockaddr::SockaddrIn(ref mut sin) => sin.sin_family = family,
                Sockaddr::SockaddrIn6(ref mut sin6) => sin6.sin6_family = family,
            }
        }
    }

    static IF1_NAME: &str = "if1";
    static IF2_NAME: &str = "if2";
    static IF1_DESC: &str = "if1 desc";
    static IF2_DESC: &str = "if2 desc";

    fn devs() -> Vec<raw::pcap_if_t> {
        let mut devs = vec![
            raw::pcap_if_t {
                next: std::ptr::null_mut(),
                name: CString::new(IF1_NAME).unwrap().into_raw(),
                description: CString::new(IF1_DESC).unwrap().into_raw(),
                addresses: std::ptr::null_mut(),
                flags: (raw::PCAP_IF_LOOPBACK | raw::PCAP_IF_UP),
            },
            raw::pcap_if_t {
                next: std::ptr::null_mut(),
                name: CString::new(IF2_NAME).unwrap().into_raw(),
                description: CString::new(IF2_DESC).unwrap().into_raw(),
                addresses: std::ptr::null_mut(),
                flags: 0,
            },
        ];
        devs[0].next = &mut devs[1];
        devs
    }

    trait InetAddressV4 {
        fn new() -> Self;
        fn set_addr(&mut self, addr: u32);
    }

    #[cfg(not(windows))]
    impl InetAddressV4 for libc::sockaddr_in {
        fn new() -> Self {
            let mut addr: Self = unsafe { std::mem::zeroed() };
            addr.sin_family = libc::AF_INET as libc::sa_family_t;
            addr
        }

        fn set_addr(&mut self, addr: u32) {
            self.sin_addr.s_addr = addr;
        }
    }

    #[cfg(windows)]
    impl InetAddressV4 for WinSock::SOCKADDR_IN {
        fn new() -> Self {
            let mut addr: Self = unsafe { std::mem::zeroed() };
            // The cast is only necessary due to a bug in windows_sys@v0.36.1
            addr.sin_family = WinSock::AF_INET as u16;
            addr
        }

        fn set_addr(&mut self, addr: u32) {
            self.sin_addr.S_un.S_addr = addr;
        }
    }

    fn sockaddr_ipv4() -> Sockaddr {
        #[cfg(not(windows))]
        let mut addr: libc::sockaddr_in = InetAddressV4::new();
        #[cfg(windows)]
        let mut addr: WinSock::SOCKADDR_IN = InetAddressV4::new();

        addr.sin_port = 1075;
        addr.set_addr(0x0A000042_u32.to_be());

        Sockaddr::SockaddrIn(addr)
    }

    trait InetAddressV6 {
        fn new() -> Self;
        fn set_octet(&mut self, index: usize, octet: u8);
    }

    #[cfg(not(windows))]
    impl InetAddressV6 for libc::sockaddr_in6 {
        fn new() -> Self {
            let mut addr: Self = unsafe { std::mem::zeroed() };
            addr.sin6_family = libc::AF_INET6 as libc::sa_family_t;
            addr.sin6_addr.s6_addr[0] = 0xFE;
            addr.sin6_addr.s6_addr[1] = 0x80;
            addr
        }

        fn set_octet(&mut self, index: usize, octet: u8) {
            self.sin6_addr.s6_addr[index] = octet;
        }
    }

    #[cfg(windows)]
    impl InetAddressV6 for WinSock::SOCKADDR_IN6 {
        fn new() -> Self {
            let mut addr: Self = unsafe { std::mem::zeroed() };
            // The cast is only necessary due to a bug in windows_sys@v0.36.1
            addr.sin6_family = WinSock::AF_INET6 as u16;
            unsafe {
                addr.sin6_addr.u.Byte[0] = 0xFE;
                addr.sin6_addr.u.Byte[1] = 0x80;
            }
            addr
        }

        fn set_octet(&mut self, index: usize, octet: u8) {
            unsafe { self.sin6_addr.u.Byte[index] = octet };
        }
    }

    fn sockaddr_ipv6() -> Sockaddr {
        #[cfg(not(windows))]
        let mut addr: libc::sockaddr_in6 = InetAddressV6::new();
        #[cfg(windows)]
        let mut addr: WinSock::SOCKADDR_IN6 = InetAddressV6::new();

        addr.sin6_port = 1075;
        addr.set_octet(15, 0x42);

        Sockaddr::SockaddrIn6(addr)
    }

    impl From<&mut Sockaddr> for raw::pcap_addr_t {
        fn from(value: &mut Sockaddr) -> Self {
            raw::pcap_addr_t {
                next: std::ptr::null_mut(),
                addr: value.as_mut_ptr(),
                netmask: std::ptr::null_mut(),
                broadaddr: std::ptr::null_mut(),
                dstaddr: std::ptr::null_mut(),
            }
        }
    }

    #[test]
    fn test_device_flags() {
        let flags = DeviceFlags::from(
            raw::PCAP_IF_LOOPBACK | raw::PCAP_IF_UP | raw::PCAP_IF_CONNECTION_STATUS_NOT_APPLICABLE,
        );

        assert!(flags.is_loopback());
        assert!(flags.is_up());
        assert!(flags.contains(IfFlags::LOOPBACK | IfFlags::UP));

        assert!(!flags.is_running());
        assert!(!flags.is_wireless());

        assert_ne!(flags.connection_status, ConnectionStatus::Unknown);
        assert_ne!(flags.connection_status, ConnectionStatus::Connected);
        assert_ne!(flags.connection_status, ConnectionStatus::Disconnected);
        assert_eq!(flags.connection_status, ConnectionStatus::NotApplicable);

        assert!(!format!("{flags:?}").is_empty());
    }

    #[test]
    fn test_connection_status() {
        let flags = raw::PCAP_IF_CONNECTION_STATUS_UNKNOWN;
        assert_eq!(ConnectionStatus::from(flags), ConnectionStatus::Unknown);

        let flags = raw::PCAP_IF_CONNECTION_STATUS_CONNECTED;
        assert_eq!(ConnectionStatus::from(flags), ConnectionStatus::Connected);

        let flags = raw::PCAP_IF_CONNECTION_STATUS_DISCONNECTED;
        assert_eq!(
            ConnectionStatus::from(flags),
            ConnectionStatus::Disconnected
        );

        let flags = raw::PCAP_IF_CONNECTION_STATUS_NOT_APPLICABLE;
        assert_eq!(
            ConnectionStatus::from(flags),
            ConnectionStatus::NotApplicable
        );
    }

    #[test]
    fn test_into_capture() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let ctx = raw::pcap_create_context();
        ctx.expect().return_once_st(move |_, _| pcap);

        let ctx = raw::pcap_activate_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once(|_| 0);

        let ctx = raw::pcap_close_context();
        ctx.expect()
            .withf_st(move |ptr| *ptr == pcap)
            .return_once(|_| {});

        let device: Device = "device".into();
        let _capture: Capture<Active> = device.clone().open().unwrap();

        assert!(!format!("{device:?}").is_empty());
    }

    #[test]
    fn test_lookup() {
        let _m = RAWMTX.lock();

        let ctx = raw::pcap_findalldevs_context();
        ctx.expect().return_once_st(move |arg1, _| {
            unsafe { *arg1 = std::ptr::null_mut() };
            0
        });

        let ctx = raw::pcap_freealldevs_context();
        ctx.expect().return_once(move |_| {});

        let device = Device::lookup().unwrap();
        assert!(device.is_none());

        let mut devs = devs();
        let mut addrs = sockaddr_ipv4();
        let mut pcap_addr = (&mut addrs).into();
        devs[0].addresses = &mut pcap_addr;
        let devs_ptr = devs.as_mut_ptr();

        let ctx = raw::pcap_findalldevs_context();
        ctx.checkpoint();
        ctx.expect().return_once_st(move |arg1, _| {
            unsafe { *arg1 = devs_ptr };
            0
        });

        let ctx = raw::pcap_freealldevs_context();
        ctx.checkpoint();
        ctx.expect().return_once(move |_| {});

        let device = Device::lookup().unwrap().unwrap();
        assert_eq!(&device.name, IF1_NAME);
        assert_eq!(&device.desc.unwrap(), IF1_DESC);
        assert_eq!(device.addresses.len(), 1);
        assert!(device.addresses[0].addr.is_ipv4());

        let ctx = raw::pcap_findalldevs_context();
        ctx.checkpoint();
        ctx.expect().return_once_st(move |_, _| -1);

        let ctx = raw::pcap_freealldevs_context();
        ctx.checkpoint();

        let result = Device::lookup();
        assert!(result.is_err());
    }

    #[test]
    fn test_list() {
        let _m = RAWMTX.lock();

        let ctx = raw::pcap_findalldevs_context();
        ctx.expect().return_once_st(move |arg1, _| {
            unsafe { *arg1 = std::ptr::null_mut() };
            0
        });

        let ctx = raw::pcap_freealldevs_context();
        ctx.expect().return_once(move |_| {});

        let devices = Device::list().unwrap();
        assert!(devices.is_empty());

        let mut devs = devs();
        let mut ipv4s = sockaddr_ipv4();
        let mut ipv6s = sockaddr_ipv6();
        let mut pcap_addr: raw::pcap_addr_t = (&mut ipv4s).into();
        let mut pcap_addr6: raw::pcap_addr_t = (&mut ipv6s).into();
        pcap_addr.next = &mut pcap_addr6;
        devs[1].addresses = &mut pcap_addr;
        let devs_ptr = devs.as_mut_ptr();

        let ctx = raw::pcap_findalldevs_context();
        ctx.checkpoint();
        ctx.expect().return_once_st(move |arg1, _| {
            unsafe { *arg1 = devs_ptr };
            0
        });

        let ctx = raw::pcap_freealldevs_context();
        ctx.checkpoint();
        ctx.expect().return_once(move |_| {});

        let devices = Device::list().unwrap();
        assert_eq!(devices.len(), devs.len());

        assert_eq!(&devices[0].name, IF1_NAME);
        assert_eq!(devices[0].desc.as_ref().unwrap(), IF1_DESC);
        assert_eq!(devices[0].addresses.len(), 0);

        assert_eq!(&devices[1].name, IF2_NAME);
        assert_eq!(devices[1].desc.as_ref().unwrap(), IF2_DESC);
        assert_eq!(devices[1].addresses.len(), 2);
        assert!(devices[1].addresses[0].addr.is_ipv4());
        assert!(devices[1].addresses[1].addr.is_ipv6());

        let ctx = raw::pcap_findalldevs_context();
        ctx.checkpoint();
        ctx.expect().return_once_st(move |_, _| -1);

        let ctx = raw::pcap_freealldevs_context();
        ctx.checkpoint();

        let result = Device::list();
        assert!(result.is_err());
    }

    #[test]
    fn test_address_ipv4() {
        let mut addr = sockaddr_ipv4();
        let pcap_addr: raw::pcap_addr_t = (&mut addr).into();

        let address = unsafe { Address::new(&pcap_addr) }.unwrap();

        assert!(address.addr.is_ipv4());
        assert_eq!(address.addr.to_string(), "10.0.0.66");

        assert!(address.netmask.is_none());
        assert!(address.broadcast_addr.is_none());
        assert!(address.dst_addr.is_none());

        assert!(!format!("{address:?}").is_empty());
    }

    #[test]
    fn test_address_family() {
        let mut addr = sockaddr_ipv4();

        #[cfg(not(windows))]
        addr.set_family(libc::AF_IPX as u16);
        #[cfg(windows)]
        addr.set_family(WinSock::AF_IPX);

        let pcap_addr: raw::pcap_addr_t = (&mut addr).into();

        let address = unsafe { Address::new(&pcap_addr) };
        assert!(address.is_none());
    }

    #[test]
    fn test_address_ipv6() {
        let mut addr = sockaddr_ipv6();
        let pcap_addr: raw::pcap_addr_t = (&mut addr).into();

        let address = unsafe { Address::new(&pcap_addr) }.unwrap();

        assert!(address.addr.is_ipv6());
        assert_eq!(address.addr.to_string(), "fe80::42");

        assert!(address.netmask.is_none());
        assert!(address.broadcast_addr.is_none());
        assert!(address.dst_addr.is_none());

        assert!(!format!("{address:?}").is_empty());
    }
}
