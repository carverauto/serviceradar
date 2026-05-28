#![no_std]
#![no_main]

use aya_ebpf::{
    macros::{kprobe, kretprobe, map, tracepoint},
    maps::RingBuf,
    programs::{ProbeContext, RetProbeContext, TracePointContext},
    EbpfContext,
};
use core::{ffi::c_void, panic::PanicInfo};

const EVENT_VERSION: u16 = 1;
const AF_INET: u16 = 2;
const AF_INET6: u16 = 10;
const IPPROTO_TCP: u16 = 6;
const IPPROTO_UDP: u16 = 17;

const EVENT_TCP_CONNECT: u16 = 1;
const EVENT_TCP_ACCEPT: u16 = 2;
const EVENT_TCP_CLOSE: u16 = 3;
const EVENT_UDP_SEND: u16 = 4;
const EVENT_UDP_RECV: u16 = 5;
const EVENT_INET_SOCK_SET_STATE: u16 = 6;

const TRACE_SKADDR_OFFSET: usize = 8;
const TRACE_OLDSTATE_OFFSET: usize = 16;
const TRACE_NEWSTATE_OFFSET: usize = 20;
const TRACE_SPORT_OFFSET: usize = 24;
const TRACE_DPORT_OFFSET: usize = 26;
const TRACE_FAMILY_OFFSET: usize = 28;
const TRACE_PROTOCOL_OFFSET: usize = 30;
const TRACE_SADDR_V4_OFFSET: usize = 32;
const TRACE_DADDR_V4_OFFSET: usize = 36;
const TRACE_SADDR_V6_OFFSET: usize = 40;
const TRACE_DADDR_V6_OFFSET: usize = 56;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct FlowTuple {
    pub family: u16,
    pub protocol: u16,
    pub source_port: u16,
    pub destination_port: u16,
    pub source_addr: [u8; 16],
    pub destination_addr: [u8; 16],
}

