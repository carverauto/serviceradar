//! Keeps the collector's active ruleset in step with the store core publishes
//! it to: the NATS rule bucket ([`NatsBucket`]) or, for one more release,
//! datasvc ([`Datasvc`]).
//!
//! One task per collector follows one key. Each time it connects it fetches
//! the bundle, then watches for later ones. The watch carries no replay
//! position, so whenever it ends the task reconnects and fetches again rather
//! than assuming it saw every update. Every document goes through
//! [`ActiveRules::offer`], which activates only a whole valid bundle, so a bad
//! update, a deleted key or an unreachable store leaves the last good
//! ruleset in place and shows up in its status. No record waits on the store.

use crate::config::NatsRulesConfig;
use async_nats::ConnectOptions;
use async_nats::jetstream::{self, kv};
use futures::StreamExt;
use log::{info, warn};
use serviceradar_zen_normalize::{ActiveRules, RulesStatus};
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

/// How long one connect, fetch or watch request may take.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const FIRST_RETRY: Duration = Duration::from_secs(1);
const LONGEST_RETRY: Duration = Duration::from_secs(30);

/// Opens connections to the store the bundle is published in.
pub trait Connector: Send + Sync + 'static {
    type Session: Session;
    /// Names the store in status messages.
    fn name(&self) -> String;
    fn connect(&self) -> impl Future<Output = Result<Self::Session, String>> + Send;
}

/// One connection to the store.
pub trait Session: Send {
    /// The key's value now, or `None` when nothing is published.
    fn get(&mut self, key: &str) -> impl Future<Output = Result<Option<Vec<u8>>, String>> + Send;
    fn watch(&mut self, key: &str) -> impl Future<Output = Result<(), String>> + Send;
    /// The next value the watch delivers. Empty means the key was deleted;
    /// `None` means the watch ended.
    fn next(&mut self) -> impl Future<Output = Result<Option<Vec<u8>>, String>> + Send;
}

/// Follows the bundle for `rules` until the task is dropped.
pub async fn follow<C: Connector>(connector: C, rules: Arc<ActiveRules>) {
    let key = rules.key();
    let mut reported = rules.status();
    let mut retry = FIRST_RETRY;
    loop {
        let connected = tokio::time::Instant::now();
        let problem = session(&connector, &key, &rules, &mut reported).await;
        rules.report_unavailable(problem);
        report(&rules, &mut reported);
        // Only a connection that lasted counts as recovered. One that fetched
        // and then lost its watch at once would otherwise be retried every
        // second for as long as the watch keeps failing.
        if connected.elapsed() >= LONGEST_RETRY {
            retry = FIRST_RETRY;
        }
        tokio::time::sleep(retry).await;
        retry = (retry * 2).min(LONGEST_RETRY);
    }
}

/// Runs one connection until it fails or its watch ends, and says why.
async fn session<C: Connector>(
    connector: &C,
    key: &str,
    rules: &ActiveRules,
    reported: &mut RulesStatus,
) -> String {
    let store = connector.name();
    let mut session = match bounded(&format!("connect to {store}"), connector.connect()).await {
        Ok(session) => session,
        Err(problem) => return problem,
    };
    match bounded("fetch the rule bundle", session.get(key)).await {
        Ok(value) => offer(rules, key, value.as_deref().unwrap_or_default()),
        Err(problem) => return problem,
    }
    report(rules, reported);
    if let Err(problem) = bounded("watch the rule bundle", session.watch(key)).await {
        return problem;
    }
    loop {
        match session.next().await {
            Ok(Some(value)) => offer(rules, key, &value),
            Ok(None) => return format!("{store} ended the rule bundle watch"),
            Err(problem) => return format!("rule bundle watch failed: {problem}"),
        }
        report(rules, reported);
    }
}

async fn bounded<T>(
    action: &str,
    request: impl Future<Output = Result<T, String>>,
) -> Result<T, String> {
    match tokio::time::timeout(REQUEST_TIMEOUT, request).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(problem)) => Err(format!("could not {action}: {problem}")),
        Err(_) => Err(format!("could not {action} within {REQUEST_TIMEOUT:?}")),
    }
}

