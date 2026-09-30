//! Executes the shared, pinned ELK JavaScript in an isolated native runtime.
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use rquickjs::{Context, Function, Runtime};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::Error;

const BUNDLE: &str = include_str!("../../../js/topology-layout/elk_layout.bundle.js");
const MAX_NODES: usize = 512;
const CACHE_ENTRIES: usize = 128;
type Points = Vec<(usize, f64, f64)>;

pub(crate) struct Elk {
    runtime: Runtime,
    context: Context,
    deadline: Instant,
    cache: RefCell<HashMap<[u8; 32], Points>>,
}

impl Elk {
    pub(crate) fn new() -> Result<Self, Error> {
        let runtime = Runtime::new().map_err(|_| Error::LayoutUnavailable)?;
        runtime.set_memory_limit(268_435_456);
        runtime.set_max_stack_size(8_388_608);
        let deadline = Instant::now() + Duration::from_secs(600);
        runtime.set_interrupt_handler(Some(Box::new(move || Instant::now() >= deadline)));
        let context = Context::full(&runtime).map_err(|_| Error::LayoutUnavailable)?;
        context
            .with(|ctx| ctx.eval::<(), _>(BUNDLE))
            .map_err(|_| Error::LayoutUnavailable)?;
        Ok(Self {
            runtime,
            context,
            deadline,
            cache: RefCell::new(HashMap::new()),
        })
    }

    pub(crate) fn layout(&self, nodes: &[Value], edges: &[Value]) -> Result<Points, Error> {
        if nodes.is_empty() || nodes.len() > MAX_NODES || edges.len() >= MAX_NODES {
            return Err(Error::LayoutUnavailable);
        }
        // Geometry templates contain local ordinals, never inventory identity.
        let ids: Vec<usize> = nodes
            .iter()
            .map(|n| {
                n["id"]
                    .as_str()
                    .and_then(|id| id.parse().ok())
                    .ok_or(Error::LayoutUnavailable)
            })
            .collect::<Result<_, _>>()?;
        let ordinals: HashMap<_, _> = ids
            .iter()
            .enumerate()
            .map(|(n, id)| (id.to_string(), n))
            .collect();
        if ordinals.len() != nodes.len() {
            return Err(Error::LayoutUnavailable);
        }
        let children: Vec<_> = nodes
            .iter()
            .enumerate()
            .map(|(n, node)| {
                let mut node = node.clone();
                node["id"] = json!(n.to_string());
                node
            })
            .collect();
        let edges: Vec<_> = edges.iter().enumerate().map(|(n, edge)| {
            let endpoint = |field: &str| -> Result<String, Error> {
                let id = edge[field][0].as_str().ok_or(Error::LayoutUnavailable)?;
                ordinals.get(id).map(|n| n.to_string()).ok_or(Error::LayoutUnavailable)
            };
            Ok(json!({"id": n.to_string(), "sources": [endpoint("sources")?], "targets": [endpoint("targets")?]}))
        }).collect::<Result<_, Error>>()?;
        let diagonals: Vec<_> = nodes
            .iter()
            .map(|n| {
                let width = n["width"]
                    .as_f64()
                    .filter(|w| w.is_finite() && *w > 0.0)
                    .ok_or(Error::LayoutUnavailable)?;
                let height = n["height"]
                    .as_f64()
                    .filter(|h| h.is_finite() && *h > 0.0)
                    .ok_or(Error::LayoutUnavailable)?;
                Ok(width.hypot(height))
            })
            .collect::<Result<_, Error>>()?;
        let radius = 224.0_f64
            .max(diagonals.iter().sum::<f64>() / std::f64::consts::TAU * 1.2)
            .max(diagonals.into_iter().fold(0.0, f64::max));
        let mut input = json!({"nodes": children, "edges": edges, "radius": radius});
        let key: [u8; 32] = Sha256::digest(input.to_string().as_bytes()).into();
        let translate = |points: &Points| points.iter().map(|&(n, x, y)| (ids[n], x, y)).collect();
        if let Some(points) = self.cache.borrow().get(&key) {
            return Ok(translate(points));
        }
        let mut accepted = None;
        for attempt in 0..4 {
            input["radius"] = json!(radius * f64::from(1 << attempt));
            let points = self.execute(input.to_string())?;
            let ordinals: HashSet<_> = points.iter().map(|p| p.0).collect();
            if points.len() != ids.len()
                || ordinals.len() != ids.len()
                || ordinals.iter().any(|&n| n >= ids.len())
            {
                return Err(Error::LayoutUnavailable);
            }
            let overlap = points.iter().enumerate().any(|(i, &(a, ax, ay))| {
                points[..i].iter().any(|&(b, bx, by)| {
                    let width = (nodes[a]["width"].as_f64().unwrap()
                        + nodes[b]["width"].as_f64().unwrap())
                        / 2.0;
                    let height = (nodes[a]["height"].as_f64().unwrap()
                        + nodes[b]["height"].as_f64().unwrap())
                        / 2.0;
                    (ax - bx).abs() < width - 0.01 && (ay - by).abs() < height - 0.01
                })
            });
            if !overlap {
                accepted = Some(points);
                break;
            }
        }
        let points = accepted.ok_or(Error::LayoutUnavailable)?;
        let result = translate(&points);
        let mut cache = self.cache.borrow_mut();
        if cache.len() == CACHE_ENTRIES {
            cache.clear();
        }
        cache.insert(key, points);
        Ok(result)
    }

