use std::collections::{BTreeSet, HashSet};
use std::sync::{Arc, Mutex};

use dgraph_topology::{
    EGRESS_STITCH_INGESTOR, ExternalEdgeKind, ExternalEdgeWrite, ExternalNodeKind,
    ExternalNodeWrite, ExternalSnapshotWrite, TopologyClient,
};
use proto_dgraph::api;
use proto_dgraph::api::dgraph_server::{Dgraph, DgraphServer};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tokio_stream::wrappers::TcpListenerStream;
use tonic::{Request, Response, Status};

#[derive(Default)]
struct MockExternalDgraph {
    nodes: Vec<Value>,
    edges: Vec<Value>,
    prefix_links: Vec<Value>,
    queries: Vec<String>,
}

impl MockExternalDgraph {
    fn handle(&mut self, req: api::Request) -> Result<api::Response, Status> {
        self.queries.push(req.query.clone());
        if !req.mutations.is_empty() && req.query.contains("aged as uid") {
            return self.handle_prune(&req.query);
        }
        if !req.mutations.is_empty() && req.query.is_empty() {
            return self.handle_delete_mutation(&req.mutations);
        }
        if req.query.contains("direct(func: eq(topo.kind,") {
            return self.handle_egress_seed(&req.query);
        }
        if req.query.contains("vantages(func: eq(ext.kind,") {
            return self.handle_egress_targets();
        }
        if req.query.contains("d0(func: eq(device.id,") {
            return self.handle_device_egress_lookup(&req.query);
        }
        if req.query.contains("func: type(TopologyEdge)") && req.query.contains("egress_stitch_v1")
        {
            return self.handle_global_egress_lookup();
        }
        if req.query.contains("a(func: eq(device.id,") {
            return self.handle_seed_resolve(&req.query);
        }
        if req.query.contains("a(func: eq(ext.id,") {
            return self.handle_asn_seed_resolve(&req.query);
        }
        if req.query.contains("asns(func: eq(ext.asn,") {
            return self.handle_prefix_asn_bridge(&req.query);
        }
        if req.query.contains("prefixes(func: eq(prefix.asn,") {
            return self.handle_asn_prefixes(&req.query);
        }
        if req.query.contains("prefixes(func: type(Prefix)") {
            return self.handle_spof_prefixes(&req.query);
        }
        if req.query.contains("edges(func: type(TopologyEdge)") {
            return self.handle_spof_edges(&req.query);
        }
        if req.query.contains("q(func: uid(") {
            return self.handle_hop_expand(&req.query);
        }
        Ok(ok_json(json!({})))
    }

    fn handle_prune(&mut self, query: &str) -> Result<api::Response, Status> {
        let now = extract_quoted_after(query, "expires_at, ").unwrap_or_default();
        let fallback = extract_quoted_after(query, "last_seen, ").unwrap_or_default();
        let is_edge = query.contains("type(TopologyEdge)");

        let mut aged = Vec::new();
        if is_edge {
            self.edges.retain(|e| {
                let stale = matches_prune(
                    e.get("topo.expires_at").and_then(Value::as_str),
                    e.get("topo.last_seen").and_then(Value::as_str),
                    &now,
                    &fallback,
                ) && e.get("topo.ingestor").and_then(Value::as_str)
                    == Some("horizon_topology_v1");
                if stale {
                    aged.push(json!({ "uid": e["uid"] }));
                }
                !stale
            });
        } else {
            let connected: HashSet<&str> = self
                .edges
                .iter()
                .flat_map(|e| [edge_end_uid(e, "topo.src"), edge_end_uid(e, "topo.dst")])
                .flatten()
                .collect();
            let mut removed = Vec::new();
            for n in &self.nodes {
                let uid = n["uid"].as_str().unwrap_or("");
                let orphan = !connected.contains(uid);
                let stale = n.get("ext.ingestor").and_then(Value::as_str)
                    == Some("horizon_topology_v1")
                    && orphan
                    && matches_prune(
                        n.get("ext.expires_at").and_then(Value::as_str),
                        n.get("ext.last_seen").and_then(Value::as_str),
                        &now,
                        &fallback,
                    );
                if stale {
                    removed.push(uid.to_string());
                    aged.push(json!({ "uid": uid }));
                }
            }
            self.nodes
                .retain(|n| !removed.contains(&n["uid"].as_str().unwrap_or("").to_string()));
        }
        Ok(ok_json(json!({ "stale": aged })))
    }

    fn handle_seed_resolve(&self, query: &str) -> Result<api::Response, Status> {
        let seed = extract_quoted_after(query, "eq(device.id, ").unwrap_or_default();
        let matches: Vec<Value> = self
            .nodes
            .iter()
            .filter(|n| {
                n.get("device.id").and_then(Value::as_str) == Some(seed.as_str())
                    || n.get("ext.id").and_then(Value::as_str) == Some(seed.as_str())
                    || n.get("prefix.cidr").and_then(Value::as_str) == Some(seed.as_str())
            })
            .cloned()
            .collect();
        Ok(ok_json(json!({ "a": matches })))
    }

    fn handle_asn_seed_resolve(&self, query: &str) -> Result<api::Response, Status> {
        let wanted_id = extract_quoted_after(query, "eq(ext.id, ");
        let wanted_asn = parse_arg_usize(query, "eq(ext.asn,").and_then(|v| i64::try_from(v).ok());
        let matches: Vec<Value> = self
            .nodes
            .iter()
            .filter(|n| {
                n.get("ext.kind").and_then(Value::as_str) == Some("ASN")
                    && (wanted_id
                        .as_deref()
                        .is_some_and(|id| n.get("ext.id").and_then(Value::as_str) == Some(id))
                        || wanted_asn
                            .is_some_and(|a| n.get("ext.asn").and_then(Value::as_i64) == Some(a)))
            })
            .cloned()
            .collect();
        Ok(ok_json(json!({ "a": matches })))
    }

