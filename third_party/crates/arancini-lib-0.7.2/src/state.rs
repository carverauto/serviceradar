use anyhow::Result;
use chrono::Utc;
use core::net::IpAddr;
use metrics::{counter, gauge};
use serde::{Deserialize, Serialize};
use std::hash::{Hash, Hasher};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::sleep;
use tracing::{debug, trace};

use crate::sender::UpdateSender;
use crate::state_store::store::StateStore;
use crate::update::{map_to_ipv6, Update, UpdateAttributes, UpdateMetadata};

pub type AsyncState<T> = Arc<Mutex<State<T>>>;
pub type RouterPeerUpdate = (IpAddr, IpAddr, TimedPrefix);

pub fn new_state<T: StateStore + Send>(store: T) -> AsyncState<T> {
    Arc::new(Mutex::new(State::new(store)))
}

pub struct State<T: StateStore> {
    pub store: T,
}

impl<T: StateStore> State<T> {
    pub fn new(store: T) -> State<T> {
        State { store }
    }

    pub fn get_updates_by_peer(
        &self,
        router_addr: &IpAddr,
        peer_addr: &IpAddr,
    ) -> Result<Vec<TimedPrefix>> {
        Ok(self.store.get_updates_by_peer(router_addr, peer_addr))
    }

    pub fn add_peer(&mut self, router_addr: &IpAddr, peer_addr: &IpAddr) -> Result<()> {
        self.store.add_peer(router_addr, peer_addr);
        Ok(())
    }

    pub fn remove_peer(&mut self, router_addr: &IpAddr, peer_addr: &IpAddr) -> Result<()> {
        self.store.remove_peer(router_addr, peer_addr);
        gauge!(
            "risotto_state_updates",
            "router" => router_addr.to_string(),
            "peer" => peer_addr.to_string()
        )
        .set(0);
        Ok(())
    }

    pub fn update(
        &mut self,
        router_addr: &IpAddr,
        peer_addr: &IpAddr,
        update: &Update,
    ) -> Result<bool> {
        let emit = self.store.update(router_addr, peer_addr, update);
        if emit {
            let delta = if update.announced { 1.0 } else { -1.0 };
            gauge!(
                "risotto_state_updates",
                "router" => router_addr.to_string(),
                "peer" => peer_addr.to_string()
            )
            .increment(delta);
        }
        Ok(emit)
    }
}

#[derive(Serialize, Deserialize, Eq, Clone)]
pub struct TimedPrefix {
    pub prefix_addr: IpAddr,
    pub prefix_len: u8,
    pub is_post_policy: bool,
    pub is_adj_rib_out: bool,
    pub timestamp: i64,
}

impl PartialEq for TimedPrefix {
    fn eq(&self, other: &Self) -> bool {
        self.prefix_addr == other.prefix_addr
            && self.prefix_len == other.prefix_len
            && self.is_post_policy == other.is_post_policy
            && self.is_adj_rib_out == other.is_adj_rib_out
    }
}

impl Hash for TimedPrefix {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.prefix_addr.hash(state);
        self.prefix_len.hash(state);
        self.is_post_policy.hash(state);
        self.is_adj_rib_out.hash(state);
    }
}

pub fn synthesize_withdraw_update(prefix: &TimedPrefix, metadata: UpdateMetadata) -> Update {
    Update {
        time_received_ns: Utc::now(),
        time_bmp_header_ns: Utc::now(),
        router_addr: map_to_ipv6(metadata.router_socket.ip()),
        router_port: metadata.router_socket.port(),
        peer_addr: map_to_ipv6(metadata.peer_addr),
        peer_bgp_id: metadata.peer_bgp_id,
        peer_asn: metadata.peer_asn,
        prefix_addr: map_to_ipv6(prefix.prefix_addr),
        prefix_len: prefix.prefix_len,
        is_post_policy: prefix.is_post_policy,
        is_adj_rib_out: prefix.is_adj_rib_out,
        announced: false,
        synthetic: true,
        attrs: Arc::new(UpdateAttributes::synthetic_withdraw()),
    }
}

