//! Bounded Longshore worker ownership for the ServiceRadar Rustler boundary.
//!
//! Resources own senders, never Longshore handles. The last native worker drops
//! the client and joins its I/O thread, so BEAM resource GC cannot block on I/O.

#[cfg(panic = "abort")]
compile_error!("Longshore NIF requires panic=unwind");

use crossbeam_channel::{bounded, Receiver, Sender};
use longshore_s3::client::{BuildError, Builder, Client, Error};
use longshore_s3::creds::Credentials;
use rustler::env::SavedTerm;
use rustler::{
    Atom, Binary, Encoder, Env, LocalPid, NifMap, OwnedBinary, OwnedEnv, Resource, ResourceArc,
    Term,
};
use std::net::{IpAddr, SocketAddr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

mod atoms {
    rustler::atoms! {
        ok, error, busy, closed, closing, bad_config, bad_key, too_large,
        bad_range, unsupported, io_setup_failed, no_nameserver, worker_failed,
        unknown, not_found, already_exists, stored, longshore_reply,
        native_panic, allocation_failed
    }
}

const MAX_CLIENTS: usize = 2;
const MAX_PAYLOAD_POOL: usize = 64 * 1024 * 1024;
static CLIENTS: AtomicUsize = AtomicUsize::new(0);

// Count a client until every worker has dropped its Longshore handle, including
// during failed initialization or after the Elixir resource has been collected.
struct ClientLease;
impl Drop for ClientLease {
    fn drop(&mut self) {
        CLIENTS.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(NifMap)]
struct Config {
    host: String,
    port: u16,
    region: String,
    bucket: Option<String>,
    access_key: String,
    secret_key: String,
    session_token: Option<String>,
    tls: bool,
    concurrency: usize,
    buffer_size: usize,
}

impl Config {
    fn builder(self) -> Result<Builder, Atom> {
        let address = self.host.parse::<IpAddr>().ok();
        if self.port == 0
            || !(1..=16).contains(&self.concurrency)
            || !(8192..=16 * 1024 * 1024).contains(&self.buffer_size)
            || self.buffer_size * self.concurrency > MAX_PAYLOAD_POOL
            || (!self.tls && !address.is_some_and(|ip| ip.is_loopback()))
        {
            return Err(atoms::bad_config());
        }
        let credentials = match self.session_token {
            Some(token) => Credentials::with_session(&self.access_key, &self.secret_key, &token),
            None => Credentials::new(&self.access_key, &self.secret_key),
        }
        .ok_or_else(atoms::bad_config)?;
        let mut builder = Builder::new(&self.host, &self.region, credentials);
        builder.port = self.port;
        builder.tls = self.tls;
        builder.bucket_in_path = self.bucket;
        builder.address = address.map(|ip| SocketAddr::new(ip, self.port));
        builder.threads = 1;
        builder.buffers = self.concurrency as u32;
        builder.connections = self.concurrency as u32;
        builder.operations = self.concurrency as u32;
        builder.buffer_size = self.buffer_size as u32;
        Ok(builder)
    }
}

pub struct Handle {
    sender: Mutex<Option<Sender<Job>>>,
    outstanding: Arc<AtomicUsize>,
    workers: Arc<AtomicUsize>,
    concurrency: usize,
    buffer_size: usize,
}

#[rustler::resource_impl]
impl Resource for Handle {}

struct Permit(Arc<AtomicUsize>);
impl Drop for Permit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

struct WorkerLease {
    count: Arc<AtomicUsize>,
    client: Option<Arc<ClientLease>>,
}
impl Drop for WorkerLease {
    fn drop(&mut self) {
        drop(self.client.take());
        self.count.fetch_sub(1, Ordering::AcqRel);
    }
}

enum Operation {
    Put(Vec<u8>),
    Fetch(Option<(u64, u64)>),
}

struct Job {
    key: String,
    operation: Operation,
    env: OwnedEnv,
    reference: SavedTerm,
    pid: LocalPid,
    admitted: Instant,
    _permit: Permit,
}

enum Outcome {
    Stored(bool),
    Fetched(Option<Vec<u8>>),
}

fn operate(client: &Client, key: &str, operation: Operation) -> Result<Outcome, Atom> {
    let mut buffer = client.buffer_blocking();
    // A failed I/O thread can return a void buffer. Never index it.
    if buffer.len() == 0 {
        return Err(atoms::closed());
    }
    match operation {
        Operation::Put(bytes) => {
            buffer.as_mut_slice()[..bytes.len()].copy_from_slice(&bytes);
            let (result, _buffer) = client.store_no_clobber(key, buffer, bytes.len()).wait();
            result.map(Outcome::Stored).map_err(classify)
        }
        Operation::Fetch(range) => {
            let pending = match range {
                Some((first, last)) => client.fetch_range(key, first, last, buffer),
                None => client.fetch(key, buffer),
            };
            let (result, buffer) = pending.wait();
            result
                .map(|length| Outcome::Fetched(length.map(|n| buffer.as_slice()[..n].to_vec())))
                .map_err(classify)
        }
    }
}

fn classify(error: Error) -> Atom {
    match error {
        Error::BadKey => atoms::bad_key(),
        Error::BadRange => atoms::bad_range(),
        Error::TooLong => atoms::too_large(),
        Error::Closed => atoms::closed(),
        // Internal retries and lost replies make a failed mutation ambiguous.
        _ => atoms::unknown(),
    }
}

fn encode_result<'a>(env: Env<'a>, result: Result<Outcome, Atom>) -> Term<'a> {
    match result {
        Ok(Outcome::Stored(created)) => (
            atoms::ok(),
            if created {
                atoms::stored()
            } else {
                atoms::already_exists()
            },
        )
            .encode(env),
        Ok(Outcome::Fetched(None)) => (atoms::ok(), atoms::not_found()).encode(env),
        Ok(Outcome::Fetched(Some(bytes))) => match OwnedBinary::new(bytes.len()) {
            Some(mut binary) => {
                binary.as_mut_slice().copy_from_slice(&bytes);
                (atoms::ok(), binary.release(env)).encode(env)
            }
            None => (atoms::error(), atoms::allocation_failed()).encode(env),
        },
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

fn worker(client: Client, receiver: Receiver<Job>, lease: WorkerLease) {
    for mut job in receiver {
        let started = Instant::now();
        let queue_us = started.duration_since(job.admitted).as_micros() as u64;
        let result = catch_unwind(AssertUnwindSafe(|| {
            operate(&client, &job.key, job.operation)
        }))
        .unwrap_or_else(|_| Err(atoms::native_panic()));
        let elapsed_us = started.elapsed().as_micros() as u64;
        // Native buffers are returned before completion becomes observable.
        // Result delivery remains bounded by the fixed worker count.
        drop(job._permit);
        let _ = job.env.send_and_clear(&job.pid, |env| {
            (
                atoms::longshore_reply(),
                job.reference.load(env),
                encode_result(env, result),
                (queue_us, elapsed_us),
            )
                .encode(env)
        });
    }
    drop(client);
    drop(lease);
}

fn start(config: Config) -> Result<ResourceArc<Handle>, (Atom, Option<i32>)> {
    let concurrency = config.concurrency;
    let buffer_size = config.buffer_size;
    let builder = config.builder().map_err(|reason| (reason, None))?;
    CLIENTS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            (n < MAX_CLIENTS).then_some(n + 1)
        })
        .map_err(|_| (atoms::busy(), None))?;
    let lease = Arc::new(ClientLease);
    let client = builder.build().map_err(|error| match error {
        BuildError::Unsupported => (atoms::unsupported(), None),
        BuildError::Setting(_) => (atoms::bad_config(), None),
        BuildError::NoNameserver => (atoms::no_nameserver(), None),
        BuildError::Io(error) => (atoms::io_setup_failed(), error.raw_os_error()),
    })?;
    let (sender, receiver) = bounded(concurrency);
    let workers = Arc::new(AtomicUsize::new(0));
    for index in 0..concurrency {
        workers.fetch_add(1, Ordering::AcqRel);
        let worker_lease = WorkerLease {
            count: workers.clone(),
            client: Some(lease.clone()),
        };
        let client = client.clone();
        let receiver = receiver.clone();
        std::thread::Builder::new()
            .name(format!("longshore-nif-{index}"))
            .spawn(move || worker(client, receiver, worker_lease))
            .map_err(|_| (atoms::worker_failed(), None))?;
    }
    Ok(ResourceArc::new(Handle {
        sender: Mutex::new(Some(sender)),
        outstanding: Arc::new(AtomicUsize::new(0)),
        workers,
        concurrency,
        buffer_size,
    }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn open(env: Env, config: Config) -> Term {
    match catch_unwind(AssertUnwindSafe(|| start(config)))
        .unwrap_or_else(|_| Err((atoms::native_panic(), None)))
    {
        Ok(handle) => (atoms::ok(), handle).encode(env),
        Err((reason, Some(errno))) => (atoms::error(), (reason, errno)).encode(env),
        Err((reason, None)) => (atoms::error(), reason).encode(env),
    }
}

fn submit<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    key: String,
    operation: impl FnOnce() -> Operation,
) -> Term<'a> {
    if key.is_empty() || key.len() > 1024 {
        return (atoms::error(), atoms::bad_key()).encode(env);
    }
    if handle
        .outstanding
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            (n < handle.concurrency).then_some(n + 1)
        })
        .is_err()
    {
        return (atoms::error(), atoms::busy()).encode(env);
    }
    let permit = Permit(handle.outstanding.clone());
    let reference = env.make_ref();
    let owned = OwnedEnv::new();
    let saved = owned.save(reference);
    let job = Job {
        key,
        operation: operation(),
        env: owned,
        reference: saved,
        pid: env.pid(),
        admitted: Instant::now(),
        _permit: permit,
    };
    let sender = handle.sender.lock().unwrap_or_else(|e| e.into_inner());
    match sender.as_ref() {
        Some(sender) if sender.try_send(job).is_ok() => (atoms::ok(), reference).encode(env),
        _ => (atoms::error(), atoms::closed()).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn put<'a>(env: Env<'a>, handle: ResourceArc<Handle>, key: String, bytes: Binary<'a>) -> Term<'a> {
    if bytes.len() > handle.buffer_size {
        return (atoms::error(), atoms::too_large()).encode(env);
    }
    // Own just the admitted slice, never a sub-binary's arbitrarily large parent.
    submit(env, handle, key, || {
        Operation::Put(bytes.as_slice().to_vec())
    })
}

#[rustler::nif]
fn fetch<'a>(env: Env<'a>, handle: ResourceArc<Handle>, key: String) -> Term<'a> {
    submit(env, handle, key, || Operation::Fetch(None))
}

#[rustler::nif]
fn fetch_range<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    key: String,
    first: u64,
    last: u64,
) -> Term<'a> {
    if last < first || last - first >= handle.buffer_size as u64 {
        return (atoms::error(), atoms::bad_range()).encode(env);
    }
    submit(env, handle, key, || Operation::Fetch(Some((first, last))))
}

#[rustler::nif]
fn close(handle: ResourceArc<Handle>) -> Atom {
    // Dropping the sender drains the admitted jobs before workers retire.
    handle
        .sender
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take();
    atoms::closing()
}

#[derive(NifMap)]
struct Info {
    accepting: bool,
    outstanding: usize,
    workers: usize,
    buffer_size: usize,
}

#[rustler::nif]
fn info(handle: ResourceArc<Handle>) -> Info {
    Info {
        accepting: handle
            .sender
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_some(),
        outstanding: handle.outstanding.load(Ordering::Acquire),
        workers: handle.workers.load(Ordering::Acquire),
        buffer_size: handle.buffer_size,
    }
}

rustler::init!("Elixir.ServiceRadarObjectStorage");
