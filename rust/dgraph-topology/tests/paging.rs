//! Invented protocol fixtures, built without deployment captures. This server
//! speaks the real gRPC protocol so tonic's receive limit remains in the path.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use dgraph_topology::{EdgeKind, EdgeWrite, TopologyClient};
use proto_dgraph::api;
use proto_dgraph::api::dgraph_server::{Dgraph, DgraphServer};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio_stream::wrappers::TcpListenerStream;
use tonic::{Request, Response, Status};

const RECEIVE_LIMIT: usize = 4 * 1024 * 1024;
const SNAPSHOT: u64 = 73;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Block {
    Nodes,
    Edges,
}

#[derive(Clone, Copy, Debug)]
enum Fault {
    MissingBlock,
    InvalidUid,
    RepeatedUid,
    MissingUid,
    WrongFieldType,
    MissingTimestamp,
    ZeroTimestamp,
    ChangedTimestamp,
    AbortedSnapshot,
    ServerFailure,
    OversizedRow,
}

#[derive(Debug)]
struct PageCall {
    block: Block,
    first: usize,
    after: u64,
    start_ts: u64,
    bytes: usize,
}

#[derive(Default)]
struct Fixture {
    nodes: Vec<Value>,
    edges: Vec<Value>,
    fault: Option<Fault>,
    calls: Vec<PageCall>,
    queries: Vec<String>,
    mutations: Vec<Value>,
    mutation_contracts: Vec<(String, String, Value)>,
    mutation_response: Value,
    snapshot_established: bool,
    faults_delivered: usize,
    interfaces: Vec<Value>,
    /// Fail every interface lookup after this many have been answered.
    interface_outage_after: Option<usize>,
    /// (keys requested, response bytes) per interface lookup.
    interface_calls: Vec<(usize, usize)>,
    violations: Vec<String>,
    /// (first, after, response bytes) per prune transaction.
    age_calls: Vec<(usize, u64, usize)>,
    neighborhood: Option<Neighborhood>,
    neighborhood_calls: Vec<NeighborhoodCall>,
}

/// One device's stored neighbourhood, in the row shapes its paged reads select.
#[derive(Default)]
struct Neighborhood {
    device: Value,
    interfaces: Vec<Value>,
    outbound: Vec<Value>,
    inbound: Vec<Value>,
    /// Every stored Interface of every peer, each naming its owner's UID.
    peer_interfaces: Vec<Value>,
}

#[derive(Debug)]
struct NeighborhoodCall {
    block: String,
    first: usize,
    rows: usize,
    bytes: usize,
}

impl Fixture {
    fn mutation_response(&self) -> Value {
        if self.mutation_response.is_null() {
            json!({"src":[{"uid":"0x1"}],"dst":[{"uid":"0x2"}]})
        } else {
            self.mutation_response.clone()
        }
    }

    fn query(&mut self, request: api::Request) -> Result<api::Response, Status> {
        if !request.mutations.is_empty() {
            if request.read_only || request.mutations.len() != 1 {
                return self.violation("edge upsert must use one write mutation");
            }
            if request.query.contains("aged as uid") {
                return self.age(&request);
            }
            let mutation = &request.mutations[0];
            self.mutations.push(
                serde_json::from_slice(&mutation.set_json)
                    .map_err(|err| Status::invalid_argument(err.to_string()))?,
            );
            self.mutation_contracts.push((
                request.query,
                mutation.cond.clone(),
                if mutation.delete_json.is_empty() {
                    json!({})
                } else {
                    serde_json::from_slice(&mutation.delete_json)
                        .map_err(|err| Status::invalid_argument(err.to_string()))?
                },
            ));
            return Ok(api::Response {
                json: serde_json::to_vec(&self.mutation_response()).expect("mutation response"),
                txn: Some(api::TxnContext::default()),
                ..Default::default()
            });
        }
        if !request.read_only || request.best_effort || !request.mutations.is_empty() {
            return self.violation("canonical reads must be read-only snapshot queries");
        }
        if request.start_ts
            != if self.snapshot_established {
                SNAPSHOT
            } else {
                0
            }
        {
            return self.violation("the reader changed its transaction between source pages");
        }

        self.queries.push(request.query.clone());
        if request.query.contains("eq(iface.key,") {
            return self.interface_lookup(&request.query);
        }
        if self.neighborhood.is_some() {
            return self.neighborhood_page(&request);
        }
        let query: String = request.query.split_whitespace().collect();
        let block = if query.contains("type(Device)") {
            Block::Nodes
        } else if query.contains("type(TopologyEdge)") {
            Block::Edges
        } else {
            return self.violation("unexpected source query type");
        };
        let first = argument(&query, &request.vars, "first")
            .map(|value| value.parse::<usize>().expect("numeric first argument"))
            .unwrap_or(usize::MAX);
        let after = argument(&query, &request.vars, "after")
            .map(|value| uid(&value))
            .unwrap_or(0);
        let name = query
            .split_once("(func:")
            .expect("root query function")
            .0
            .rsplit('{')
            .next()
            .expect("root query alias");

        let source = match block {
            Block::Nodes => &self.nodes,
            Block::Edges => &self.edges,
        };
        let mut rows: Vec<Value> = source
            .iter()
            .filter(|row| uid(row["uid"].as_str().expect("fixture UID")) > after)
            .take(first)
            .cloned()
            .collect();

        // DQL returns a predicate only when the query selects it. The stored
        // fixture may carry a rank the caller forgot to ask for; omitting it
        // must surface as the client's default, not as a value the server invented.
        for row in &mut rows {
            project_selected(row, &request.query);
        }
        // DQL returns a UID only when selected. Keep that protocol obligation in
        // the fake instead of supplying a cursor the request did not ask for.
        if !request
            .query
            .split(|c: char| !c.is_alphanumeric() && c != '_')
            .any(|word| word == "uid")
        {
            for row in &mut rows {
                row.as_object_mut().expect("fixture row").remove("uid");
            }
        }

        let active_fault = self.fault.filter(|_| block == Block::Edges && after > 0);
        let mut context = Some(api::TxnContext {
            start_ts: SNAPSHOT,
            ..Default::default()
        });
        if let Some(fault) = active_fault {
            self.faults_delivered += 1;
            match fault {
                Fault::InvalidUid => rows[0]["uid"] = json!("not-a-uid"),
                Fault::RepeatedUid => rows[0]["uid"] = json!(format!("{after:#x}")),
                Fault::MissingUid => {
                    rows[0].as_object_mut().expect("fixture row").remove("uid");
                }
                Fault::WrongFieldType => rows[0]["topo.flow_pps_ab"] = json!({"invalid": true}),
                Fault::MissingTimestamp => context = None,
                Fault::ZeroTimestamp => context.as_mut().expect("context").start_ts = 0,
                Fault::ChangedTimestamp => {
                    context.as_mut().expect("context").start_ts = SNAPSHOT + 1
                }
                Fault::AbortedSnapshot => context.as_mut().expect("context").aborted = true,
                Fault::OversizedRow => {
                    rows[0]["topo.if_name_ab"] = json!("x".repeat(RECEIVE_LIMIT + 1024))
                }
                Fault::MissingBlock | Fault::ServerFailure => {}
            }
        }

        let body = if matches!(active_fault, Some(Fault::MissingBlock)) {
            json!({})
        } else {
            json!({name: rows})
        };
        let json = serde_json::to_vec(&body).expect("fixture JSON");
        self.calls.push(PageCall {
            block,
            first,
            after,
            start_ts: request.start_ts,
            bytes: json.len(),
        });
        if matches!(active_fault, Some(Fault::ServerFailure)) {
            return Err(Status::unavailable("invented later-page outage"));
        }
        // An oversized first response is rejected before the client receives
        // its timestamp. The first successfully decoded response pins the read.
        if json.len() < RECEIVE_LIMIT - 1024 {
            self.snapshot_established = true;
        }
        Ok(api::Response {
            json,
            txn: context,
            ..Default::default()
        })
    }

