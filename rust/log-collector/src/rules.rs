//! Keeps the collector's active ruleset in step with datasvc.
//!
//! One task per collector follows one key. Each time it connects it fetches
//! the bundle, then watches for later ones. The watch carries no replay
//! position, so whenever it ends the task reconnects and fetches again rather
//! than assuming it saw every update. Every document goes through
//! [`ActiveRules::offer`], which activates only a whole valid bundle, so a bad
//! update, a deleted key or an unreachable datasvc leaves the last good
//! ruleset in place and shows up in its status. No record waits on datasvc.

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
    let mut session = match bounded("connect to datasvc", connector.connect()).await {
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
            Ok(None) => return "datasvc ended the rule bundle watch".to_owned(),
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
                problem: Some("could not connect to datasvc: connection refused".to_owned())
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
}