    fn handle_prefix_asn_bridge(&self, query: &str) -> Result<api::Response, Status> {
        let wanted: HashSet<i64> = extract_bracket_list(query, "eq(ext.asn, [")
            .split(',')
            .filter_map(|s| s.trim().parse::<i64>().ok())
            .collect();
        let asns: Vec<Value> = self
            .nodes
            .iter()
            .filter(|n| {
                n.get("ext.kind").and_then(Value::as_str) == Some("ASN")
                    && n.get("ext.asn")
                        .and_then(Value::as_i64)
                        .is_some_and(|a| wanted.contains(&a))
            })
            .cloned()
            .collect();
        Ok(ok_json(json!({ "asns": asns })))
    }

    fn handle_asn_prefixes(&self, query: &str) -> Result<api::Response, Status> {
        let wanted: HashSet<i64> = if query.contains("eq(prefix.asn, [") {
            extract_bracket_list(query, "eq(prefix.asn, [")
                .split(',')
                .filter_map(|s| s.trim().parse::<i64>().ok())
                .collect()
        } else {
            parse_arg_usize(query, "eq(prefix.asn,")
                .map(|v| i64::try_from(v).unwrap_or(0))
                .into_iter()
                .collect()
        };
        let prefixes: Vec<Value> = self
            .nodes
            .iter()
            .filter(|n| {
                n.get("prefix.cidr").is_some()
                    && n.get("prefix.asn")
                        .and_then(Value::as_i64)
                        .is_some_and(|a| wanted.contains(&a))
            })
            .map(|n| {
                let mut row = n.clone();
                if let Some(link) = self
                    .prefix_links
                    .iter()
                    .find(|p| p.get("prefix.cidr") == n.get("prefix.cidr"))
                    && let Some(rev) = link.get("~iface.prefixes")
                {
                    row["~iface.prefixes"] = rev.clone();
                }
                row
            })
            .collect();
        Ok(ok_json(json!({ "prefixes": prefixes })))
    }

    fn handle_egress_seed(&self, query: &str) -> Result<api::Response, Status> {
        let cap = parse_arg_usize(query, "first:").unwrap_or(50);
        let direct: Vec<Value> = self
            .edges
            .iter()
            .filter(|e| e.get("topo.kind").and_then(Value::as_str) == Some("EGRESSES_TO"))
            .take(cap)
            .cloned()
            .collect();
        let border_direct: Vec<Value> = self
            .edges
            .iter()
            .filter(|e| {
                e.get("topo.kind").and_then(Value::as_str) == Some("BORDER_HANDOFF")
                    && e.get("topo.src")
                        .and_then(Value::as_array)
                        .and_then(|arr| arr.first())
                        .and_then(|src| src.get("device.id"))
                        .is_some()
            })
            .take(cap)
            .cloned()
            .collect();
        let dev_prefixes: Vec<Value> = self.prefix_links.iter().take(cap).cloned().collect();
        Ok(ok_json(json!({
            "direct": direct,
            "border_direct": border_direct,
            "dev_prefixes": dev_prefixes
        })))
    }

    fn handle_egress_targets(&self) -> Result<api::Response, Status> {
        let prefixes: Vec<Value> = self
            .nodes
            .iter()
            .filter(|n| {
                n.get("prefix.cidr").is_some()
                    && n.get("prefix.asn")
                        .and_then(Value::as_i64)
                        .is_some_and(|a| a > 0)
            })
            .cloned()
            .collect();
        let asns: Vec<Value> = self
            .nodes
            .iter()
            .filter(|n| n.get("ext.kind").and_then(Value::as_str) == Some("ASN"))
            .cloned()
            .collect();
        let vantages: Vec<Value> = self
            .nodes
            .iter()
            .filter(|n| n.get("ext.kind").and_then(Value::as_str) == Some("Vantage"))
            .cloned()
            .collect();
        Ok(ok_json(json!({
            "prefixes": prefixes,
            "asns": asns,
            "vantages": vantages
        })))
    }

    fn handle_device_egress_lookup(&self, query: &str) -> Result<api::Response, Status> {
        let dev_id = extract_quoted_after(query, "eq(device.id, ").unwrap_or_default();
        let dev_uid = self
            .nodes
            .iter()
            .find(|n| n.get("device.id").and_then(Value::as_str) == Some(dev_id.as_str()))
            .and_then(|n| n["uid"].as_str());
        let out_edges: Vec<Value> = self
            .edges
            .iter()
            .filter(|e| {
                e.get("topo.ingestor").and_then(Value::as_str) == Some(EGRESS_STITCH_INGESTOR)
                    && dev_uid.is_some_and(|u| edge_end_uid(e, "topo.src") == Some(u))
            })
            .cloned()
            .collect();
        Ok(ok_json(json!({
            "d0": [{ "~topo.src": out_edges }]
        })))
    }

    fn handle_global_egress_lookup(&self) -> Result<api::Response, Status> {
        let edges: Vec<Value> = self
            .edges
            .iter()
            .filter(|e| {
                e.get("topo.ingestor").and_then(Value::as_str) == Some(EGRESS_STITCH_INGESTOR)
            })
            .cloned()
            .collect();
        Ok(ok_json(json!({ "edges": edges })))
    }

    fn handle_delete_mutation(
        &mut self,
        mutations: &[api::Mutation],
    ) -> Result<api::Response, Status> {
        for m in mutations {
            if !m.delete_json.is_empty()
                && let Ok(Value::Array(items)) = serde_json::from_slice::<Value>(&m.delete_json)
            {
                let remove: HashSet<String> = items
                    .iter()
                    .filter_map(|v| {
                        v.get("uid")
                            .and_then(Value::as_str)
                            .map(ToString::to_string)
                    })
                    .collect();
                self.edges
                    .retain(|e| !e["uid"].as_str().is_some_and(|u| remove.contains(u)));
            }
        }
        Ok(ok_json(json!({})))
    }