    /// `eq(iface.key, [..])`: the stored Interface rows whose key is listed.
    fn interface_lookup(&mut self, query: &str) -> Result<api::Response, Status> {
        let list = query
            .split_once("eq(iface.key,")
            .and_then(|(_, rest)| rest.split_once("]))"))
            .map(|(list, _)| format!("{list}]"))
            .expect("interface key list");
        let keys: BTreeSet<String> = serde_json::from_str(&list).expect("JSON key list");
        if self
            .interface_outage_after
            .is_some_and(|answered| self.interface_calls.len() >= answered)
        {
            self.interface_calls.push((keys.len(), 0));
            return Err(Status::unavailable("invented interface lookup outage"));
        }
        let mut rows: Vec<Value> = self
            .interfaces
            .iter()
            .filter(|row| keys.contains(row["iface.key"].as_str().expect("fixture key")))
            .cloned()
            .collect();
        for row in &mut rows {
            project_selected(row, query);
        }
        let json = serde_json::to_vec(&json!({"interfaces": rows})).expect("fixture JSON");
        self.interface_calls.push((keys.len(), json.len()));
        if json.len() < RECEIVE_LIMIT - 1024 {
            self.snapshot_established = true;
        }
        Ok(api::Response {
            json,
            txn: Some(api::TxnContext {
                start_ts: SNAPSHOT,
                ..Default::default()
            }),
            ..Default::default()
        })
    }

    /// A prune transaction: the stored edges of a kind the query names, past
    /// its cursor. Every fixture edge is older than any cutoff. Dgraph commits
    /// the mutation whether or not the client can decode the response.
    fn age(&mut self, request: &api::Request) -> Result<api::Response, Status> {
        let query: String = request.query.split_whitespace().collect();
        let first = argument(&query, &request.vars, "first")
            .map(|value| value.parse::<usize>().expect("numeric first argument"))
            .unwrap_or(usize::MAX);
        let after = argument(&query, &request.vars, "after")
            .map(|value| uid(&value))
            .unwrap_or(0);
        let aged: BTreeSet<u64> = self
            .edges
            .iter()
            .filter(|row| {
                let kind = row["topo.kind"].as_str().expect("fixture kind");
                request
                    .query
                    .contains(&format!("eq(topo.kind, \"{kind}\")"))
            })
            .map(|row| uid(row["uid"].as_str().expect("fixture UID")))
            .filter(|row| *row > after)
            .take(first)
            .collect();
        let rows: Vec<Value> = aged
            .iter()
            .map(|row| json!({"uid": format!("{row:#x}")}))
            .collect();
        let json = serde_json::to_vec(&json!({"stale": rows})).expect("fixture JSON");
        let stored = |row: &Value| aged.contains(&uid(row["uid"].as_str().expect("fixture UID")));
        if request.mutations[0].delete_json.is_empty() {
            for row in self.edges.iter_mut().filter(|row| stored(row)) {
                row["topo.stale"] = json!(true);
            }
        } else {
            self.edges.retain(|row| !stored(row));
        }
        self.age_calls.push((first, after, json.len()));
        Ok(api::Response {
            json,
            txn: Some(api::TxnContext::default()),
            ..Default::default()
        })
    }

    /// One page of a neighbourhood read, chosen by its root block and the
    /// `var` blocks that block reads from.
    fn neighborhood_page(&mut self, request: &api::Request) -> Result<api::Response, Status> {
        let query: String = request.query.split_whitespace().collect();
        let (vars, root) = query.rsplit_once("(func:").expect("root query function");
        let block = vars
            .rsplit(['{', '}'])
            .next()
            .expect("root query alias")
            .to_owned();
        let first = argument(root, &request.vars, "first")
            .map(|value| value.parse::<usize>().expect("numeric first argument"))
            .unwrap_or(usize::MAX);
        let after = argument(root, &request.vars, "after")
            .map(|value| uid(&value))
            .unwrap_or(0);
        let stored = self.neighborhood.as_ref().expect("neighbourhood fixture");
        let source: Vec<&Value> = match block.as_str() {
            "device" => {
                let id = stored.device["device.id"].as_str().expect("fixture id");
                let named = request.query.contains(&format!("eq(device.id, \"{id}\")"));
                named.then_some(&stored.device).into_iter().collect()
            }
            "interfaces" if vars.contains("ownasdevice.interfaces") => {
                stored.interfaces.iter().collect()
            }
            "edges" if vars.contains("incidentas~topo.src") => stored.outbound.iter().collect(),
            "edges" if vars.contains("incidentas~topo.dst") => stored.inbound.iter().collect(),
            "peer_interfaces" => named_peer_interfaces(vars, &stored.peer_interfaces),
            _ => return self.violation("unexpected neighbourhood query"),
        };
        let mut rows: Vec<Value> = source
            .into_iter()
            .filter(|row| uid(row["uid"].as_str().expect("fixture UID")) > after)
            .take(first)
            .cloned()
            .collect();
        for row in &mut rows {
            project_selected(row, &request.query);
        }
        let count = rows.len();
        let mut body = serde_json::Map::new();
        body.insert(block.clone(), Value::Array(rows));
        let json = serde_json::to_vec(&body).expect("fixture JSON");
        self.neighborhood_calls.push(NeighborhoodCall {
            block,
            first,
            rows: count,
            bytes: json.len(),
        });
        if json.len() < RECEIVE_LIMIT - 1024 {
            self.snapshot_established = true;
        }
        Ok(api::Response {
            json,
            txn: Some(api::TxnContext {
                start_ts: SNAPSHOT,
                ..Default::default()
            }),
            ..Default::default()
        })
    }