fn offer(rules: &ActiveRules, key: &str, document: &[u8]) {
    if document.is_empty() {
        rules.report_unavailable(format!("no rule bundle is published at {key}"));
    } else {
        // A rejected document is kept in the status, which `report` logs.
        let _ = rules.offer(document);
    }
}

/// Logs the ruleset status when it changes.
fn report(rules: &ActiveRules, reported: &mut RulesStatus) {
    let status = rules.status();
    if status == *reported {
        return;
    }
    match &status {
        RulesStatus::Current { digest } => info!("Zen ruleset {digest} is active"),
        RulesStatus::Stale { digest, problem } => {
            warn!("Zen ruleset {digest} stays active and may be stale: {problem}")
        }
        RulesStatus::Missing { problem } => warn!(
            "no Zen ruleset is active: {}",
            problem.as_deref().unwrap_or("none has been fetched")
        ),
    }
    *reported = status;
}

/// The datasvc connection the collector reads its bundle over.
pub struct Datasvc(pub kvutil::KvEndpoint);

pub struct DatasvcSession {
    client: kvutil::KvClient,
    watch: Option<kvutil::KvWatch>,
}

impl Connector for Datasvc {
    type Session = DatasvcSession;

    fn name(&self) -> String {
        "datasvc".to_owned()
    }

    async fn connect(&self) -> Result<DatasvcSession, String> {
        let client = kvutil::KvClient::connect(&self.0)
            .await
            .map_err(|error| error.to_string())?;
        Ok(DatasvcSession {
            client,
            watch: None,
        })
    }
}

impl Session for DatasvcSession {
    async fn get(&mut self, key: &str) -> Result<Option<Vec<u8>>, String> {
        self.client
            .get(key)
            .await
            .map_err(|error| error.to_string())
    }

    async fn watch(&mut self, key: &str) -> Result<(), String> {
        let watch = self.client.watch(key).await;
        self.watch = Some(watch.map_err(|error| error.to_string())?);
        Ok(())
    }

    async fn next(&mut self) -> Result<Option<Vec<u8>>, String> {
        match &mut self.watch {
            Some(watch) => watch.next().await.map_err(|error| error.to_string()),
            None => Ok(None),
        }
    }
}

/// The NATS key-value bucket core publishes rule bundles to.
pub struct NatsBucket(pub NatsRulesConfig);

pub struct NatsSession {
    store: kv::Store,
    watch: Option<kv::Watch>,
}

impl Connector for NatsBucket {
    type Session = NatsSession;

    fn name(&self) -> String {
        format!("NATS bucket {}", self.0.bucket)
    }

    async fn connect(&self) -> Result<NatsSession, String> {
        let config = &self.0;
        // One automatic reconnect. When it fails the client closes, which ends
        // the watch, so `follow` reports the ruleset stale and reconnects with
        // its own backoff; a client left reconnecting on its own would keep a
        // dead watch open, and a dropped one would never stop.
        let mut options = ConnectOptions::new().max_reconnects(1);
        if let Some(creds_file) = &config.creds_file {
            options = options
                .credentials_file(creds_file)
                .await
                .map_err(|error| format!("could not read {creds_file}: {error}"))?;
        }
        if let Some(tls) = &config.tls {
            if let Some(ca_file) = &tls.ca_file {
                options = options.add_root_certificates(ca_file.into());
            }
            options = options
                .add_client_certificate(tls.cert_file.clone().into(), tls.key_file.clone().into());
        }
        let client = options
            .connect(config.url.as_str())
            .await
            .map_err(|error| error.to_string())?;
        let context = match &config.domain {
            Some(domain) => jetstream::with_domain(client, domain),
            None => jetstream::new(client),
        };
        let store = context
            .get_key_value(&config.bucket)
            .await
            .map_err(|error| error.to_string())?;
        Ok(NatsSession { store, watch: None })
    }
}

impl Session for NatsSession {
    async fn get(&mut self, key: &str) -> Result<Option<Vec<u8>>, String> {
        let value = self
            .store
            .get(key)
            .await
            .map_err(|error| error.to_string())?;
        Ok(value.map(|value| value.to_vec()))
    }