    fn handle_hop_expand(&self, query: &str) -> Result<api::Response, Status> {
        let uids: Vec<&str> = query
            .split_once("func: uid(")
            .and_then(|(_, r)| r.split_once(')'))
            .map(|(u, _)| u.split(',').map(str::trim).collect())
            .unwrap_or_default();
        let mut q = Vec::new();
        for uid in uids {
            let out_edges: Vec<Value> = self
                .edges
                .iter()
                .filter(|e| edge_end_uid(e, "topo.src") == Some(uid))
                .cloned()
                .collect();
            let in_egress_only = query.contains(
                "~topo.dst @filter(NOT eq(topo.stale, true) AND eq(topo.kind, [\"EGRESSES_TO\", \"BORDER_HANDOFF\"]))",
            );
            let in_edges: Vec<Value> = self
                .edges
                .iter()
                .filter(|e| {
                    edge_end_uid(e, "topo.dst") == Some(uid)
                        && (!in_egress_only
                            || matches!(
                                e.get("topo.kind").and_then(Value::as_str),
                                Some("EGRESSES_TO" | "BORDER_HANDOFF")
                            ))
                })
                .cloned()
                .collect();
            let interfaces: Vec<Value> = self
                .nodes
                .iter()
                .find(|n| n["uid"].as_str() == Some(uid))
                .and_then(|n| n.get("device.interfaces"))
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let rev_ifaces: Vec<Value> = self
                .prefix_links
                .iter()
                .find(|p| p["uid"].as_str() == Some(uid))
                .and_then(|p| p.get("~iface.prefixes"))
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            q.push(json!({
                "uid": uid,
                "~topo.src": out_edges,
                "~topo.dst": in_edges,
                "device.interfaces": interfaces,
                "~iface.prefixes": rev_ifaces
            }));
        }
        Ok(ok_json(json!({ "q": q })))
    }

    fn handle_spof_edges(&self, query: &str) -> Result<api::Response, Status> {
        let first = parse_arg_usize(query, "first:").unwrap_or(500);
        let after = parse_arg_hex(query, "after:").unwrap_or(0);
        let canonical_only = query.contains("eq(topo.kind, \"CANONICAL_TOPOLOGY\")");
        let rows: Vec<Value> = self
            .edges
            .iter()
            .filter(|e| {
                let is_canon =
                    e.get("topo.kind").and_then(Value::as_str) == Some("CANONICAL_TOPOLOGY");
                is_canon == canonical_only && parse_uid_hex(&e["uid"]) > after
            })
            .take(first)
            .cloned()
            .collect();
        Ok(ok_json(json!({ "edges": rows })))
    }

    fn handle_spof_prefixes(&self, query: &str) -> Result<api::Response, Status> {
        let first = parse_arg_usize(query, "first:").unwrap_or(500);
        let after = parse_arg_hex(query, "after:").unwrap_or(0);
        let rows: Vec<Value> = self
            .prefix_links
            .iter()
            .filter(|p| parse_uid_hex(&p["uid"]) > after)
            .take(first)
            .cloned()
            .collect();
        Ok(ok_json(json!({ "prefixes": rows })))
    }
}

struct ServerHandle(Arc<Mutex<MockExternalDgraph>>);

#[tonic::async_trait]
impl Dgraph for ServerHandle {
    async fn login(
        &self,
        _req: Request<api::LoginRequest>,
    ) -> Result<Response<api::Response>, Status> {
        Err(Status::unimplemented("unused"))
    }
    async fn query(&self, req: Request<api::Request>) -> Result<Response<api::Response>, Status> {
        let res = self.0.lock().expect("lock").handle(req.into_inner())?;
        Ok(Response::new(res))
    }
    async fn alter(&self, _req: Request<api::Operation>) -> Result<Response<api::Payload>, Status> {
        Err(Status::unimplemented("unused"))
    }
    async fn commit_or_abort(
        &self,
        _req: Request<api::TxnContext>,
    ) -> Result<Response<api::TxnContext>, Status> {
        Ok(Response::new(api::TxnContext::default()))
    }
    async fn check_version(
        &self,
        _req: Request<api::Check>,
    ) -> Result<Response<api::Version>, Status> {
        Ok(Response::new(api::Version {
            tag: "mock-external-dgraph".into(),
        }))
    }
    async fn run_dql(
        &self,
        _req: Request<api::RunDqlRequest>,
    ) -> Result<Response<api::Response>, Status> {
        Err(Status::unimplemented("unused"))
    }
    async fn allocate_i_ds(
        &self,
        _req: Request<api::AllocateIDsRequest>,
    ) -> Result<Response<api::AllocateIDsResponse>, Status> {
        Err(Status::unimplemented("unused"))
    }
    async fn update_ext_snapshot_streaming_state(
        &self,
        _req: Request<api::UpdateExtSnapshotStreamingStateRequest>,
    ) -> Result<Response<api::UpdateExtSnapshotStreamingStateResponse>, Status> {
        Err(Status::unimplemented("unused"))
    }
    type StreamExtSnapshotStream =
        tokio_stream::Empty<Result<api::StreamExtSnapshotResponse, Status>>;
    async fn stream_ext_snapshot(
        &self,
        _req: Request<tonic::Streaming<api::StreamExtSnapshotRequest>>,
    ) -> Result<Response<Self::StreamExtSnapshotStream>, Status> {
        Err(Status::unimplemented("unused"))
    }
    async fn create_namespace(
        &self,
        _req: Request<api::CreateNamespaceRequest>,
    ) -> Result<Response<api::CreateNamespaceResponse>, Status> {
        Err(Status::unimplemented("unused"))
    }
    async fn drop_namespace(
        &self,
        _req: Request<api::DropNamespaceRequest>,
    ) -> Result<Response<api::DropNamespaceResponse>, Status> {
        Err(Status::unimplemented("unused"))
    }
    async fn list_namespaces(
        &self,
        _req: Request<api::ListNamespacesRequest>,
    ) -> Result<Response<api::ListNamespacesResponse>, Status> {
        Err(Status::unimplemented("unused"))
    }
}