    fn execute(&self, input: String) -> Result<Points, Error> {
        self.context
            .with(|ctx| {
                ctx.globals().set("__srInput", input)?;
                let argument = ctx.eval::<rquickjs::Value, _>("JSON.parse(__srInput)")?;
                ctx.globals()
                    .get::<_, Function>("__srLayout")?
                    .call::<_, ()>((argument,))
            })
            .map_err(|_| Error::LayoutUnavailable)?;
        loop {
            if Instant::now() >= self.deadline {
                return Err(Error::LayoutUnavailable);
            }
            let (result, failure) = self
                .context
                .with(|ctx| {
                    Ok::<_, rquickjs::Error>((
                        ctx.globals().get::<_, Option<String>>("__srResult")?,
                        ctx.globals().get::<_, Option<String>>("__srFailure")?,
                    ))
                })
                .map_err(|_| Error::LayoutUnavailable)?;
            if failure.is_some() {
                return Err(Error::LayoutUnavailable);
            }
            if let Some(result) = result {
                let rows: Vec<Value> =
                    serde_json::from_str(&result).map_err(|_| Error::LayoutUnavailable)?;
                return rows
                    .into_iter()
                    .map(|row| {
                        let id = row["id"]
                            .as_str()
                            .and_then(|id| id.parse().ok())
                            .ok_or(Error::LayoutUnavailable)?;
                        let coordinate = |field: &str| {
                            row[field]
                                .as_f64()
                                .filter(|v| v.is_finite())
                                .ok_or(Error::LayoutUnavailable)
                        };
                        Ok((id, coordinate("x")?, coordinate("y")?))
                    })
                    .collect();
            }
            let timers = self
                .context
                .with(|ctx| ctx.eval::<bool, _>("__srDrain()"))
                .map_err(|_| Error::LayoutUnavailable)?;
            let mut jobs = false;
            while self
                .runtime
                .execute_pending_job()
                .map_err(|_| Error::LayoutUnavailable)?
            {
                jobs = true;
            }
            if !timers && !jobs {
                let done = self
                    .context
                    .with(|ctx| ctx.globals().get::<_, Option<String>>("__srResult"))
                    .map_err(|_| Error::LayoutUnavailable)?;
                if done.is_none() {
                    return Err(Error::LayoutUnavailable);
                }
            }
        }
    }
}
