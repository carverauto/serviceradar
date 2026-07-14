use std::net::IpAddr;

use crate::state::TimedPrefix;
use crate::update::Update;

pub trait StateStore: Send + Sync + 'static {
    // Get (router, peer) tuples from the state
    fn get_peers(&self) -> Vec<(IpAddr, IpAddr)>;

    // Add a peer for a given router in the state
    // If called multiple times, it must not add the peer again
    fn add_peer(&mut self, router_addr: &IpAddr, peer_addr: &IpAddr);

    // Remove a peer for a given router in the state
    // If must remove all updates associated with the router and peer
    fn remove_peer(&mut self, router_addr: &IpAddr, peer_addr: &IpAddr);

    // Get the updates for a specific router and peer from the state
    fn get_updates_by_peer(&self, router_addr: &IpAddr, peer_addr: &IpAddr) -> Vec<TimedPrefix>;

    // Update the state with a new update
    // If the update should be emited downstream, the function must return true, else false
    fn update(&mut self, router_addr: &IpAddr, peer_addr: &IpAddr, update: &Update) -> bool;
}