    fn violation(&mut self, message: &str) -> Result<api::Response, Status> {
        self.violations.push(message.to_owned());
        Err(Status::failed_precondition(message.to_owned()))
    }

    fn assert_protocol(&self) {
        assert!(
            self.violations.is_empty(),
            "unexpected request failures: {:?}",
            self.violations
        );
        assert!(
            self.calls
                .iter()
                .all(|call| call.first > 0 && call.first <= 256)
        );
    }
}

#[tokio::test]
async fn hosted_replacement_scopes_retirement_and_rejects_older_observations() {
    let server = RunningServer::start(Fixture {
        mutation_response: json!({"source":[{"uid":"0x1"}],"target":[{"uid":"0x2"}]}),
        ..Fixture::default()
    })
    .await;
    let edge = EdgeWrite::new(
        "sr:guest.example.test",
        "sr:host.example.test",
        EdgeKind::HostedOn,
        "virtualization_inventory",
        "hosted-virtual",
        "hypervisor_enrichment_v1",
    )
    .with_last_seen("2030-02-03T04:05:06Z");

    server
        .client
        .replace_hosted_edge(&edge)
        .await
        .expect("valid hosted projection mutation");

    let fixture = server.fixture.lock().expect("fixture lock");
    let (query, condition, delete) = fixture
        .mutation_contracts
        .first()
        .expect("one atomic replacement mutation");
    assert!(query.contains("~topo.src"), "{query}");
    assert!(
        query.contains("eq(topo.ingestor, \"hypervisor_enrichment_v1\")"),
        "{query}"
    );
    assert!(query.contains("eq(topo.kind, \"HOSTED_ON\")"), "{query}");
    assert!(
        query.contains("gt(topo.last_seen, \"2030-02-03T04:05:06Z\")"),
        "{query}"
    );
    assert!(!query.contains("type(TopologyEdge)"), "{query}");
    assert_eq!(
        condition,
        "@if(eq(len(s), 1) AND eq(len(d), 1) AND eq(len(n), 0) AND eq(len(identical), 0))"
    );
    assert_eq!(
        delete,
        &json!([
            {"uid": "uid(e)"},
            {"uid": "uid(c)", "topo.dst": null}
        ])
    );
    assert_eq!(
        fixture.mutations[0]["topo.ingestor"],
        "hypervisor_enrichment_v1"
    );
    assert!(
        fixture.mutations[0]["topo.link_key"]
            .as_str()
            .expect("projection link key")
            .contains("projection=hypervisor_enrichment_v1")
    );
    assert_eq!(fixture.mutations[0]["topo.kind"], "HOSTED_ON");
    assert_eq!(fixture.mutations[0]["topo.telemetry_eligible"], false);
}

#[tokio::test]
async fn hosted_replacement_rejects_missing_or_ambiguous_endpoint_identities() {
    for response in [
        json!({"source":[],"target":[{"uid":"0x2"}]}),
        json!({"source":[{"uid":"0x1"},{"uid":"0x3"}],"target":[{"uid":"0x2"}]}),
    ] {
        let server = RunningServer::start(Fixture {
            mutation_response: response,
            ..Fixture::default()
        })
        .await;
        let edge = EdgeWrite::new(
            "sr:guest.example.test",
            "sr:host.example.test",
            EdgeKind::HostedOn,
            "virtualization_inventory",
            "hosted-virtual",
            "hypervisor_enrichment_v1",
        )
        .with_last_seen("2030-02-03T04:05:06Z");
        assert!(server.client.replace_hosted_edge(&edge).await.is_err());
    }
}

fn argument(
    query: &str,
    variables: &std::collections::HashMap<String, String>,
    name: &str,
) -> Option<String> {
    let value = query
        .split_once(&format!("{name}:"))?
        .1
        .split([',', ')'])
        .next()?;
    Some(
        variables
            .get(value)
            .cloned()
            .unwrap_or_else(|| value.to_owned()),
    )
}

fn uid(value: &str) -> u64 {
    u64::from_str_radix(
        value.strip_prefix("0x").expect("hexadecimal fixture UID"),
        16,
    )
    .expect("numeric fixture UID")
}

fn device(index: usize) -> Value {
    json!({
        "uid": format!("{index:#x}"),
        "device.id": format!("sr:host{index:04}.example.com"),
        "device.hostname": format!("host{index:04}.example.com")
    })
}

fn edge(index: usize, interface_bytes: usize) -> Value {
    json!({
        "uid": format!("{:#x}", 4096 + index),
        "topo.link_key": format!("invented-edge-{index}"),
        "topo.protocol": "lldp",
        "topo.evidence_class": "direct-physical",
        "topo.confidence_tier": "high",
        "topo.flow_pps_ab": index,
        "topo.pair_support_rank": index,
        "topo.if_name_ab": "x".repeat(interface_bytes),
        "topo.src": [{"device.id": "sr:host0001.example.com"}],
        "topo.dst": [{"device.id": "sr:host0002.example.com"}]
    })
}

fn project_selected(value: &mut Value, query: &str) {
    match value {
        Value::Object(map) => {
            map.retain(|key, _child| query.contains(key));
            for child in map.values_mut() {
                project_selected(child, query);
            }
        }
        Value::Array(items) => {
            for item in items {
                project_selected(item, query);
            }
        }
        _ => {}
    }
}

struct RunningServer {
    client: TopologyClient,
    fixture: Arc<Mutex<Fixture>>,
    task: JoinHandle<()>,
}

impl RunningServer {
    async fn start(fixture: Fixture) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind loopback");
        let address = listener.local_addr().expect("listener address");
        let fixture = Arc::new(Mutex::new(fixture));
        let service = ProtocolServer(Arc::clone(&fixture));
        let task = tokio::spawn(async move {
            tonic::transport::Server::builder()
                .add_service(DgraphServer::new(service))
                .serve_with_incoming(TcpListenerStream::new(listener))
                .await
                .expect("serve invented Dgraph protocol");
        });
        let client = TopologyClient::connect(&format!("dgraph://{address}?sslmode=disable"))
            .await
            .expect("connect loopback Dgraph");
        Self {
            client,
            fixture,
            task,
        }
    }
}