impl FlowTuple {
    const fn empty(protocol: u16) -> Self {
        Self {
            family: 0,
            protocol,
            source_port: 0,
            destination_port: 0,
            source_addr: [0; 16],
            destination_addr: [0; 16],
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct FlowAttributionRecord {
    pub version: u16,
    pub event_kind: u16,
    pub pid: u32,
    pub tgid: u32,
    pub uid: u32,
    pub gid: u32,
    pub socket_address: u64,
    pub old_state: i32,
    pub new_state: i32,
    pub tuple: FlowTuple,
    pub comm: [u8; 16],
}

#[map(name = "flow_events")]
static FLOW_EVENTS: RingBuf = RingBuf::pinned(1 << 20, 0);

#[kprobe(function = "tcp_connect")]
pub fn tcp_connect(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    emit_event(
        &ctx,
        EVENT_TCP_CONNECT,
        sock,
        FlowTuple::empty(IPPROTO_TCP),
        0,
        0,
    );
    0
}

#[kretprobe(function = "inet_csk_accept")]
pub fn inet_csk_accept(ctx: RetProbeContext) -> u32 {
    let Some(sock) = ctx.ret::<*const c_void>() else {
        return 0;
    };

    if sock.is_null() {
        return 0;
    }

    emit_event(
        &ctx,
        EVENT_TCP_ACCEPT,
        sock,
        FlowTuple::empty(IPPROTO_TCP),
        0,
        0,
    );
    0
}

#[kprobe(function = "tcp_close")]
pub fn tcp_close(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    emit_event(
        &ctx,
        EVENT_TCP_CLOSE,
        sock,
        FlowTuple::empty(IPPROTO_TCP),
        0,
        0,
    );
    0
}

#[kprobe(function = "udp_sendmsg")]
pub fn udp_sendmsg(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    emit_event(
        &ctx,
        EVENT_UDP_SEND,
        sock,
        FlowTuple::empty(IPPROTO_UDP),
        0,
        0,
    );
    0
}

#[kprobe(function = "udp_recvmsg")]
pub fn udp_recvmsg(ctx: ProbeContext) -> u32 {
    let Some(sock) = ctx.arg::<*const c_void>(0) else {
        return 0;
    };

    emit_event(
        &ctx,
        EVENT_UDP_RECV,
        sock,
        FlowTuple::empty(IPPROTO_UDP),
        0,
        0,
    );
    0
}

#[tracepoint(name = "inet_sock_set_state", category = "sock")]
pub fn inet_sock_set_state(ctx: TracePointContext) -> u32 {
    let Ok(sock) = trace_read::<*const c_void>(&ctx, TRACE_SKADDR_OFFSET) else {
        return 0;
    };
    let Ok(old_state) = trace_read::<i32>(&ctx, TRACE_OLDSTATE_OFFSET) else {
        return 0;
    };
    let Ok(new_state) = trace_read::<i32>(&ctx, TRACE_NEWSTATE_OFFSET) else {
        return 0;
    };
    let Ok(family) = trace_read::<u16>(&ctx, TRACE_FAMILY_OFFSET) else {
        return 0;
    };
    let Ok(protocol) = trace_read::<u16>(&ctx, TRACE_PROTOCOL_OFFSET) else {
        return 0;
    };
    let Ok(source_port) = trace_read::<u16>(&ctx, TRACE_SPORT_OFFSET) else {
        return 0;
    };
    let Ok(destination_port) = trace_read::<u16>(&ctx, TRACE_DPORT_OFFSET) else {
        return 0;
    };

    if protocol != IPPROTO_TCP {
        return 0;
    }

    let mut tuple = FlowTuple::empty(protocol);
    tuple.family = family;
    tuple.source_port = source_port;
    tuple.destination_port = destination_port;

    if family == AF_INET {
        let Ok(source_addr) = trace_read::<[u8; 4]>(&ctx, TRACE_SADDR_V4_OFFSET) else {
            return 0;
        };
        let Ok(destination_addr) = trace_read::<[u8; 4]>(&ctx, TRACE_DADDR_V4_OFFSET) else {
            return 0;
        };
        tuple.source_addr[..4].copy_from_slice(&source_addr);
        tuple.destination_addr[..4].copy_from_slice(&destination_addr);
    } else if family == AF_INET6 {
        let Ok(source_addr) = trace_read::<[u8; 16]>(&ctx, TRACE_SADDR_V6_OFFSET) else {
            return 0;
        };
        let Ok(destination_addr) = trace_read::<[u8; 16]>(&ctx, TRACE_DADDR_V6_OFFSET) else {
            return 0;
        };
        tuple.source_addr = source_addr;
        tuple.destination_addr = destination_addr;
    } else {
        return 0;
    }

    emit_event(
        &ctx,
        EVENT_INET_SOCK_SET_STATE,
        sock,
        tuple,
        old_state,
        new_state,
    );
    0
}

fn emit_event(
    ctx: &impl EbpfContext,
    event_kind: u16,
    sock: *const c_void,
    tuple: FlowTuple,
    old_state: i32,
    new_state: i32,
) {
    let record = FlowAttributionRecord {
        version: EVENT_VERSION,
        event_kind,
        pid: ctx.pid(),
        tgid: ctx.tgid(),
        uid: ctx.uid(),
        gid: ctx.gid(),
        socket_address: sock as u64,
        old_state,
        new_state,
        tuple,
        comm: ctx.command().unwrap_or([0; 16]),
    };

    let _ = FLOW_EVENTS.output(&record, 0);
}

fn trace_read<T: Copy>(ctx: &TracePointContext, offset: usize) -> Result<T, i64> {
    // SAFETY: Offsets match the kernel's sock/inet_sock_set_state tracepoint
    // format. The eBPF helper copies the value out and returns an error if the
    // tracepoint context cannot satisfy the read.
    unsafe { ctx.read_at(offset) }
}

#[panic_handler]
fn panic(_info: &PanicInfo<'_>) -> ! {
    loop {}
}