async fn start_mock(
    state: MockExternalDgraph,
) -> (
    TopologyClient,
    Arc<Mutex<MockExternalDgraph>>,
    JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let shared = Arc::new(Mutex::new(state));
    let svc = ServerHandle(Arc::clone(&shared));
    let task = tokio::spawn(async move {
        tonic::transport::Server::builder()
            .add_service(DgraphServer::new(svc))
            .serve_with_incoming(TcpListenerStream::new(listener))
            .await
            .expect("serve");
    });
    let client = TopologyClient::connect(&format!("dgraph://{addr}?sslmode=disable"))
        .await
        .expect("connect");
    (client, shared, task)
}

fn ok_json(val: Value) -> api::Response {
    api::Response {
        json: serde_json::to_vec(&val).expect("json"),
        txn: Some(api::TxnContext {
            start_ts: 1,
            ..Default::default()
        }),
        ..Default::default()
    }
}

fn matches_prune(exp: Option<&str>, last_seen: Option<&str>, now: &str, fallback: &str) -> bool {
    match exp {
        Some(e) => e < now,
        None => last_seen.is_some_and(|l| l < fallback),
    }
}

fn edge_end_uid<'a>(edge: &'a Value, key: &str) -> Option<&'a str> {
    edge.get(key)?.as_array()?.first()?.get("uid")?.as_str()
}

fn parse_uid_hex(val: &Value) -> u64 {
    val.as_str()
        .and_then(|s| s.strip_prefix("0x"))
        .and_then(|s| u64::from_str_radix(s, 16).ok())
        .unwrap_or(0)
}