impl Drop for RunningServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[tokio::test]
async fn canonical_edges_page_past_the_grpc_limit_and_an_unadmitted_page() {
    let mut edges: Vec<Value> = (1..=321).map(|index| edge(index, 20 * 1024)).collect();
    // The entire first successful 128-row page is excluded by the existing
    // orphan-edge policy. It must not terminate traversal of later raw rows.
    for row in &mut edges[..128] {
        row.as_object_mut().expect("fixture row").remove("topo.dst");
    }
    let server = RunningServer::start(Fixture {
        edges,
        ..Default::default()
    })
    .await;
    let edges = tokio::time::timeout(
        Duration::from_secs(10),
        server.client.query_canonical_edges(),
    )
    .await
    .expect("finite source traversal")
    .expect("complete paged edge read");
    assert_eq!(edges.len(), 193);
    assert_eq!(
        edges.first().expect("first admitted edge").link_key(),
        "invented-edge-129"
    );
    assert_eq!(
        edges.last().expect("last edge").link_key(),
        "invented-edge-321"
    );
    assert!(
        edges
            .iter()
            .all(|edge| edge.local_if_name_ab().len() == 20 * 1024)
    );
    assert!(edges.iter().all(|edge| {
        let index: i64 = edge
            .link_key()
            .trim_start_matches("invented-edge-")
            .parse()
            .expect("invented edge index");
        edge.pair_support_rank() == index
    }));
    let fixture = server.fixture.lock().expect("fixture lock");
    fixture.assert_protocol();
    assert!(
        fixture.calls.iter().any(|call| call.bytes > RECEIVE_LIMIT),
        "exercise tonic's real receive ceiling"
    );
    assert!(
        fixture
            .calls
            .iter()
            .any(|call| call.first < 256 && call.after == 0),
        "retry an oversized page at the same cursor"
    );
    assert!(
        fixture
            .calls
            .iter()
            .filter(|call| call.bytes < RECEIVE_LIMIT)
            .map(|call| call.bytes)
            .sum::<usize>()
            > RECEIVE_LIMIT
    );
    assert!(
        fixture
            .calls
            .iter()
            .filter(|call| call.after > 0)
            .all(|call| call.start_ts == SNAPSHOT)
    );
}

#[tokio::test]
async fn edge_upsert_preserves_only_supplied_observation_time() {
    use dgraph_topology::{EdgeKind, EdgeWrite};

    let server = RunningServer::start(Fixture::default()).await;
    server
        .client
        .upsert_edge(&EdgeWrite::new(
            "synthetic-source",
            "synthetic-target",
            EdgeKind::AttachedTo,
            "fixture",
            "physical",
            "synthetic-test",
        ))
        .await
        .expect("upsert edge without observation time");
    server
        .client
        .upsert_edge(
            &EdgeWrite::new(
                "synthetic-source",
                "synthetic-target",
                EdgeKind::AttachedTo,
                "fixture",
                "physical",
                "synthetic-test",
            )
            .with_last_seen("2030-01-02T03:04:05Z"),
        )
        .await
        .expect("upsert edge with observation time");

    let fixture = server.fixture.lock().expect("fixture lock");
    assert_eq!(fixture.mutations.len(), 2);
    assert_eq!(fixture.mutations[0]["topo.stale"], false);
    assert!(fixture.mutations[0].get("topo.last_seen").is_none());
    assert_eq!(
        fixture.mutations[1]["topo.last_seen"],
        "2030-01-02T03:04:05Z"
    );
}

#[tokio::test]
async fn canonical_graph_keeps_isolated_vertices_and_one_snapshot_across_both_scans() {
    let server = RunningServer::start(Fixture {
        nodes: (1..=258).map(device).collect(),
        edges: (1..=257).map(|index| edge(index, 0)).collect(),
        ..Default::default()
    })
    .await;
    let graph = tokio::time::timeout(
        Duration::from_secs(10),
        server.client.query_canonical_graph(),
    )
    .await
    .expect("finite graph traversal")
    .expect("complete canonical graph");
    assert_eq!(graph.nodes().len(), 258);
    assert_eq!(graph.edges().len(), 257);
    assert!(graph.edges().iter().all(|edge| {
        let index: i64 = edge
            .link_key()
            .trim_start_matches("invented-edge-")
            .parse()
            .expect("invented edge index");
        edge.pair_support_rank() == index
    }));
    let isolated = graph.nodes().last().expect("isolated canonical vertex");
    assert_eq!(isolated.id(), "sr:host0258.example.com");
    assert_eq!(isolated.hostname(), Some("host0258.example.com"));
    assert_eq!(isolated.ip(), None);
    let fixture = server.fixture.lock().expect("fixture lock");
    fixture.assert_protocol();
    assert_eq!(fixture.calls.first().expect("initial query").start_ts, 0);
    assert!(
        fixture
            .calls
            .iter()
            .skip(1)
            .all(|call| call.start_ts == SNAPSHOT)
    );
    for block in [Block::Nodes, Block::Edges] {
        assert!(
            fixture
                .calls
                .iter()
                .any(|call| call.block == block && call.after > 0),
            "both source sets must page"
        );
    }
}

#[tokio::test]
async fn later_page_protocol_or_source_failures_never_return_a_partial_graph() {
    for fault in [
        Fault::MissingBlock,
        Fault::InvalidUid,
        Fault::RepeatedUid,
        Fault::MissingUid,
        Fault::WrongFieldType,
        Fault::MissingTimestamp,
        Fault::ZeroTimestamp,
        Fault::ChangedTimestamp,
        Fault::AbortedSnapshot,
        Fault::ServerFailure,
        Fault::OversizedRow,
    ] {
        let server = RunningServer::start(Fixture {
            nodes: vec![device(1)],
            edges: (1..=257).map(|index| edge(index, 0)).collect(),
            fault: Some(fault),
            ..Default::default()
        })
        .await;
        let result = tokio::time::timeout(
            Duration::from_secs(10),
            server.client.query_canonical_graph(),
        )
        .await
        .expect("invalid source must terminate");
        assert!(result.is_err(), "{fault:?} returned partial canonical data");
        let fixture = server.fixture.lock().expect("fixture lock");
        fixture.assert_protocol();
        assert!(
            fixture.faults_delivered > 0,
            "{fault:?} failed before the intended later-page fault"
        );
        assert!(
            fixture
                .calls
                .iter()
                .any(|call| call.block == Block::Edges && call.after == 0)
        );
        if matches!(fault, Fault::OversizedRow) {
            assert_eq!(fixture.calls.last().expect("last page attempt").first, 1);
        }
    }
}