pub async fn peer_up_withdraws_handler<T: StateStore, S: UpdateSender>(
    state: AsyncState<T>,
    tx: S,
    metadata: UpdateMetadata,
    sleep_time: u64,
) -> Result<()> {
    let startup = chrono::Utc::now();
    sleep(Duration::from_secs(sleep_time)).await;

    debug!(
        "[{} - {} - removing updates older than {} after waited {} seconds",
        metadata.router_socket, metadata.peer_addr, startup, sleep_time
    );

    let state_lock = state.lock().await;
    let timed_prefixes = state_lock
        .store
        .get_updates_by_peer(&metadata.router_socket.ip(), &metadata.peer_addr);

    drop(state_lock);

    let mut stale_prefixes = Vec::new();
    for timed_prefix in timed_prefixes {
        if timed_prefix.timestamp < startup.timestamp_millis() {
            stale_prefixes.push(timed_prefix);
        }
    }

    debug!(
        "[{} - {} - emitting {} synthetic withdraw updates",
        metadata.router_socket,
        metadata.peer_addr,
        stale_prefixes.len()
    );

    counter!("risotto_tx_updates_total").increment(stale_prefixes.len() as u64);

    for prefix in &stale_prefixes {
        let update = synthesize_withdraw_update(prefix, metadata.clone());
        trace!("{:?}", update);
        tx.send(update).await?;
    }

    // Remove updates from state after sends complete; do not await while holding the lock.
    let mut state_lock = state.lock().await;
    for prefix in &stale_prefixes {
        let update = synthesize_withdraw_update(prefix, metadata.clone());
        state_lock
            .store
            .update(&update.router_addr, &metadata.peer_addr, &update);
    }

    Ok(())
}

/// Process pre-parsed updates through the state machine
/// This is the core processing logic used by both collectors and curators
pub async fn process_updates<T: StateStore, S: UpdateSender>(
    state: Option<AsyncState<T>>,
    tx: S,
    updates: Vec<Update>,
) -> Result<()> {
    if updates.is_empty() {
        return Ok(());
    }

    match state {
        Some(state) => {
            // Gather emit candidates while locked.
            let mut to_emit = Vec::new();
            {
                let mut state_lock = state.lock().await;
                for update in updates {
                    debug!("Processing update: {:?}", update);
                    let should_emit =
                        state_lock.update(&update.router_addr, &update.peer_addr, &update)?;
                    if should_emit {
                        to_emit.push(update);
                    }
                }
            }

            // Emit after lock release so slow channel sends cannot stall state updates.
            for update in to_emit {
                trace!("Emitting update: {:?}", update);
                tx.send(update).await?;

                counter!("risotto_tx_updates_total").increment(1);
            }
        }
        None => {
            // Stateless mode: forward all updates as-is
            for update in updates {
                trace!("Forwarding update: {:?}", update);

                counter!("risotto_tx_updates_total").increment(1);

                tx.send(update).await?;
            }
        }
    }

    Ok(())
}