fn parse_arg_usize(query: &str, pat: &str) -> Option<usize> {
    let rest = query.split_once(pat)?.1.trim_start();
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

fn parse_arg_hex(query: &str, pat: &str) -> Option<u64> {
    let rest = query.split_once(pat)?.1.trim_start();
    let hex = rest.strip_prefix("0x")?;
    let digits: String = hex.chars().take_while(char::is_ascii_hexdigit).collect();
    u64::from_str_radix(&digits, 16).ok()
}

fn extract_quoted_after(query: &str, pat: &str) -> Option<String> {
    let rest = query.split_once(pat)?.1;
    let after_open = rest.split_once('"')?.1;
    let val = after_open.split_once('"')?.0;
    Some(val.to_string())
}

fn extract_bracket_list(query: &str, pat: &str) -> String {
    query
        .split_once(pat)
        .and_then(|(_, r)| r.split_once(']'))
        .map_or_else(String::new, |(l, _)| l.to_string())
}

fn ext_node(uid: &str, id: &str, kind: &str, asn: Option<i64>) -> Value {
    json!({
        "uid": uid,
        "dgraph.type": [kind],
        "ext.id": id,
        "ext.kind": kind,
        "ext.asn": asn,
        "ext.ingestor": "horizon_topology_v1",
        "ext.stale": false
    })
}

fn topo_edge(uid: &str, kind: &str, src: Value, dst: Value) -> Value {
    json!({
        "uid": uid,
        "topo.kind": kind,
        "topo.ingestor": "horizon_topology_v1",
        "topo.src": [src],
        "topo.dst": [dst]
    })
}

#[tokio::test]
async fn prune_stale_external_respects_short_and_long_ttl_and_legacy_fallback() {
    let state = MockExternalDgraph {
        edges: vec![
            json!({"uid":"0x1","topo.ingestor":"horizon_topology_v1","topo.last_seen":"2026-11-25T00:00:00Z","topo.expires_at":"2026-11-25T00:01:00Z"}),
            json!({"uid":"0x2","topo.ingestor":"horizon_topology_v1","topo.last_seen":"2026-11-25T00:00:00Z","topo.expires_at":"2026-11-25T06:00:00Z"}),
            json!({"uid":"0x3","topo.ingestor":"horizon_topology_v1","topo.last_seen":"2026-11-25T00:00:00Z"}),
        ],
        ..Default::default()
    };
    let (client, shared, task) = start_mock(state).await;

    let deleted_61s = client
        .prune_stale_external("2026-11-25T00:01:01Z")
        .await
        .expect("prune 61s");
    assert_eq!(deleted_61s, 1);
    {
        let guard = shared.lock().expect("lock");
        let remaining: Vec<&str> = guard
            .edges
            .iter()
            .map(|e| e["uid"].as_str().unwrap())
            .collect();
        assert_eq!(remaining, vec!["0x2", "0x3"]);
    }

    let deleted_16m = client
        .prune_stale_external("2026-11-25T00:16:00Z")
        .await
        .expect("prune 16m");
    assert_eq!(deleted_16m, 1);
    {
        let guard = shared.lock().expect("lock");
        let remaining: Vec<&str> = guard
            .edges
            .iter()
            .map(|e| e["uid"].as_str().unwrap())
            .collect();
        assert_eq!(remaining, vec!["0x2"]);
    }
    task.abort();
}

#[tokio::test]
async fn six_way_star_truncation_emits_zero_dangling_edges() {
    let hub = json!({"uid": "0x1", "dgraph.type": ["Device"], "device.id": "sr:hub"});
    let mut nodes = vec![hub.clone()];
    let mut edges = Vec::new();
    for i in 1..=6 {
        let uid = format!("{:#x}", 10 + i);
        let fan = ext_node(&uid, &format!("tr:fan-{i}"), "TransitRouter", Some(64512));
        edges.push(topo_edge(
            &format!("{:#x}", 100 + i),
            "TRACEROUTE_HOP",
            hub.clone(),
            fan.clone(),
        ));
        nodes.push(fan);
    }
    let (client, _shared, task) = start_mock(MockExternalDgraph {
        nodes,
        edges,
        ..Default::default()
    })
    .await;

    let br = client
        .query_blast_radius("sr:hub", 4, 3)
        .await
        .expect("blast radius");
    assert!(br.truncated);
    let node_ids: BTreeSet<String> = br
        .internal_devices
        .iter()
        .chain(&br.prefixes)
        .chain(&br.external_nodes)
        .map(|n| n.id.clone())
        .collect();
    assert_eq!(node_ids.len(), 3);
    assert_eq!(br.edges.len(), 2);
    let dangling = br
        .edges
        .iter()
        .filter(|e| !node_ids.contains(&e.src_id) || !node_ids.contains(&e.dst_id))
        .count();
    assert_eq!(dangling, 0);

    let trace = client
        .query_multi_hop_trace("sr:hub", Some("tr:fan-3"), 4, 3)
        .await
        .expect("trace");
    assert!(!trace.found);
    assert_eq!(trace.hops, 0);
    assert!(trace.nodes.is_empty());
    task.abort();
}

#[tokio::test]
async fn customer_cone_clamps_seeds_to_limit_without_dangling_edges() {
    let nodes = vec![
        ext_node("0x1", "asn:64512", "ASN", Some(64512)),
        ext_node("0x2", "asn:64513", "ASN", Some(64512)),
        ext_node("0x3", "asn:64514", "ASN", Some(64512)),
    ];
    let (client, _shared, task) = start_mock(MockExternalDgraph {
        nodes,
        ..Default::default()
    })
    .await;
    let cone = client
        .query_customer_cone("64512", 4, 2)
        .await
        .expect("cone");
    assert!(cone.truncated);
    assert!(cone.edges.is_empty());
    task.abort();
}

#[tokio::test]
async fn expand_subgraph_bridges_prefix_to_asn_via_prefix_asn() {
    let pfx = json!({"uid": "0x2", "dgraph.type": ["Prefix"], "prefix.cidr": "198.51.100.0/24", "prefix.asn": 64512});
    let dev = json!({
        "uid": "0x1",
        "dgraph.type": ["Device"],
        "device.id": "sr:edge-01",
        "device.interfaces": [{"iface.prefixes": [pfx.clone()]}]
    });
    let asn = ext_node("0x3", "asn:64512", "ASN", Some(64512));
    let saas = ext_node("0x4", "saas:crm", "SaasTarget", None);
    let edge = topo_edge("0x10", "AS_REL_PROVIDER", asn.clone(), saas.clone());

    let (client, _shared, task) = start_mock(MockExternalDgraph {
        nodes: vec![dev, pfx, asn, saas],
        edges: vec![edge],
        ..Default::default()
    })
    .await;

    let trace = client
        .query_multi_hop_trace("sr:edge-01", Some("saas:crm"), 4, 50)
        .await
        .expect("trace");
    assert!(trace.found);
    let ids: Vec<&str> = trace.nodes.iter().map(|n| n.id.as_str()).collect();
    assert_eq!(
        ids,
        vec!["sr:edge-01", "198.51.100.0/24", "asn:64512", "saas:crm"]
    );
    task.abort();
}

#[tokio::test]
async fn shared_fate_spofs_pages_past_2000_canonical_edges_and_includes_device_interface_prefix() {
    let mut edges = Vec::new();
    for i in 1..=2100usize {
        let d1 = json!({"uid": format!("{:#x}", 10_000 + i), "dgraph.type": ["Device"], "device.id": format!("sr:d{i}")});
        let d2 = json!({"uid": format!("{:#x}", 20_000 + i), "dgraph.type": ["Device"], "device.id": format!("sr:n{i}")});
        edges.push(topo_edge(
            &format!("{:#x}", i),
            "CANONICAL_TOPOLOGY",
            d1,
            d2,
        ));
    }

    let tr = ext_node("0x5001", "tr:spof", "TransitRouter", Some(64512));
    let s1 = ext_node("0x5002", "saas:1", "SaasTarget", None);
    let s2 = ext_node("0x5003", "saas:2", "SaasTarget", None);
    let pfx1 = json!({"uid": "0x5004", "dgraph.type": ["Prefix"], "prefix.cidr": "203.0.113.0/24", "prefix.asn": 64513});
    let dev1 = json!({"uid": "0x5005", "dgraph.type": ["Device"], "device.id": "sr:edge-01"});

    edges.push(topo_edge(
        "0x6001",
        "TRACEROUTE_HOP",
        pfx1.clone(),
        tr.clone(),
    ));
    edges.push(topo_edge("0x6002", "TRACEROUTE_HOP", tr.clone(), s1));
    edges.push(topo_edge("0x6003", "TRACEROUTE_HOP", tr, s2));

    let prefix_links = vec![json!({
        "uid": "0x5004",
        "dgraph.type": ["Prefix"],
        "prefix.cidr": "203.0.113.0/24",
        "prefix.asn": 64513,
        "~iface.prefixes": [{"~device.interfaces": [dev1]}]
    })];

    let (client, _shared, task) = start_mock(MockExternalDgraph {
        edges,
        prefix_links,
        ..Default::default()
    })
    .await;

    let spofs = client.query_shared_fate_spofs(2, 10).await.expect("spofs");
    assert_eq!(spofs.len(), 1);
    assert_eq!(spofs[0].id, "tr:spof");
    assert_eq!(spofs[0].target_count, 2);
    assert_eq!(spofs[0].device_count, 1);
    assert_eq!(spofs[0].devices, vec!["sr:edge-01"]);
    task.abort();
}

#[tokio::test]
async fn egress_stitch_traverses_all_four_modes_and_preserves_port_speed_mbps() {
    let dev = json!({"uid": "0x1", "dgraph.type": ["Device"], "device.id": "sr:gw-01", "device.hostname": "edge-gw-01", "device.ip": "198.51.100.1"});
    let pfx = json!({"uid": "0x2", "dgraph.type": ["Prefix"], "prefix.cidr": "198.51.100.0/24", "prefix.asn": 64512});
    let mut asn = ext_node("0x3", "asn:64512", "ASN", Some(64512));
    asn["ext.label"] = json!("AS64512");
    let mut ixp = ext_node("0x4", "ixp:501", "IXP", None);
    ixp["ext.port_speed_mbps"] = json!(100_000);
    let mut vantage = ext_node("0x5", "vantage:van-1", "Vantage", Some(64513));
    vantage["ext.ip"] = json!("203.0.113.10");
    let saas1 = ext_node("0x6", "saas:app-1", "SaasTarget", None);
    let saas2 = ext_node("0x7", "saas:app-2", "SaasTarget", None);

    let mut egress_edge = topo_edge("0x10", "EGRESSES_TO", dev.clone(), asn.clone());
    egress_edge["topo.ingestor"] = json!(EGRESS_STITCH_INGESTOR);
    egress_edge["topo.port_speed_mbps"] = json!(10_000);
    egress_edge["topo.if_name_ab"] = json!("xe-0/0/0");
    egress_edge["topo.if_index_ab"] = json!(101);
    egress_edge["topo.egress_source"] = json!("manual");

    let mut ixp_edge = topo_edge("0x11", "IXP_MEMBER", asn.clone(), ixp.clone());
    ixp_edge["topo.port_speed_mbps"] = json!(100_000);

    let edges = vec![
        egress_edge,
        ixp_edge,
        topo_edge("0x12", "TRACEROUTE_HOP", ixp.clone(), saas1.clone()),
        topo_edge("0x13", "TRACEROUTE_HOP", ixp.clone(), saas2.clone()),
        topo_edge("0x14", "EGRESSES_TO", dev.clone(), vantage.clone()),
        topo_edge("0x15", "TRACEROUTE_HOP", vantage.clone(), saas1.clone()),
        topo_edge("0x16", "TRACEROUTE_HOP", vantage.clone(), saas2.clone()),
    ];

    let prefix_links = vec![json!({
        "uid": "0x2",
        "dgraph.type": ["Prefix"],
        "prefix.cidr": "198.51.100.0/24",
        "prefix.asn": 64512,
        "~iface.prefixes": [{"iface.name": "eth0", "iface.if_index": 1, "~device.interfaces": [dev.clone()]}]
    })];

    let (client, _shared, task) = start_mock(MockExternalDgraph {
        nodes: vec![dev, pfx, asn, ixp, vantage, saas1, saas2],
        edges,
        prefix_links,
        ..Default::default()
    })
    .await;

    // 1. Blast radius from asn:64512 traverses reverse bridge_asn_prefixes -> Prefix -> Device AND EGRESSES_TO -> Device
    let br = client
        .query_blast_radius("asn:64512", 4, 50)
        .await
        .expect("blast radius");
    assert!(
        br.internal_devices.iter().any(|d| d.id == "sr:gw-01"),
        "expected sr:gw-01 in internal_devices: {:?}",
        br.internal_devices
    );
    assert!(br.prefixes.iter().any(|p| p.id == "198.51.100.0/24"));
    let ixp_ref = br
        .external_nodes
        .iter()
        .find(|n| n.id == "ixp:501")
        .expect("ixp:501");
    assert_eq!(ixp_ref.port_speed_mbps, Some(100_000));
    let egress_ref = br
        .edges
        .iter()
        .find(|e| e.kind == "EGRESSES_TO" && e.dst_id == "asn:64512")
        .expect("egresses_to edge");
    assert_eq!(egress_ref.port_speed_mbps, Some(10_000));
    assert_eq!(egress_ref.if_name.as_deref(), Some("xe-0/0/0"));
    assert_eq!(egress_ref.if_index, Some(101));
    assert_eq!(egress_ref.egress_source.as_deref(), Some("manual"));

    // 2. Shared-fate SPOFs includes EGRESSES_TO, Vantage, and ASN edge bottleneck fallback
    let spofs = client.query_shared_fate_spofs(2, 10).await.expect("spofs");
    let asn_spof = spofs
        .iter()
        .find(|s| s.id == "asn:64512")
        .expect("asn spof");
    assert_eq!(asn_spof.port_speed_mbps, Some(10_000));
    assert_eq!(asn_spof.devices, vec!["sr:gw-01"]);
    let ixp_spof = spofs.iter().find(|s| s.id == "ixp:501").expect("ixp spof");
    assert_eq!(ixp_spof.port_speed_mbps, Some(100_000));
    assert_eq!(ixp_spof.devices, vec!["sr:gw-01"]);
    let van_spof = spofs
        .iter()
        .find(|s| s.id == "vantage:van-1")
        .expect("vantage spof");
    assert_eq!(van_spof.devices, vec!["sr:gw-01"]);

    // 3. Customer cone discovers inbound Device via ~topo.dst EGRESSES_TO
    let cone = client
        .query_customer_cone("64512", 4, 50)
        .await
        .expect("customer cone");
    assert!(cone.impacted_devices.iter().any(|d| d.id == "sr:gw-01"));
    assert!(cone.saas_targets.iter().any(|t| t.id == "saas:app-1"));

    // 4. Multi-hop trace inside -> outside
    let trace = client
        .query_multi_hop_trace("sr:gw-01", Some("saas:app-1"), 4, 50)
        .await
        .expect("trace");
    assert!(trace.found);

    // 5. God View B2 query_egress_topology & query_external_egress_targets
    let egress = client
        .query_egress_topology(4, 50)
        .await
        .expect("egress topology");
    assert_eq!(egress.egress_devices.len(), 1);
    assert_eq!(egress.egress_devices[0].id, "sr:gw-01");
    assert_eq!(egress.egress_devices[0].egress_source, "manual");
    assert_eq!(egress.egress_devices[0].port_speed_mbps, Some(10_000));
    assert!(egress.external_nodes.iter().any(|n| n.id == "saas:app-1"));

    let targets = client
        .query_external_egress_targets(100)
        .await
        .expect("egress targets");
    assert_eq!(targets.prefixes.len(), 1);
    assert_eq!(targets.asns.len(), 1);
    assert_eq!(targets.vantages.len(), 1);

    task.abort();
}

#[tokio::test]
async fn prune_stale_external_preserves_egress_stitch_and_reconcile_removes_stale() {
    let dev = json!({"uid": "0x1", "dgraph.type": ["Device"], "device.id": "sr:gw-01"});
    let asn1 = ext_node("0x2", "asn:64512", "ASN", Some(64512));
    let asn2 = ext_node("0x3", "asn:64513", "ASN", Some(64513));
    let mut keep_edge = topo_edge("0x10", "EGRESSES_TO", dev.clone(), asn1.clone());
    keep_edge["topo.ingestor"] = json!(EGRESS_STITCH_INGESTOR);
    keep_edge["topo.link_key"] = json!("EGRESSES_TO|sr:gw-01|asn:64512||");
    keep_edge["topo.last_seen"] = json!("2026-11-25T00:00:00Z");

    let mut drop_edge = topo_edge("0x11", "EGRESSES_TO", dev.clone(), asn2.clone());
    drop_edge["topo.ingestor"] = json!(EGRESS_STITCH_INGESTOR);
    drop_edge["topo.link_key"] = json!("EGRESSES_TO|sr:gw-01|asn:64513||");
    drop_edge["topo.last_seen"] = json!("2026-11-25T00:00:00Z");

    let (client, shared, task) = start_mock(MockExternalDgraph {
        nodes: vec![dev, asn1, asn2],
        edges: vec![keep_edge, drop_edge],
        ..Default::default()
    })
    .await;

    let pruned = client
        .prune_stale_external("2026-11-25T06:00:00Z")
        .await
        .expect("prune");
    assert_eq!(pruned, 0);

    let removed = client
        .reconcile_egress_edges(
            &["sr:gw-01".to_string()],
            &["EGRESSES_TO|sr:gw-01|asn:64512||".to_string()],
        )
        .await
        .expect("reconcile");
    assert_eq!(removed, 1);

    let remaining: Vec<String> = shared
        .lock()
        .expect("lock")
        .edges
        .iter()
        .filter_map(|e| e["topo.link_key"].as_str().map(ToString::to_string))
        .collect();
    assert_eq!(remaining, vec!["EGRESSES_TO|sr:gw-01|asn:64512||"]);

    let _ = ExternalSnapshotWrite {
        generated_at: "2026-11-25T00:00:00Z".to_string(),
        ttl_secs: 900,
        nodes: vec![ExternalNodeWrite {
            id: "asn:64512".to_string(),
            kind: ExternalNodeKind::Asn,
            asn: Some(64_512),
            label: None,
            region: None,
            ip: None,
            rpki_state: None,
            rtbh_active: None,
            max_length: None,
            irr_status: None,
            metro: None,
            iata: None,
            country_code: None,
            outage_state: None,
            port_speed_mbps: None,
            ingestor: Some(EGRESS_STITCH_INGESTOR.to_string()),
            last_seen: "2026-11-25T00:00:00Z".to_string(),
            expires_at: None,
        }],
        edges: vec![ExternalEdgeWrite {
            src_id: "sr:gw-01".to_string(),
            dst_id: "asn:64512".to_string(),
            kind: ExternalEdgeKind::EgressesTo,
            border_asn: Some(64_512),
            as_boundary_confidence: None,
            avg_rtt_us: None,
            loss_pct: None,
            port_speed_mbps: Some(10_000),
            if_name: Some("eth0".to_string()),
            if_index: Some(1),
            egress_source: Some("manual".to_string()),
            ingestor: Some(EGRESS_STITCH_INGESTOR.to_string()),
            last_seen: "2026-11-25T00:00:00Z".to_string(),
            ttl_secs: None,
            expires_at: None,
        }],
    };
    task.abort();
}

#[tokio::test]
async fn customer_cone_prefix_attached_multihomed_device_does_not_leak_secondary_isp() {
    let asn174 = ext_node("0x1", "asn:174", "ASN", Some(174));
    let asn64512 = ext_node("0x2", "asn:64512", "ASN", Some(64512));
    let asn64599 = ext_node("0x3", "asn:64599", "ASN", Some(64599));
    let saas_cust = ext_node("0x4", "saas:64512-cust", "SaasTarget", None);
    let saas_other = ext_node("0x5", "saas:other-isp", "SaasTarget", None);
    let pfx = json!({
        "uid": "0x6",
        "dgraph.type": ["Prefix"],
        "prefix.cidr": "198.51.100.0/24",
        "prefix.asn": 64512
    });
    let dev_prefix = json!({
        "uid": "0x7",
        "dgraph.type": ["Device"],
        "device.id": "sr:gw-via-prefix"
    });
    let dev_egress = json!({
        "uid": "0x8",
        "dgraph.type": ["Device"],
        "device.id": "sr:gw-via-egress"
    });

    let edges = vec![
        topo_edge("0x10", "AS_REL_PROVIDER", asn174, asn64512.clone()),
        topo_edge("0x11", "AS_REL_PROVIDER", asn64512.clone(), saas_cust),
        topo_edge("0x12", "EGRESSES_TO", dev_egress.clone(), asn64512.clone()),
        topo_edge("0x13", "EGRESSES_TO", dev_prefix.clone(), asn64599.clone()),
        topo_edge("0x14", "EGRESSES_TO", dev_egress, asn64599.clone()),
        topo_edge("0x15", "AS_REL_PROVIDER", asn64599.clone(), saas_other),
    ];

    let prefix_links = vec![json!({
        "uid": "0x6",
        "dgraph.type": ["Prefix"],
        "prefix.cidr": "198.51.100.0/24",
        "prefix.asn": 64512,
        "~iface.prefixes": [{"~device.interfaces": [dev_prefix]}]
    })];

    let (client, _shared, task) = start_mock(MockExternalDgraph {
        nodes: vec![asn64512, asn64599, pfx],
        edges,
        prefix_links,
        ..Default::default()
    })
    .await;

    let cone = client
        .query_customer_cone("asn:64512", 4, 50)
        .await
        .expect("customer cone");

    let dev_ids: Vec<&str> = cone
        .impacted_devices
        .iter()
        .map(|d| d.id.as_str())
        .collect();
    assert!(dev_ids.contains(&"sr:gw-via-prefix"));
    assert!(dev_ids.contains(&"sr:gw-via-egress"));

    let saas_ids: Vec<&str> = cone.saas_targets.iter().map(|t| t.id.as_str()).collect();
    assert_eq!(saas_ids, vec!["saas:64512-cust"]);

    assert!(
        cone.customer_asns.is_empty(),
        "unexpected customer ASNs leaked: {:?}",
        cone.customer_asns
    );
    assert!(
        cone.edges.iter().all(|e| e.dst_id != "asn:64599"
            && e.src_id != "asn:64599"
            && e.dst_id != "saas:other-isp"),
        "unexpected secondary ISP edges leaked: {:?}",
        cone.edges
    );

    task.abort();
}

#[tokio::test]
async fn shared_fate_spofs_asn_falls_back_to_min_incident_edge_port_speed_mbps() {
    let dev = json!({"uid": "0x1", "dgraph.type": ["Device"], "device.id": "sr:gw-01"});
    let asn = ext_node("0x2", "asn:64512", "ASN", Some(64512));
    let saas1 = ext_node("0x3", "saas:1", "SaasTarget", None);
    let saas2 = ext_node("0x4", "saas:2", "SaasTarget", None);

    let mut egress_10g = topo_edge("0x10", "EGRESSES_TO", dev, asn.clone());
    egress_10g["topo.port_speed_mbps"] = json!(10_000);

    let mut provider_100g = topo_edge("0x11", "AS_REL_PROVIDER", asn.clone(), saas1);
    provider_100g["topo.port_speed_mbps"] = json!(100_000);

    let mut provider_25g = topo_edge("0x12", "AS_REL_PROVIDER", asn, saas2);
    provider_25g["topo.port_speed_mbps"] = json!(25_000);

    let (client, _shared, task) = start_mock(MockExternalDgraph {
        edges: vec![egress_10g, provider_100g, provider_25g],
        ..Default::default()
    })
    .await;

    let spofs = client.query_shared_fate_spofs(2, 10).await.expect("spofs");
    let asn_spof = spofs
        .iter()
        .find(|s| s.id == "asn:64512")
        .expect("asn spof");
    assert_eq!(asn_spof.port_speed_mbps, Some(10_000));
    assert_eq!(asn_spof.devices, vec!["sr:gw-01"]);

    task.abort();
}

#[tokio::test]
async fn egress_topology_ignores_external_border_handoffs_before_device_egresses_to() {
    let tr1 = ext_node("0x10", "transit:192.0.2.1", "TransitRouter", Some(64_500));
    let tr2 = ext_node("0x11", "transit:192.0.2.2", "TransitRouter", Some(64_501));
    let tr3 = ext_node("0x12", "transit:192.0.2.3", "TransitRouter", Some(64_502));
    let tr4 = ext_node("0x13", "transit:192.0.2.4", "TransitRouter", Some(64_503));
    let dev = json!({
        "uid": "0x1",
        "dgraph.type": ["Device"],
        "device.id": "sr:gw-01",
        "device.hostname": "edge-gw-01"
    });
    let asn = ext_node("0x2", "asn:64512", "ASN", Some(64_512));

    let mut egress = topo_edge("0x30", "EGRESSES_TO", dev, asn);
    egress["topo.egress_source"] = json!("manual");
    egress["topo.port_speed_mbps"] = json!(1_000);

    let (client, _shared, task) = start_mock(MockExternalDgraph {
        edges: vec![
            topo_edge("0x20", "BORDER_HANDOFF", tr1.clone(), tr2.clone()),
            topo_edge("0x21", "BORDER_HANDOFF", tr2.clone(), tr3.clone()),
            topo_edge("0x22", "BORDER_HANDOFF", tr3.clone(), tr4.clone()),
            topo_edge("0x23", "BORDER_HANDOFF", tr1, tr3),
            egress,
        ],
        ..Default::default()
    })
    .await;

    let res = client
        .query_egress_topology(4, 3)
        .await
        .expect("egress topology");

    assert!(!res.truncated);
    assert_eq!(res.egress_devices.len(), 1);
    assert_eq!(res.egress_devices[0].id, "sr:gw-01");
    assert_eq!(res.egress_devices[0].egress_source, "manual");
    assert_eq!(res.egress_devices[0].port_speed_mbps, Some(1_000));
    assert_eq!(res.edges.len(), 1);
    assert_eq!(res.edges[0].kind, "EGRESSES_TO");

    task.abort();
}