/// A stored row the canonical rebuild reads: only the predicates it selects.
fn rebuild_row(index: usize, kind: &str) -> Value {
    json!({
        "uid": format!("{:#x}", 4096 + index),
        "topo.kind": kind,
        "topo.protocol": "lldp",
        "topo.evidence_class": "direct-physical",
        "topo.ingestor": "mapper_topology_v1",
        "topo.confidence_tier": "high",
        "topo.if_name_ab": format!("port{index}"),
        "topo.if_index_ab": index,
        "topo.last_seen": "2030-01-02T00:00:00Z",
        "topo.pair_support_rank": 0,
        "topo.src": [{"device.id": "sr:host0001.example.com"}],
        "topo.dst": [{"device.id": format!("sr:host{index:04}.example.com")}]
    })
}

fn interface(index: usize, name_bytes: usize) -> Value {
    json!({
        "iface.key": format!("sr:host0001.example.com/port{index}"),
        "iface.name": format!("port{index}{}", "x".repeat(name_bytes)),
        "iface.if_index": index,
        "~device.interfaces": [{"device.id": "sr:host0001.example.com"}]
    })
}

#[tokio::test]
async fn rebuild_inputs_return_every_stored_row_across_pages_of_one_snapshot() {
    let kinds = ["CANONICAL_TOPOLOGY", "CONNECTS_TO", "ATTACHED_TO"];
    let mut stored: Vec<Value> = (1..=600)
        .map(|index| rebuild_row(index, kinds[index % kinds.len()]))
        .collect();
    // A canonical row with no resolvable endpoint must reach the caller, which
    // refuses to rebuild from it. Dropping it here would let the rebuild treat
    // the edge as gone and delete it.
    stored[299]
        .as_object_mut()
        .expect("fixture row")
        .remove("topo.dst");
    let server = RunningServer::start(Fixture {
        edges: stored.clone(),
        ..Default::default()
    })
    .await;

    let rows = tokio::time::timeout(
        Duration::from_secs(10),
        server.client.query_rebuild_inputs(),
    )
    .await
    .expect("finite source traversal")
    .expect("complete paged rebuild read");

    // The same rows one unpaged response would carry, in the same UID order.
    let unpaged: Vec<Value> = stored
        .into_iter()
        .map(|mut row| {
            row.as_object_mut().expect("fixture row").remove("uid");
            row
        })
        .collect();
    assert_eq!(rows, unpaged);

    let fixture = server.fixture.lock().expect("fixture lock");
    fixture.assert_protocol();
    assert_eq!(
        fixture
            .calls
            .iter()
            .map(|call| (call.first, call.after))
            .collect::<Vec<_>>(),
        vec![(256, 0), (256, 4096 + 256), (256, 4096 + 512)]
    );
    assert!(fixture.calls.iter().all(|call| call.bytes < RECEIVE_LIMIT));
    assert!(
        fixture
            .calls
            .iter()
            .filter(|call| call.after > 0)
            .all(|call| call.start_ts == SNAPSHOT)
    );
    // Endpoints are identities only: embedding each device's port list in every
    // edge row is what outgrew the receive limit.
    assert!(
        fixture
            .queries
            .iter()
            .all(|query| !query.contains("device.interfaces")),
        "{:?}",
        fixture.queries
    );
}

#[tokio::test]
async fn a_rebuild_read_that_fails_part_way_returns_no_rows_and_writes_nothing() {
    let server = RunningServer::start(Fixture {
        edges: (1..=600)
            .map(|index| rebuild_row(index, "CANONICAL_TOPOLOGY"))
            .collect(),
        fault: Some(Fault::ServerFailure),
        ..Default::default()
    })
    .await;
    let result = tokio::time::timeout(
        Duration::from_secs(10),
        server.client.query_rebuild_inputs(),
    )
    .await
    .expect("a failed page must terminate the read");
    assert!(result.is_err(), "a partial rebuild input set was returned");
    {
        let fixture = server.fixture.lock().expect("fixture lock");
        assert!(
            fixture.faults_delivered > 0,
            "the first page failed instead"
        );
        assert!(fixture.mutations.is_empty());
    }

    let keys: Vec<String> = (1..=600)
        .map(|index| format!("sr:host0001.example.com/port{index}"))
        .collect();
    let server = RunningServer::start(Fixture {
        interfaces: (1..=600).map(|index| interface(index, 0)).collect(),
        interface_outage_after: Some(1),
        ..Default::default()
    })
    .await;
    let result = tokio::time::timeout(
        Duration::from_secs(10),
        server.client.query_interfaces_by_key(&keys),
    )
    .await
    .expect("a failed chunk must terminate the lookup");
    assert!(result.is_err(), "a partial interface set was returned");
    let fixture = server.fixture.lock().expect("fixture lock");
    assert_eq!(fixture.interface_calls.len(), 2, "one answered, one failed");
    assert!(fixture.mutations.is_empty());
}

#[tokio::test]
async fn interface_lookup_is_chunked_and_splits_a_chunk_past_the_grpc_limit() {
    // 300 keys are two chunks. The first chunk's 256 rows exceed the receive
    // limit, so it is split; no key is lost and no unlisted interface returned.
    let stored: Vec<Value> = (1..=320).map(|index| interface(index, 20 * 1024)).collect();
    let keys: Vec<String> = (1..=300)
        .map(|index| format!("sr:host0001.example.com/port{index}"))
        .collect();
    let server = RunningServer::start(Fixture {
        interfaces: stored.clone(),
        ..Default::default()
    })
    .await;

    let rows = tokio::time::timeout(
        Duration::from_secs(10),
        server.client.query_interfaces_by_key(&keys),
    )
    .await
    .expect("finite lookup")
    .expect("complete chunked lookup");

    assert_eq!(rows, stored[..300]);
    assert!(
        server
            .client
            .query_interfaces_by_key(&[])
            .await
            .expect("empty lookup")
            .is_empty(),
        "an empty key list needs no round trip"
    );
    let fixture = server.fixture.lock().expect("fixture lock");
    assert!(fixture.violations.is_empty(), "{:?}", fixture.violations);
    assert_eq!(
        fixture
            .interface_calls
            .iter()
            .map(|(keys, _bytes)| *keys)
            .collect::<Vec<_>>(),
        vec![256, 128, 128, 44]
    );
    assert!(fixture.interface_calls[0].1 > RECEIVE_LIMIT);
    assert!(
        fixture.interface_calls[1..]
            .iter()
            .all(|(_keys, bytes)| *bytes < RECEIVE_LIMIT)
    );
}

