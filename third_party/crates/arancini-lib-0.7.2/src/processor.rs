use anyhow::Result;
use bgpkit_parser::bmp::messages::{PeerDownNotification, PeerUpNotification, RouteMonitoring};
use bgpkit_parser::parse_bmp_msg;
use bgpkit_parser::parser::bmp::messages::BmpMessage;
use bytes::Bytes;
use metrics::{counter, gauge};
use rand::Rng;
use tracing::{error, trace};

use crate::sender::UpdateSender;
use crate::state::AsyncState;
use crate::state::{peer_up_withdraws_handler, process_updates, synthesize_withdraw_update};
use crate::state_store::store::StateStore;
use crate::update::{decode_updates, UpdateMetadata};

pub fn decode_bmp_message(bytes: &mut Bytes) -> Result<BmpMessage> {
    let message = match parse_bmp_msg(bytes) {
        Ok(message) => message,
        Err(err) => return Err(anyhow::anyhow!("failed to parse BMP message: {}", err)),
    };

    Ok(message)
}

pub async fn peer_up_notification<T: StateStore, S: UpdateSender>(
    state: Option<AsyncState<T>>,
    tx: S,
    metadata: UpdateMetadata,
    _: PeerUpNotification,
) -> Result<()> {
    if let Some(state) = state {
        {
            let mut state_lock = state.lock().await;
            state_lock
                .add_peer(&metadata.router_socket.ip(), &metadata.peer_addr)
                .unwrap();
        }

        gauge!(
            "risotto_peer_established",
            "router" => metadata.router_socket.ip().to_string(),
            "peer" => metadata.peer_addr.to_string()
        )
        .set(1);

        let spawn_state = state.clone();
        let random = {
            let mut rng = rand::rng();
            rng.random_range(-60.0..60.0) as u64
        };
        let sleep_time = 300 + random; // 5 minutes +/- 1 minute
        tokio::spawn(async move {
            if let Err(e) = peer_up_withdraws_handler(spawn_state, tx, metadata, sleep_time).await {
                error!("Error in peer_up_withdraws_handler: {}", e);
            }
        });
    }

    Ok(())
}

pub async fn route_monitoring<T: StateStore, S: UpdateSender>(
    state: Option<AsyncState<T>>,
    tx: S,
    metadata: UpdateMetadata,
    body: RouteMonitoring,
) -> Result<()> {
    // Decode BMP RouteMonitoring message into Update structs
    let updates = decode_updates(body, metadata.clone()).unwrap_or_default();

    counter!("risotto_rx_updates_total").increment(updates.len() as u64);

    // Process updates through state machine
    process_updates(state, tx, updates).await?;

    Ok(())
}

pub async fn peer_down_notification<T: StateStore, S: UpdateSender>(
    state: Option<AsyncState<T>>,
    tx: S,
    metadata: UpdateMetadata,
    _: PeerDownNotification,
) -> Result<()> {
    if let Some(state) = state {
        let mut synthetic_updates = Vec::new();
        {
            // Gather updates and mutate state while locked, but do not await in this scope.
            let mut state_lock = state.lock().await;
            let updates = state_lock
                .get_updates_by_peer(&metadata.router_socket.ip(), &metadata.peer_addr)
                .unwrap();
            for prefix in updates {
                synthetic_updates.push(synthesize_withdraw_update(&prefix, metadata.clone()));
            }

            state_lock
                .remove_peer(&metadata.router_socket.ip(), &metadata.peer_addr)
                .unwrap();
        }

        gauge!(
            "risotto_peer_established",
            "router" => metadata.router_socket.ip().to_string(),
            "peer" => metadata.peer_addr.to_string()
        )
        .set(0);

        counter!("risotto_tx_updates_total").increment(synthetic_updates.len() as u64);

        for update in synthetic_updates {
            trace!("{:?}", update);
            tx.send(update).await?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{new_state, State};
    use crate::state_store::memory::MemoryStore;
    use crate::update::{map_to_ipv6, Update, UpdateAttributes};
    use chrono::Utc;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use tokio::sync::{Notify, Semaphore};
    use tokio::time::{timeout, Duration};

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

    fn test_metadata(router: IpAddr, peer: IpAddr) -> UpdateMetadata {
        UpdateMetadata {
            time_bmp_header_ns: Utc::now().timestamp_millis(),
            router_socket: SocketAddr::new(router, 4000),
            peer_addr: peer,
            peer_bgp_id: Ipv4Addr::new(198, 51, 100, 1),
            peer_asn: 64512,
            is_post_policy: false,
            is_adj_rib_out: false,
        }
    }

    fn insert_announced_prefix(state: &mut State<MemoryStore>, metadata: &UpdateMetadata) {
        let update = Update {
            time_received_ns: Utc::now(),
            time_bmp_header_ns: Utc::now(),
            router_addr: map_to_ipv6(metadata.router_socket.ip()),
            router_port: metadata.router_socket.port(),
            peer_addr: map_to_ipv6(metadata.peer_addr),
            peer_bgp_id: metadata.peer_bgp_id,
            peer_asn: metadata.peer_asn,
            prefix_addr: map_to_ipv6(IpAddr::V4(Ipv4Addr::new(203, 0, 113, 0))),
            prefix_len: 24,
            is_post_policy: false,
            is_adj_rib_out: false,
            announced: true,
            synthetic: false,
            attrs: Arc::new(UpdateAttributes::default()),
        };
        state
            .store
            .update(&metadata.router_socket.ip(), &metadata.peer_addr, &update);
    }

    #[tokio::test]
    async fn peer_down_releases_state_lock_before_send_await() {
        let metadata = test_metadata(
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 30)),
            IpAddr::V4(Ipv4Addr::new(198, 51, 100, 30)),
        );
        let state = new_state(MemoryStore::new());
        let sender = BlockingSender::default();

        {
            let mut lock = state.lock().await;
            insert_announced_prefix(&mut lock, &metadata);
        }

        let worker_state = state.clone();
        let worker_sender = sender.clone();
        let worker_metadata = metadata.clone();
        let task = tokio::spawn(async move {
            peer_down_notification(
                Some(worker_state),
                worker_sender,
                worker_metadata,
                PeerDownNotification {
                    reason: bgpkit_parser::bmp::messages::PeerDownReason::RemoteSystemsClosedNoData,
                    data: None,
                },
            )
            .await
        });

        timeout(Duration::from_secs(1), sender.wait_for_send_start())
            .await
            .expect("synthetic withdraw send should begin");
        let lock_attempt = timeout(Duration::from_secs(1), state.lock()).await;
        assert!(
            lock_attempt.is_ok(),
            "state lock should be acquirable while peer-down send is blocked"
        );

        sender.release_one_send();
        task.await
            .expect("peer_down_notification task should complete")
            .expect("peer_down_notification should succeed");
        assert_eq!(sender.sent_count(), 1);
    }
}
