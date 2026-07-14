use ahash::RandomState;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::net::IpAddr;

use crate::state::TimedPrefix;
use crate::state_store::store::StateStore;
use crate::update::Update;

#[derive(Serialize, Deserialize, Clone)]
pub struct MemoryStore {
    routers: HashMap<IpAddr, Router, RandomState>,
}

impl MemoryStore {
    pub fn new() -> MemoryStore {
        MemoryStore {
            routers: HashMap::with_hasher(RandomState::default()),
        }
    }

    fn _get_router(&mut self, router_addr: &IpAddr) -> &mut Router {
        let router = self.routers.entry(*router_addr).or_insert(Router::new());
        router
    }
}

impl Default for MemoryStore {
    fn default() -> Self {
        Self::new()
    }
}

impl StateStore for MemoryStore {
    fn add_peer(&mut self, router_addr: &IpAddr, peer_addr: &IpAddr) {
        let router = self._get_router(router_addr);
        router.add_peer(peer_addr);
    }

    fn remove_peer(&mut self, router_addr: &IpAddr, peer_addr: &IpAddr) {
        let router = self._get_router(router_addr);
        router.remove_peer(peer_addr);
    }

    fn get_peers(&self) -> Vec<(IpAddr, IpAddr)> {
        let mut peers = Vec::new();
        for (router_addr, router) in &self.routers {
            for peer_addr in router.peers.keys() {
                peers.push((*router_addr, *peer_addr));
            }
        }
        peers
    }

    fn get_updates_by_peer(&self, router_addr: &IpAddr, peer_addr: &IpAddr) -> Vec<TimedPrefix> {
        let router_binding = Router::new();
        let router = self.routers.get(router_addr).unwrap_or(&router_binding);
        let peer = match router.peers.get(peer_addr) {
            Some(peer) => peer,
            None => return Vec::new(),
        };

        peer.updates.iter().cloned().collect()
    }

    fn update(&mut self, router_addr: &IpAddr, peer_addr: &IpAddr, update: &Update) -> bool {
        let router = self._get_router(router_addr);
        router.update(peer_addr, update)
    }
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Peer {
    pub peer_addr: IpAddr,
    pub updates: HashSet<TimedPrefix, RandomState>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Router {
    peers: HashMap<IpAddr, Peer, RandomState>,
}

impl Router {
    fn new() -> Router {
        Router {
            peers: HashMap::with_hasher(RandomState::default()),
        }
    }

    fn add_peer(&mut self, peer_addr: &IpAddr) {
        self.peers.entry(*peer_addr).or_insert_with(|| Peer {
            peer_addr: *peer_addr,
            updates: HashSet::with_hasher(RandomState::default()),
        });
    }

    fn remove_peer(&mut self, peer_addr: &IpAddr) {
        self.peers.remove(peer_addr);
    }

    fn update(&mut self, peer_addr: &IpAddr, update: &Update) -> bool {
        self.add_peer(peer_addr);
        let peer = self.peers.get_mut(peer_addr).unwrap();

        let now: i64 = chrono::Utc::now().timestamp_millis();
        let timed_prefix = TimedPrefix {
            prefix_addr: update.prefix_addr,
            prefix_len: update.prefix_len,
            is_post_policy: update.is_post_policy,
            is_adj_rib_out: update.is_adj_rib_out,
            timestamp: now,
        };

        // Will emit the update only if (1) announced + not present or (2) withdrawn + present
        // Which is a XOR operation
        let emit = update.announced ^ peer.updates.contains(&timed_prefix);

        if update.announced {
            // Announced prefix: add the update or overwrite it if present
            peer.updates.replace(timed_prefix);
        } else {
            // Withdrawn prefix: remove the update if present
            peer.updates.remove(&timed_prefix);
        }
        emit
    }
}