#[tokio::test]
async fn topology_view_keeps_admitted_attachments_and_drops_observations() {
    let kinds = [
        "CANONICAL_TOPOLOGY",
        "ATTACHED_TO",
        "INFERRED_TO",
        "HOSTED_ON",
        "OBSERVED_TO",
        "MTR_PATH",
        "",
    ];
    let mut edges: Vec<_> = kinds
        .iter()
        .enumerate()
        .map(|(index, kind)| {
            json!({
                "uid": format!("{:#x}", 4096 + index + 1),
                "topo.link_key": format!("invented-view-{index}"),
                "topo.kind": kind,
                "topo.last_seen": "2030-01-02T00:00:00Z",
                "topo.protocol": "lldp",
                "topo.evidence_class": "direct-physical",
                "topo.confidence_tier": "high",
                "topo.telemetry_eligible": true,
                "topo.src": [{"device.id": "sr:ap-1.example.test"}],
                "topo.dst": [{"device.id": format!("sr:endpoint-{index}.example.test")}]
            })
        })
        .collect();
    let mut expected_keys: BTreeSet<_> = (0..4).map(|i| format!("invented-view-{i}")).collect();
    let mut stale_keys = BTreeSet::new();
    for kind in &kinds[..4] {
        for (name, seen, fresh) in [
            ("expired", Some("2030-01-01T11:59:59Z"), false),
            ("boundary", Some("2030-01-01T12:00:00Z"), true),
            ("offset", Some("2030-01-01T13:00:00+02:00"), false),
            ("missing", None, false),
            ("invalid", Some("invalid-timestamp"), false),
        ] {
            let key = format!("{kind}-{name}");
            expected_keys.insert(key.clone());
            if *kind != "CANONICAL_TOPOLOGY" && !fresh {
                stale_keys.insert(key.clone());
            }
            let mut row = edges[0].clone();
            row["uid"] = json!(format!("{:#x}", 4096 + edges.len() + 1));
            row["topo.link_key"] = json!(key);
            row["topo.kind"] = json!(kind);
            if let Some(seen) = seen {
                row["topo.last_seen"] = json!(seen);
            } else {
                row.as_object_mut().unwrap().remove("topo.last_seen");
            }
            edges.push(row);
        }
    }
    let expired: Vec<_> = (1..=256)
        .map(|index| {
            let key = format!("expired-prefix-{index}");
            expected_keys.insert(key.clone());
            stale_keys.insert(key.clone());
            let mut row = edges[1].clone();
            row["uid"] = json!(format!("{index:#x}"));
            row["topo.link_key"] = json!(key);
            row["topo.last_seen"] = json!("2000-01-01T00:00:00Z");
            row
        })
        .collect();
    edges.splice(0..0, expired);
    edges.push(json!({
        "uid": "0xff01",
        "topo.link_key": "flagged-attachment",
        "topo.kind": "ATTACHED_TO",
        "topo.stale": true,
        "topo.last_seen": "2030-01-02T00:00:00Z",
        "topo.src": [{"device.id": "sr:ap-1.example.test"}],
        "topo.dst": [{"device.id": "sr:flagged-attachment.example.test"}]
    }));
    edges.push(json!({
        "uid": "0xff02",
        "topo.link_key": "flagged-canonical",
        "topo.kind": "CANONICAL_TOPOLOGY",
        "topo.stale": true,
        "topo.last_seen": "2030-01-02T00:00:00Z",
        "topo.src": [{"device.id": "sr:ap-1.example.test"}],
        "topo.dst": [{"device.id": "sr:flagged-canonical.example.test"}]
    }));
    expected_keys.insert("flagged-attachment".to_owned());
    stale_keys.insert("flagged-attachment".to_owned());
    let server = RunningServer::start(Fixture {
        nodes: vec![json!({
            "uid": "0x1",
            "device.id": "sr:ap-1.example.test",
            "device.hostname": "ap-1.example.test"
        })],
        edges,
        ..Default::default()
    })
    .await;
    let view = tokio::time::timeout(
        Duration::from_secs(10),
        server.client.query_topology_view("2030-01-01T12:00:00Z"),
    )
    .await
    .expect("finite view traversal")
    .expect("complete topology view");
    assert_eq!(view.nodes().len(), 1);
    assert_eq!(view.nodes()[0].id(), "sr:ap-1.example.test");
    assert_eq!(view.nodes()[0].hostname(), Some("ap-1.example.test"));
    assert_eq!(
        view.edges()
            .iter()
            .map(|edge| edge.edge().link_key().to_owned())
            .collect::<BTreeSet<_>>(),
        expected_keys
    );
    assert_eq!(
        view.edges()
            .iter()
            .filter(|edge| edge.stale())
            .map(|edge| edge.edge().link_key().to_owned())
            .collect::<BTreeSet<_>>(),
        stale_keys
    );
    assert_eq!(
        view.edges()
            .iter()
            .find(|edge| edge.edge().link_key() == "invented-view-1")
            .and_then(|edge| edge.last_seen()),
        Some("2030-01-02T00:00:00Z")
    );
    assert_eq!(
        view.edges()
            .iter()
            .find(|edge| edge.edge().link_key() == "ATTACHED_TO-missing")
            .and_then(|edge| edge.last_seen()),
        None
    );
    assert!(
        view.edges()
            .iter()
            .filter(|edge| edge.kind() == "CANONICAL_TOPOLOGY")
            .all(|edge| !edge.stale())
    );
    let admitted: BTreeSet<_> = view
        .edges()
        .iter()
        .map(|edge| edge.kind().to_owned())
        .collect();
    assert_eq!(
        admitted,
        BTreeSet::from([
            "CANONICAL_TOPOLOGY".to_owned(),
            "ATTACHED_TO".to_owned(),
            "INFERRED_TO".to_owned(),
            "HOSTED_ON".to_owned(),
        ])
    );
    let fixture = server.fixture.lock().expect("fixture lock");
    fixture.assert_protocol();
    assert_eq!(
        fixture
            .calls
            .iter()
            .filter(|call| call.block == Block::Edges)
            .count(),
        2
    );
    let edge_query = fixture
        .queries
        .iter()
        .find(|query| query.contains("type(TopologyEdge)"))
        .expect("edge page");
    for kind in [
        "CANONICAL_TOPOLOGY",
        "ATTACHED_TO",
        "INFERRED_TO",
        "HOSTED_ON",
    ] {
        assert!(
            edge_query.contains(&format!("eq(topo.kind, \"{kind}\")")),
            "{edge_query}"
        );
    }
    assert!(!edge_query.contains("OBSERVED_TO"));
    assert!(!edge_query.contains("MTR_PATH"));
    assert!(
        edge_query
            .contains(r#"(eq(topo.kind, "CANONICAL_TOPOLOGY") AND NOT eq(topo.stale, true))"#),
        "{edge_query}"
    );
    assert!(edge_query.contains("topo.stale"), "{edge_query}");
}

/// The stored peer Interfaces a `peer_interfaces` page may return: for each
/// `var(func: uid(P)) { .. as device.interfaces @filter(..) }` block, the
/// Interfaces owned by `P` whose name or ifIndex that block's filter lists.
fn named_peer_interfaces<'a>(vars: &str, stored: &'a [Value]) -> Vec<&'a Value> {
    fn listed<T: serde::de::DeserializeOwned>(block: &str, function: &str) -> Vec<T> {
        block
            .split_once(function)
            .and_then(|(_, rest)| rest.split_once("])"))
            .map(|(list, _)| serde_json::from_str(&format!("[{list}]")).expect("JSON list"))
            .unwrap_or_default()
    }
    let mut selected = Vec::new();
    for block in vars.split("var(func:uid(").skip(1) {
        let owner = block.split_once(')').expect("peer UID").0;
        let names: Vec<String> = listed(block, "eq(iface.name,[");
        let if_indexes: Vec<i64> = listed(block, "eq(iface.if_index,[");
        selected.extend(stored.iter().filter(|row| {
            row["~device.interfaces"][0]["uid"] == owner
                && (names.iter().any(|name| row["iface.name"] == name.as_str())
                    || if_indexes
                        .iter()
                        .any(|index| row["iface.if_index"] == *index))
        }));
    }
    selected.sort_by_key(|row| uid(row["uid"].as_str().expect("fixture UID")));
    selected
}