    /// Starts with the key's latest entry, so nothing published between the
    /// fetch and the watch is missed.
    async fn watch(&mut self, key: &str) -> Result<(), String> {
        let watch = self.store.watch_with_history(key).await;
        self.watch = Some(watch.map_err(|error| error.to_string())?);
        Ok(())
    }

    async fn next(&mut self) -> Result<Option<Vec<u8>>, String> {
        let Some(watch) = &mut self.watch else {
            return Ok(None);
        };
        match watch.next().await {
            None => Ok(None),
            Some(Err(error)) => Err(error.to_string()),
            Some(Ok(entry)) => Ok(Some(match entry.operation {
                kv::Operation::Put => entry.value.to_vec(),
                kv::Operation::Delete | kv::Operation::Purge => Vec::new(),
            })),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tokio::sync::mpsc;
    use tokio::time::Instant;

    // The bundles and digests `rust/zen-normalize` and core's publisher both
    // assert for this content.
    const TWO_RULES: &str =
        "sha256:578cb4621ff7758cbcec93bfcb0208ddce0a52cb01011eb5b28f15332d4d70b4";
    const NO_RULES: &str =
        "sha256:11f468c88fd9041ba1b94ae65bbb4b04cf2d8f690b8d1d62f99f4689ccfc961b";
    const KEY: &str = "zen/rulesets/events/logs.syslog.json";

    fn bundle(rules: &str, digest: &str) -> Vec<u8> {
        format!(
            r#"{{"schema":"serviceradar.zen.ruleset.v1","stream_name":"events","subject":"logs.syslog","rules":[{rules}],"digest":"{digest}"}}"#
        )
        .into_bytes()
    }

    fn two_rules() -> Vec<u8> {
        bundle(
            r#"{"key":"first","jdm":"{\"nodes\":[],\"edges\":[]}"},{"key":"second","jdm":"{\"edges\":[],\"nodes\":[]}"}"#,
            TWO_RULES,
        )
    }

    fn no_rules() -> Vec<u8> {
        bundle("", NO_RULES)
    }

    /// A store whose stored value and watch the test controls. A new watch
    /// delivers nothing by itself, so only a fetch can show a value that
    /// changed while no watch was open.
    #[derive(Default)]
    struct Store {
        stored: Option<Vec<u8>>,
        refuse_connections: usize,
        end_watches_at_once: bool,
        connects: Vec<Instant>,
        fetched_keys: Vec<String>,
        watch: Option<mpsc::UnboundedSender<Vec<u8>>>,
    }

    #[derive(Clone, Default)]
    struct Fake(Arc<Mutex<Store>>);

    impl Fake {
        fn store(&self) -> std::sync::MutexGuard<'_, Store> {
            self.0.lock().unwrap()
        }

        /// Delivers a value on the open watch.
        fn update(&self, value: Vec<u8>) {
            let store = self.store();
            store.watch.as_ref().unwrap().send(value).unwrap();
        }
    }

    struct FakeSession {
        store: Fake,
        updates: Option<mpsc::UnboundedReceiver<Vec<u8>>>,
    }

    impl Connector for Fake {
        type Session = FakeSession;

        fn name(&self) -> String {
            "the test store".to_owned()
        }

        async fn connect(&self) -> Result<FakeSession, String> {
            let mut store = self.store();
            store.connects.push(Instant::now());
            if store.refuse_connections > 0 {
                store.refuse_connections -= 1;
                return Err("connection refused".to_owned());
            }
            Ok(FakeSession {
                store: self.clone(),
                updates: None,
            })
        }
    }

    impl Session for FakeSession {
        async fn get(&mut self, key: &str) -> Result<Option<Vec<u8>>, String> {
            let mut store = self.store.store();
            store.fetched_keys.push(key.to_owned());
            Ok(store.stored.clone())
        }

        async fn watch(&mut self, _key: &str) -> Result<(), String> {
            let (sender, receiver) = mpsc::unbounded_channel();
            let mut store = self.store.store();
            store.watch = (!store.end_watches_at_once).then_some(sender);
            self.updates = Some(receiver);
            Ok(())
        }

        async fn next(&mut self) -> Result<Option<Vec<u8>>, String> {
            Ok(self.updates.as_mut().unwrap().recv().await)
        }
    }

    fn start(store: &Fake) -> Arc<ActiveRules> {
        let rules = Arc::new(ActiveRules::new("events", "logs.syslog"));
        tokio::spawn(follow(store.clone(), rules.clone()));
        rules
    }

    /// Waits, on the paused clock, until the status satisfies `wanted`.
    async fn status(rules: &ActiveRules, wanted: impl Fn(&RulesStatus) -> bool) -> RulesStatus {
        let reached = async {
            loop {
                let status = rules.status();
                if wanted(&status) {
                    return status;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        };
        match tokio::time::timeout(Duration::from_secs(600), reached).await {
            Ok(status) => status,
            Err(_) => panic!("status stayed {:?}", rules.status()),
        }
    }

    fn current(digest: &str) -> RulesStatus {
        RulesStatus::Current {
            digest: digest.to_owned(),
        }
    }

    async fn watching(store: &Fake) {
        while store.store().watch.is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_starting_collector_activates_the_published_bundle() {
        let store = Fake::default();
        store.store().stored = Some(two_rules());

        let rules = start(&store);

        status(&rules, |status| *status == current(TWO_RULES)).await;
        assert_eq!(store.store().fetched_keys, [KEY]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_collector_with_nothing_published_waits_for_the_first_bundle() {
        let store = Fake::default();
        let rules = start(&store);

        let missing = status(&rules, |status| {
            matches!(status, RulesStatus::Missing { problem: Some(_) })
        })
        .await;
        assert_eq!(
            missing,
            RulesStatus::Missing {
                problem: Some(format!("no rule bundle is published at {KEY}"))
            }
        );
        assert!(rules.current().is_none());

        watching(&store).await;
        store.update(no_rules());
        status(&rules, |status| *status == current(NO_RULES)).await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_watched_update_replaces_the_ruleset_and_a_bad_one_does_not() {
        let store = Fake::default();
        store.store().stored = Some(no_rules());
        let rules = start(&store);
        status(&rules, |status| *status == current(NO_RULES)).await;
        watching(&store).await;

        store.update(two_rules());
        status(&rules, |status| *status == current(TWO_RULES)).await;

        // Declares the two-rule digest over different content.
        store.update(bundle("", TWO_RULES));
        let stale = status(&rules, |status| matches!(status, RulesStatus::Stale { .. })).await;
        assert!(matches!(stale, RulesStatus::Stale { digest, .. } if digest == TWO_RULES));
        assert_eq!(rules.current().unwrap().digest, TWO_RULES);
    }

    #[tokio::test(start_paused = true)]
    async fn a_deleted_key_keeps_the_last_ruleset_and_reports_it_stale() {
        let store = Fake::default();
        store.store().stored = Some(two_rules());
        let rules = start(&store);
        status(&rules, |status| *status == current(TWO_RULES)).await;
        watching(&store).await;

        store.update(Vec::new());

        let stale = status(&rules, |status| matches!(status, RulesStatus::Stale { .. })).await;
        assert_eq!(
            stale,
            RulesStatus::Stale {
                digest: TWO_RULES.to_owned(),
                problem: format!("no rule bundle is published at {KEY}"),
            }
        );
        assert_eq!(rules.current().unwrap().digest, TWO_RULES);
    }

    #[tokio::test(start_paused = true)]
    async fn a_bundle_published_while_the_watch_was_down_is_fetched_on_reconnect() {
        let store = Fake::default();
        store.store().stored = Some(two_rules());
        let rules = start(&store);
        status(&rules, |status| *status == current(TWO_RULES)).await;
        watching(&store).await;

        // The watch ends, and the bundle changes before another one opens.
        {
            let mut store = store.store();
            store.stored = Some(no_rules());
            store.watch = None;
        }

        status(&rules, |status| *status == current(NO_RULES)).await;
        assert_eq!(store.store().connects.len(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn a_store_whose_watch_keeps_ending_is_not_retried_every_second() {
        let store = Fake::default();
        {
            let mut store = store.store();
            store.stored = Some(two_rules());
            store.end_watches_at_once = true;
        }
        let rules = start(&store);

        while store.store().connects.len() < 8 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let connects = store.store().connects.clone();
        let waits: Vec<u64> = connects
            .windows(2)
            .map(|pair| (pair[1] - pair[0]).as_secs())
            .collect();
        assert_eq!(waits, [1, 2, 4, 8, 16, 30, 30]);
        assert_eq!(rules.current().unwrap().digest, TWO_RULES);
    }

    #[tokio::test(start_paused = true)]
    async fn a_connection_that_lasted_resets_the_retry_interval() {
        let store = Fake::default();
        {
            let mut store = store.store();
            store.stored = Some(two_rules());
            // Five refusals grow the next wait to the 30 second ceiling.
            store.refuse_connections = 5;
        }
        let rules = start(&store);
        status(&rules, |status| *status == current(TWO_RULES)).await;
        watching(&store).await;

        // The watch stays healthy for a minute, then ends.
        tokio::time::sleep(Duration::from_secs(60)).await;
        let ended = Instant::now();
        store.store().watch = None;

        while store.store().connects.len() < 7 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let reconnected = store.store().connects[6];
        assert_eq!((reconnected - ended).as_secs(), 1);
        assert_eq!(rules.current().unwrap().digest, TWO_RULES);
    }

    #[tokio::test(start_paused = true)]
    async fn an_unreachable_store_is_retried_at_a_bounded_growing_interval() {
        let store = Fake::default();
        {
            let mut store = store.store();
            store.stored = Some(two_rules());
            store.refuse_connections = 7;
        }
        let rules = start(&store);

        let missing = status(&rules, |status| {
            matches!(status, RulesStatus::Missing { problem: Some(_) })
        })
        .await;
        assert_eq!(
            missing,
            RulesStatus::Missing {
                problem: Some("could not connect to the test store: connection refused".to_owned())
            }
        );

        status(&rules, |status| *status == current(TWO_RULES)).await;
        let connects = store.store().connects.clone();
        let waits: Vec<u64> = connects
            .windows(2)
            .map(|pair| (pair[1] - pair[0]).as_secs())
            .collect();
        assert_eq!(waits, [1, 2, 4, 8, 16, 30, 30]);
    }

    /// [`NatsBucket`] against a real nats-server: the binary Bazel stages in
    /// `NATS_SERVER_BIN`, or `nats-server` on `PATH` under Cargo.
    mod nats {
        use super::*;
        use crate::config::NatsRulesConfig;
        use std::net::TcpListener;
        use std::path::{Path, PathBuf};
        use std::process::{Child, Command, Stdio};

        const BUCKET: &str = "serviceradar-zen-rules";

        struct Broker {
            process: Child,
            port: u16,
            config: PathBuf,
        }

        impl Broker {
            /// Starts a JetStream server storing under `dir`, in `domain`.
            fn start(dir: &Path, port: u16, domain: &str) -> Self {
                let config = dir.join("nats.conf");
                std::fs::write(
                    &config,
                    format!(
                        "listen: 127.0.0.1:{port}\njetstream {{ store_dir: {:?}, domain: {domain:?} }}\n",
                        dir.join("store")
                    ),
                )
                .unwrap();
                Self::spawn(config, port)
            }

            fn spawn(config: PathBuf, port: u16) -> Self {
                let executable =
                    std::env::var("NATS_SERVER_BIN").unwrap_or_else(|_| "nats-server".into());
                let process = Command::new(executable)
                    .arg("-c")
                    .arg(&config)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .expect("start the NATS test broker (Cargo needs nats-server on PATH)");
                Self {
                    process,
                    port,
                    config,
                }
            }

            fn url(&self) -> String {
                format!("nats://127.0.0.1:{}", self.port)
            }

            /// The bucket as an administrator sees it, once the server answers.
            async fn bucket(&mut self, domain: &str) -> kv::Store {
                let deadline = Instant::now() + Duration::from_secs(10);
                let client = loop {
                    if let Some(status) = self.process.try_wait().unwrap() {
                        panic!("NATS test broker exited: {status}");
                    }
                    match async_nats::connect(self.url()).await {
                        Ok(client) => break client,
                        Err(_) if Instant::now() < deadline => {
                            tokio::time::sleep(Duration::from_millis(20)).await
                        }
                        Err(error) => panic!("NATS test broker did not start: {error}"),
                    }
                };
                jetstream::with_domain(client, domain)
                    .create_key_value(kv::Config {
                        bucket: BUCKET.to_owned(),
                        history: 1,
                        max_bytes: 1 << 20,
                        ..Default::default()
                    })
                    .await
                    .unwrap()
            }

            fn stop(&mut self) {
                let _ = self.process.kill();
                let _ = self.process.wait();
            }

            fn restart(&mut self) {
                self.stop();
                *self = Self::spawn(self.config.clone(), self.port);
            }
        }

        impl Drop for Broker {
            fn drop(&mut self) {
                self.stop();
            }
        }

        /// [`status`] on the real clock, failing after 30 seconds.
        async fn settled(
            rules: &ActiveRules,
            wanted: impl Fn(&RulesStatus) -> bool,
        ) -> RulesStatus {
            match tokio::time::timeout(Duration::from_secs(30), status(rules, wanted)).await {
                Ok(status) => status,
                Err(_) => panic!("status stayed {:?}", rules.status()),
            }
        }

        fn free_port() -> u16 {
            TcpListener::bind("127.0.0.1:0")
                .unwrap()
                .local_addr()
                .unwrap()
                .port()
        }

        fn follow_bucket(url: String, domain: &str) -> Arc<ActiveRules> {
            let rules = Arc::new(ActiveRules::new("events", "logs.syslog"));
            let bucket = NatsBucket(NatsRulesConfig {
                url,
                domain: Some(domain.to_owned()),
                bucket: BUCKET.to_owned(),
                creds_file: None,
                tls: None,
            });
            tokio::spawn(follow(bucket, rules.clone()));
            rules
        }

        #[tokio::test]
        async fn the_bucket_is_fetched_then_watched_through_its_jetstream_domain() {
            let dir = tempfile::tempdir().unwrap();
            let mut broker = Broker::start(dir.path(), free_port(), "edge_site01");
            let bucket = broker.bucket("edge_site01").await;
            bucket.put(KEY, two_rules().into()).await.unwrap();

            let rules = follow_bucket(broker.url(), "edge_site01");
            settled(&rules, |status| *status == current(TWO_RULES)).await;

            bucket.put(KEY, no_rules().into()).await.unwrap();
            settled(&rules, |status| *status == current(NO_RULES)).await;

            bucket.delete(KEY).await.unwrap();
            let stale = settled(&rules, |status| matches!(status, RulesStatus::Stale { .. })).await;
            assert_eq!(
                stale,
                RulesStatus::Stale {
                    digest: NO_RULES.to_owned(),
                    problem: format!("no rule bundle is published at {KEY}"),
                }
            );

            // A domain the bucket is not in is not read.
            let elsewhere = follow_bucket(broker.url(), "edge_site02");
            let missing = settled(&elsewhere, |status| {
                matches!(status, RulesStatus::Missing { problem: Some(_) })
            })
            .await;
            assert!(
                matches!(&missing, RulesStatus::Missing { problem: Some(problem) }
                    if problem.starts_with("could not connect to NATS bucket serviceradar-zen-rules")),
                "{missing:?}"
            );
        }

        #[tokio::test]
        async fn a_lost_connection_leaves_the_ruleset_stale_until_the_bucket_is_back() {
            let dir = tempfile::tempdir().unwrap();
            let mut broker = Broker::start(dir.path(), free_port(), "hub");
            broker
                .bucket("hub")
                .await
                .put(KEY, two_rules().into())
                .await
                .unwrap();
            let rules = follow_bucket(broker.url(), "hub");
            settled(&rules, |status| *status == current(TWO_RULES)).await;

            broker.stop();
            let stale = settled(&rules, |status| matches!(status, RulesStatus::Stale { .. })).await;
            assert!(matches!(stale, RulesStatus::Stale { digest, .. } if digest == TWO_RULES));

            broker.restart();
            broker
                .bucket("hub")
                .await
                .put(KEY, no_rules().into())
                .await
                .unwrap();
            settled(&rules, |status| *status == current(NO_RULES)).await;
        }
    }
}