/// Process a single pre-parsed update through the state machine
/// Convenience wrapper for single update processing
pub async fn process_update<T: StateStore, S: UpdateSender>(
    state: Option<AsyncState<T>>,
    tx: S,
    update: Update,
) -> Result<()> {
    process_updates(state, tx, vec![update]).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state_store::memory::MemoryStore;
    use chrono::Utc;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::{Notify, Semaphore};
    use tokio::time::{sleep, timeout, Duration};

    #[derive(Clone)]
    struct BlockingSender {
        started: Arc<Notify>,
        release: Arc<Semaphore>,
        sent: Arc<AtomicUsize>,
    }

    impl Default for BlockingSender {
        fn default() -> Self {
            Self {
                started: Arc::new(Notify::new()),
                release: Arc::new(Semaphore::new(0)),
                sent: Arc::new(AtomicUsize::new(0)),
            }
        }
    }

    impl BlockingSender {
        async fn wait_for_send_start(&self) {
            self.started.notified().await;
        }

        fn release_one_send(&self) {
            self.release.add_permits(1);
        }

        fn sent_count(&self) -> usize {
            self.sent.load(Ordering::Relaxed)
        }
    }

    impl UpdateSender for BlockingSender {
        fn send<'a>(
            &'a self,
            _update: Update,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send + 'a>> {
            Box::pin(async move {
                self.sent.fetch_add(1, Ordering::Relaxed);
                self.started.notify_waiters();
                let _permit = self
                    .release
                    .acquire()
                    .await
                    .map_err(|_| anyhow::anyhow!("blocking sender gate closed"))?;
                Ok(())
            })
        }
    }

    fn test_update(router: IpAddr, peer: IpAddr, prefix: IpAddr, announced: bool) -> Update {
        Update {
            time_received_ns: Utc::now(),
            time_bmp_header_ns: Utc::now(),
            router_addr: map_to_ipv6(router),
            router_port: 4000,
            peer_addr: map_to_ipv6(peer),
            peer_bgp_id: Ipv4Addr::new(203, 0, 113, 1),
            peer_asn: 64512,
            prefix_addr: map_to_ipv6(prefix),
            prefix_len: 24,
            is_post_policy: false,
            is_adj_rib_out: false,
            announced,
            synthetic: false,
            attrs: Arc::new(UpdateAttributes::default()),
        }
    }

    fn test_metadata(router: IpAddr, peer: IpAddr) -> UpdateMetadata {
        UpdateMetadata {
            time_bmp_header_ns: Utc::now().timestamp_millis(),
            router_socket: SocketAddr::new(router, 4000),
            peer_addr: peer,
            peer_bgp_id: Ipv4Addr::new(203, 0, 113, 1),
            peer_asn: 64512,
            is_post_policy: false,
            is_adj_rib_out: false,
        }
    }

    #[tokio::test]
    async fn process_updates_releases_state_lock_before_send_await() {
        let state = new_state(MemoryStore::new());
        let sender = BlockingSender::default();
        let update = test_update(
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 2)),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 0)),
            true,
        );

        let worker_state = state.clone();
        let worker_sender = sender.clone();
        let task = tokio::spawn(async move {
            process_updates(Some(worker_state), worker_sender, vec![update]).await
        });

        timeout(Duration::from_secs(1), sender.wait_for_send_start())
            .await
            .expect("send path should be reached");
        let lock_attempt = timeout(Duration::from_secs(1), state.lock())
            .await
            .expect("state lock attempt should not time out");
        drop(lock_attempt);

        sender.release_one_send();
        task.await
            .expect("process_updates task should complete")
            .expect("process_updates should succeed");
        assert_eq!(sender.sent_count(), 1);
    }

    #[tokio::test]
    async fn peer_up_withdraw_handler_releases_state_lock_before_send_await() {
        let router = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 20));
        let peer = IpAddr::V4(Ipv4Addr::new(198, 51, 100, 20));
        let prefix = IpAddr::V4(Ipv4Addr::new(203, 0, 113, 20));
        let state = new_state(MemoryStore::new());
        let sender = BlockingSender::default();

        {
            let mut lock = state.lock().await;
            let update = test_update(router, peer, prefix, true);
            lock.store.update(&router, &peer, &update);
        }
        // Ensure stored prefix timestamp is older than handler startup timestamp.
        sleep(Duration::from_millis(5)).await;

        let metadata = test_metadata(router, peer);
        let worker_state = state.clone();
        let worker_sender = sender.clone();
        let task = tokio::spawn(async move {
            peer_up_withdraws_handler(worker_state, worker_sender, metadata, 0).await
        });

        timeout(Duration::from_secs(1), sender.wait_for_send_start())
            .await
            .expect("stale withdraw send should begin");
        let lock_attempt = timeout(Duration::from_secs(1), state.lock())
            .await
            .expect("state lock attempt should not time out");
        drop(lock_attempt);

        sender.release_one_send();
        task.await
            .expect("peer_up_withdraws_handler task should complete")
            .expect("peer_up_withdraws_handler should succeed");
        assert_eq!(sender.sent_count(), 1);
    }
}