#[tokio::test]
async fn prune_ages_every_edge_in_bounded_transactions_past_the_grpc_limit() {
    // One transaction naming every aged UID answers with more than the receive
    // limit; the edges of a kind the prune does not name must be left alone.
    let kind = |index: u64| match index % 36 {
        0 => "ATTACHED_TO",
        1 => "MTR_PATH",
        _ => "CONNECTS_TO",
    };
    let stored: Vec<Value> = (0..185_000_u64)
        .map(|index| {
            json!({
                "uid": format!("{:#x}", 0x1000_0000_0000_u64 + index),
                "topo.kind": kind(index)
            })
        })
        .collect();
    let count = |wanted: &str| {
        stored
            .iter()
            .filter(|row| row["topo.kind"] == wanted)
            .count()
    };
    let (attached, mtr, connects) = (
        count("ATTACHED_TO"),
        count("MTR_PATH"),
        count("CONNECTS_TO"),
    );
    let server = RunningServer::start(Fixture {
        edges: stored,
        ..Default::default()
    })
    .await;

    let aged = tokio::time::timeout(
        Duration::from_secs(60),
        server.client.prune_stale(
            "2030-01-02T00:00:00Z",
            &["ATTACHED_TO".to_owned(), "CONNECTS_TO".to_owned()],
        ),
    )
    .await
    .expect("finite prune")
    .expect("complete paged prune");
    assert_eq!(aged, attached + connects);

    let fixture = server.fixture.lock().expect("fixture lock");
    assert!(fixture.violations.is_empty(), "{:?}", fixture.violations);
    // Attachments stay as last-known rows; evidence is deleted; the rest is untouched.
    assert_eq!(fixture.edges.len(), attached + mtr);
    assert!(fixture.edges.iter().all(
        |row| match row["topo.kind"].as_str().expect("fixture kind") {
            "ATTACHED_TO" => row["topo.stale"] == true,
            "MTR_PATH" => row.get("topo.stale").is_none(),
            _ => false,
        }
    ));
    assert!(
        fixture
            .age_calls
            .iter()
            .all(|(_first, _after, bytes)| *bytes < RECEIVE_LIMIT / 8),
        "a prune transaction returned an unbounded UID list"
    );
    assert!(
        fixture
            .age_calls
            .iter()
            .map(|(_first, _after, bytes)| bytes)
            .sum::<usize>()
            > RECEIVE_LIMIT,
        "the aged UIDs must outgrow one response"
    );
}

