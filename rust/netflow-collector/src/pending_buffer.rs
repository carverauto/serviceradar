use std::collections::{HashMap, VecDeque};
use std::net::SocketAddr;
use std::time::{Duration, Instant};

pub struct PendingPacket {
    pub data: Vec<u8>,
    pub receive_time_ns: u64,
    pub received_at: Instant,
}

pub struct PendingPacketBuffer {
    buffer: HashMap<SocketAddr, VecDeque<PendingPacket>>,
    ttl: Duration,
    max_packets_per_source: usize,
}

impl PendingPacketBuffer {
    pub fn new(ttl: Duration, max_per_source: usize) -> Self {
        Self {
            buffer: HashMap::new(),
            ttl,
            max_packets_per_source: max_per_source,
        }
    }

    pub fn add(&mut self, source: SocketAddr, data: Vec<u8>, receive_time_ns: u64) {
        let queue = self.buffer.entry(source).or_default();

        // Evict oldest if at capacity
        while queue.len() >= self.max_packets_per_source {
            queue.pop_front();
        }

        queue.push_back(PendingPacket {
            data,
            receive_time_ns,
            received_at: Instant::now(),
        });
    }

    pub fn take_all(&mut self, source: &SocketAddr) -> Vec<PendingPacket> {
        self.buffer
            .remove(source)
            .map(Vec::from)
            .unwrap_or_default()
    }

    pub fn has_pending(&self, source: &SocketAddr) -> bool {
        self.buffer
            .get(source)
            .is_some_and(|q| !q.is_empty())
    }

    pub fn is_expired(&self, packet: &PendingPacket) -> bool {
        packet.received_at.elapsed() >= self.ttl
    }

    pub fn re_add(&mut self, source: SocketAddr, packet: PendingPacket) {
        let queue = self.buffer.entry(source).or_default();
        while queue.len() >= self.max_packets_per_source {
            queue.pop_front();
        }
        queue.push_back(packet);
    }

    pub fn sweep_expired(&mut self) {
        let ttl = self.ttl;
        self.buffer.retain(|_, queue| {
            queue.retain(|pkt| pkt.received_at.elapsed() < ttl);
            !queue.is_empty()
        });
    }

    pub fn stats(&self) -> (usize, usize) {
        let total_packets: usize = self.buffer.values().map(|q| q.len()).sum();
        let total_sources = self.buffer.len();
        (total_packets, total_sources)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};
    use std::thread::sleep;

    fn test_addr(port: u16) -> SocketAddr {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1)), port)
    }

    #[test]
    fn test_add_and_take_all() {
        let mut buf = PendingPacketBuffer::new(Duration::from_secs(60), 10);
        let addr = test_addr(9000);

        buf.add(addr, vec![1, 2, 3], 1000);
        buf.add(addr, vec![4, 5, 6], 2000);

        assert!(buf.has_pending(&addr));

        let packets = buf.take_all(&addr);
        assert_eq!(packets.len(), 2);
        assert_eq!(packets[0].data, vec![1, 2, 3]);
        assert_eq!(packets[1].data, vec![4, 5, 6]);
        assert!(!buf.has_pending(&addr));
    }

    #[test]
    fn test_eviction_at_capacity() {
        let mut buf = PendingPacketBuffer::new(Duration::from_secs(60), 2);
        let addr = test_addr(9000);

        buf.add(addr, vec![1], 1000);
        buf.add(addr, vec![2], 2000);
        buf.add(addr, vec![3], 3000);

        let packets = buf.take_all(&addr);
        assert_eq!(packets.len(), 2);
        assert_eq!(packets[0].data, vec![2]);
        assert_eq!(packets[1].data, vec![3]);
    }

    #[test]
    fn test_sweep_expired() {
        let mut buf = PendingPacketBuffer::new(Duration::from_millis(50), 10);
        let addr = test_addr(9000);

        buf.add(addr, vec![1], 1000);
        sleep(Duration::from_millis(100));

        buf.sweep_expired();
        assert!(!buf.has_pending(&addr));
        let (packets, sources) = buf.stats();
        assert_eq!(packets, 0);
        assert_eq!(sources, 0);
    }

    #[test]
    fn test_stats() {
        let mut buf = PendingPacketBuffer::new(Duration::from_secs(60), 10);
        let addr1 = test_addr(9000);
        let addr2 = test_addr(9001);

        buf.add(addr1, vec![1], 1000);
        buf.add(addr1, vec![2], 2000);
        buf.add(addr2, vec![3], 3000);

        let (packets, sources) = buf.stats();
        assert_eq!(packets, 3);
        assert_eq!(sources, 2);
    }

    #[test]
    fn test_take_all_empty() {
        let mut buf = PendingPacketBuffer::new(Duration::from_secs(60), 10);
        let addr = test_addr(9000);

        let packets = buf.take_all(&addr);
        assert!(packets.is_empty());
        assert!(!buf.has_pending(&addr));
    }
}