#[tokio::test]
async fn device_neighborhood_pages_ports_and_reads_only_the_peer_ports_edges_name() {
    const CORE: &str = "sr:core0001.example.com";
    let description = "x".repeat(20 * 1024);
    let host = |peer: usize| format!("sr:host{peer:04}.example.com");
    let peer_uid = |peer: usize| format!("{:#x}", 0x1_0000 + peer);
    let peer = |peer: usize| {
        json!([{
            "uid": peer_uid(peer),
            "device.id": host(peer),
            "device.hostname": format!("host{peer:04}.example.com")
        }])
    };
    let port = |uid: usize, owner: usize, name: &str, if_index: usize, description: &str| {
        json!({
            "uid": format!("{uid:#x}"),
            "iface.key": format!("{}/{name}", host(owner)),
            "iface.name": name,
            "iface.if_index": if_index,
            "iface.description": description,
            "~device.interfaces": [{"uid": peer_uid(owner)}]
        })
    };

    // 300 access peers each carry three uplinks; an edge names one of them.
    // Five more name their port by ifIndex alone, and the last names a port
    // that has no Interface vertex.
    let mut peer_interfaces = Vec::new();
    for owner in 1..=300 {
        for uplink in 0..3 {
            let named = uplink == owner % 3;
            peer_interfaces.push(port(
                0x10_0000 + owner * 4 + uplink,
                owner,
                &format!("uplink{uplink}"),
                uplink + 1,
                if named { &description } else { "unnamed" },
            ));
        }
    }
    for owner in 301..=305 {
        peer_interfaces.push(port(0x10_0000 + owner * 4, owner, "mgmt", 9, "by ifIndex"));
        peer_interfaces.push(port(
            0x10_0000 + owner * 4 + 1,
            owner,
            "spare",
            10,
            "unnamed",
        ));
    }
    let server = RunningServer::start(Fixture {
        neighborhood: Some(Neighborhood {
            device: json!({
                "uid": "0x1",
                "device.id": CORE,
                "device.hostname": "core0001.example.com",
                "device.ip": "192.0.2.1"
            }),
            interfaces: (1..=300)
                .map(|index| {
                    json!({
                        "uid": format!("{:#x}", 0x100 + index),
                        "iface.key": format!("{CORE}/port{index}"),
                        "iface.name": format!("port{index}"),
                        "iface.if_index": index,
                        "iface.description": description
                    })
                })
                .collect(),
            outbound: (1..=300)
                .map(|owner| {
                    json!({
                        "uid": format!("{:#x}", 0x2_0000 + owner),
                        "topo.if_name_ba": format!("uplink{}", owner % 3),
                        "topo.if_index_ba": 0,
                        "peer": peer(owner)
                    })
                })
                .collect(),
            inbound: (301..=306)
                .map(|owner| {
                    json!({
                        "uid": format!("{:#x}", 0x2_0000 + owner),
                        "topo.if_name_ab": if owner == 306 { "eth0" } else { "" },
                        "topo.if_index_ab": if owner == 306 { 0 } else { 9 },
                        "peer": peer(owner)
                    })
                })
                .collect(),
            peer_interfaces,
        }),
        ..Default::default()
    })
    .await;

    let graph = tokio::time::timeout(
        Duration::from_secs(30),
        server.client.query_device_neighborhood(CORE, true),
    )
    .await
    .expect("finite neighbourhood read")
    .expect("complete paged neighbourhood")
    .expect("the device exists");

    assert_eq!(graph["device"]["id"], CORE);
    assert_eq!(graph["device"]["ip"], "192.0.2.1");
    let interfaces = graph["interfaces"].as_array().expect("interfaces");
    assert_eq!(interfaces.len(), 300);
    assert!(interfaces.iter().zip(1..).all(|(iface, index)| {
        iface["id"] == format!("{CORE}/port{index}")
            && iface["device_id"] == CORE
            && iface["descr"] == description.as_str()
    }));

    let peers = graph["peer_interfaces"]
        .as_array()
        .expect("peer interfaces");
    assert_eq!(peers.len(), 306);
    for (peer, owner) in peers.iter().zip(1..) {
        assert_eq!(peer["owner_device_id"], host(owner), "{owner}");
        assert_eq!(
            peer["owner_device"]["hostname"],
            format!("host{owner:04}.example.com")
        );
        match owner {
            1..=300 => {
                let uplink = owner % 3;
                assert_eq!(peer["id"], format!("{}/uplink{uplink}", host(owner)));
                assert_eq!(peer["ifindex"], uplink + 1);
                assert_eq!(peer["descr"], description.as_str());
            }
            301..=305 => {
                assert_eq!(peer["id"], format!("{}/mgmt", host(owner)));
                assert_eq!(peer["ifindex"], 9);
            }
            _ => {
                assert!(peer["id"].is_null(), "no Interface vertex: {peer}");
                assert_eq!(peer["name"], "eth0");
            }
        }
    }

    let fixture = server.fixture.lock().expect("fixture lock");
    assert!(fixture.violations.is_empty(), "{:?}", fixture.violations);
    let calls = &fixture.neighborhood_calls;
    assert!(calls.iter().all(|call| call.first > 0 && call.first <= 256));
    let decoded = || calls.iter().filter(|call| call.bytes < RECEIVE_LIMIT);
    for block in ["interfaces", "peer_interfaces"] {
        assert!(
            calls
                .iter()
                .any(|call| call.block == block && call.bytes > RECEIVE_LIMIT),
            "{block} must exercise tonic's real receive ceiling"
        );
        assert!(
            decoded()
                .filter(|call| call.block == block)
                .map(|call| call.bytes)
                .sum::<usize>()
                > RECEIVE_LIMIT,
            "{block} must outgrow one response"
        );
    }
    // A peer contributes the port its edge names, not its port list.
    assert_eq!(
        decoded()
            .filter(|call| call.block == "peer_interfaces")
            .map(|call| call.rows)
            .sum::<usize>(),
        305
    );
}

#[derive(Clone)]
struct ProtocolServer(Arc<Mutex<Fixture>>);

#[tonic::async_trait]
impl Dgraph for ProtocolServer {
    async fn check_version(
        &self,
        _request: Request<api::Check>,
    ) -> Result<Response<api::Version>, Status> {
        Ok(Response::new(api::Version {
            tag: "invented-protocol-fixture".into(),
        }))
    }

    async fn query(
        &self,
        request: Request<api::Request>,
    ) -> Result<Response<api::Response>, Status> {
        self.0
            .lock()
            .expect("fixture lock")
            .query(request.into_inner())
            .map(Response::new)
    }

    async fn login(
        &self,
        _request: Request<api::LoginRequest>,
    ) -> Result<Response<api::Response>, Status> {
        unsupported()
    }
    async fn alter(
        &self,
        _request: Request<api::Operation>,
    ) -> Result<Response<api::Payload>, Status> {
        unsupported()
    }
    async fn commit_or_abort(
        &self,
        _request: Request<api::TxnContext>,
    ) -> Result<Response<api::TxnContext>, Status> {
        unsupported()
    }
    async fn run_dql(
        &self,
        _request: Request<api::RunDqlRequest>,
    ) -> Result<Response<api::Response>, Status> {
        unsupported()
    }
    async fn allocate_i_ds(
        &self,
        _request: Request<api::AllocateIDsRequest>,
    ) -> Result<Response<api::AllocateIDsResponse>, Status> {
        unsupported()
    }
    async fn update_ext_snapshot_streaming_state(
        &self,
        _request: Request<api::UpdateExtSnapshotStreamingStateRequest>,
    ) -> Result<Response<api::UpdateExtSnapshotStreamingStateResponse>, Status> {
        unsupported()
    }
    type StreamExtSnapshotStream =
        tokio_stream::Empty<Result<api::StreamExtSnapshotResponse, Status>>;
    async fn stream_ext_snapshot(
        &self,
        _request: Request<tonic::Streaming<api::StreamExtSnapshotRequest>>,
    ) -> Result<Response<Self::StreamExtSnapshotStream>, Status> {
        unsupported()
    }
    async fn create_namespace(
        &self,
        _request: Request<api::CreateNamespaceRequest>,
    ) -> Result<Response<api::CreateNamespaceResponse>, Status> {
        unsupported()
    }
    async fn drop_namespace(
        &self,
        _request: Request<api::DropNamespaceRequest>,
    ) -> Result<Response<api::DropNamespaceResponse>, Status> {
        unsupported()
    }
    async fn list_namespaces(
        &self,
        _request: Request<api::ListNamespacesRequest>,
    ) -> Result<Response<api::ListNamespacesResponse>, Status> {
        unsupported()
    }
}

fn unsupported<T>() -> Result<Response<T>, Status> {
    Err(Status::unimplemented(
        "not a canonical read protocol operation",
    ))
}
