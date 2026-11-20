//! Bounded Longshore worker ownership for the ServiceRadar Rustler boundary.
//!
//! Resources own senders, never Longshore handles. The last native worker drops
//! the client and joins its I/O thread, so BEAM resource GC cannot block on I/O.

#[cfg(panic = "abort")]
compile_error!("Longshore NIF requires panic=unwind");

use crossbeam_channel::{bounded, Receiver, Sender};
use longshore_s3::client::{Budget, BuildError, Builder, Client, Error};
use longshore_s3::creds::Credentials;
use longshore_s3::report::{
    Answer, Cause, ContentRange, ETag, Encryption, End, Expect, Put, Report, ServerEncryption,
    Signed, VersionId, ETAG_MAX, VERSION_ID_MAX,
};
use longshore_s3::s3::Checksum;
use rustler::env::SavedTerm;
use rustler::types::atom;
use rustler::{
    Atom, Binary, Encoder, Env, LocalPid, NifMap, OwnedBinary, OwnedEnv, Resource, ResourceArc,
    Term,
};
use std::net::{IpAddr, SocketAddr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

mod atoms {
    rustler::atoms! {
        ok, error, busy, closed, closing, bad_config, bad_key, too_large,
        bad_range, unsupported, io_setup_failed, no_nameserver, worker_failed,
        unknown, not_found, already_exists, stored, longshore_reply,
        native_panic, allocation_failed,
        // Verified put/head/get options, budgets, expectations, and reports.
        no_clobber, encryption, checksum, aes256, other, none, crc64nvme, sha256,
        etag, version, attempts, timeout_ms,
        end, request, sent, unanswered, not_sent, answered,
        deadline, no_address, transport,
        method, date, canonical_request_sha256, signed_headers,
        status, request_id, content_length, content_range, crc64, body_len,
        body, verified, malformed, first, last, size, portable
    }
}

const MAX_CLIENTS: usize = 2;
// The kernel locks every registered native buffer, so this bounds a client's
// locked memory (RLIMIT_MEMLOCK) as well as its native buffer pool.
const MAX_REGISTERED_POOL: usize = 64 * 1024 * 1024;
const MAX_TIMEOUT_MS: u64 = 600_000;
const MAX_ATTEMPTS: u32 = 4;
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

// The large buffers the pinned Longshore registers for one I/O thread with this
// wrapper's equal connection and buffer counts (client/threads/linux.rs): the
// lent buffers, plus two TLS record buffers per connection over HTTPS, all sized
// to at least 256 KiB with TLS. Counting only the lent buffers would let a TLS
// client lock three times the bound. Each connection's 8 KiB head is additional.
fn registered_pool_bytes(concurrency: usize, buffer_size: usize, tls: bool) -> usize {
    let (record_buffers, size_floor) = if tls {
        (2 * concurrency, 256 * 1024)
    } else {
        (0, 8192)
    };
    (concurrency + record_buffers) * buffer_size.max(size_floor)
}

impl Config {
    fn builder(self, portable: bool) -> Result<Builder, Atom> {
        let address = self.host.parse::<IpAddr>().ok();
        if self.port == 0
            || !(1..=16).contains(&self.concurrency)
            || !(8192..=16 * 1024 * 1024).contains(&self.buffer_size)
            || registered_pool_bytes(self.concurrency, self.buffer_size, self.tls)
                > MAX_REGISTERED_POOL
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
        builder.portable = portable;
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
    scratch_tx: Sender<Vec<u8>>,
    scratch_rx: Receiver<Vec<u8>>,
    outstanding: Arc<AtomicUsize>,
    workers: Arc<AtomicUsize>,
    concurrency: usize,
    buffer_size: usize,
}

#[rustler::resource_impl]
impl Resource for Handle {}

impl Handle {
    fn borrow_scratch(&self, src: &[u8]) -> ScratchBuf {
        let mut bytes = self.scratch_rx.try_recv().unwrap_or_default();
        bytes.clear();
        if bytes.capacity() < src.len() {
            bytes = Vec::with_capacity(self.buffer_size);
        }
        bytes.extend_from_slice(src);
        ScratchBuf {
            bytes,
            pool: self.scratch_tx.clone(),
        }
    }
}

struct ScratchBuf {
    bytes: Vec<u8>,
    pool: Sender<Vec<u8>>,
}

impl ScratchBuf {
    fn as_slice(&self) -> &[u8] {
        &self.bytes
    }
}

impl Drop for ScratchBuf {
    fn drop(&mut self) {
        let mut bytes = std::mem::take(&mut self.bytes);
        bytes.clear();
        let _ = self.pool.try_send(bytes);
    }
}

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

#[derive(Clone, Copy)]
struct BudgetSpec {
    attempts: u32,
    timeout: Option<Duration>,
}

impl BudgetSpec {
    fn into_budget(self, admitted: Instant) -> Budget {
        match (self.attempts, self.timeout) {
            (1, Some(timeout)) => Budget::once(admitted + timeout),
            (attempts, timeout) => Budget {
                attempts,
                deadline: timeout.map(|d| admitted + d),
            },
        }
    }
}

enum Operation {
    Put(ScratchBuf),
    Fetch {
        range: Option<(u64, u64)>,
        limit: usize,
    },
    PutExact {
        bytes: ScratchBuf,
        options: Put,
        budget: Budget,
    },
    HeadExact {
        expect: Expect,
        budget: Budget,
    },
    GetExact {
        range: Option<(u64, u64)>,
        expect: Expect,
        budget: Budget,
        max_len: usize,
    },
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
    Fetched(Option<OwnedBinary>),
    Reported {
        report: Box<Report>,
        body: Option<OwnedBinary>,
    },
}

fn copy_owned_binary(bytes: &[u8]) -> Result<OwnedBinary, Atom> {
    let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::allocation_failed)?;
    binary.as_mut_slice().copy_from_slice(bytes);
    Ok(binary)
}

fn operate(client: &Client, key: &str, operation: Operation) -> Result<Outcome, Atom> {
    match operation {
        Operation::Put(bytes) => {
            let mut buffer = client.buffer_blocking();
            // A failed I/O thread can return a void buffer. Never index it.
            if buffer.is_empty() {
                return Err(atoms::closed());
            }
            let slice = bytes.as_slice();
            let len = slice.len();
            if len > buffer.as_slice().len() {
                return Err(atoms::too_large());
            }
            buffer.as_mut_slice()[..len].copy_from_slice(slice);
            drop(bytes);
            let (result, _buffer) = client.store_no_clobber(key, buffer, len).wait();
            result.map(Outcome::Stored).map_err(classify)
        }
        Operation::Fetch { range, limit } => {
            let buffer = client.buffer_blocking();
            if buffer.is_empty() {
                return Err(atoms::closed());
            }
            let pending = match range {
                Some((first, last)) => client.fetch_range(key, first, last, buffer),
                None => client.fetch(key, buffer),
            };
            let (result, buffer) = pending.wait();
            match result.map_err(classify)? {
                // TLS can round the native buffer above the requested payload
                // budget. Enforce the API limit before allocating a result copy.
                Some(n) if n > limit || n > buffer.as_slice().len() => Err(atoms::too_large()),
                Some(n) => Ok(Outcome::Fetched(Some(copy_owned_binary(
                    &buffer.as_slice()[..n],
                )?))),
                None => Ok(Outcome::Fetched(None)),
            }
        }
        Operation::PutExact {
            bytes,
            options,
            budget,
        } => {
            let mut buffer = client.buffer_blocking();
            if buffer.is_empty() {
                return Err(atoms::closed());
            }
            let slice = bytes.as_slice();
            let len = slice.len();
            if len > buffer.as_slice().len() {
                return Err(atoms::too_large());
            }
            buffer.as_mut_slice()[..len].copy_from_slice(slice);
            drop(bytes);
            let (result, _buffer) = client.put(key, buffer, len, &options, budget).wait();
            let report = result.map_err(classify_exact)?;
            Ok(Outcome::Reported {
                report: Box::new(report),
                body: None,
            })
        }
        Operation::HeadExact { expect, budget } => {
            let report = client
                .head(key, &expect, budget)
                .wait()
                .map_err(classify_exact)?;
            Ok(Outcome::Reported {
                report: Box::new(report),
                body: None,
            })
        }
        Operation::GetExact {
            range,
            expect,
            budget,
            max_len,
        } => {
            let buffer = client.buffer_blocking();
            if buffer.is_empty() {
                return Err(atoms::closed());
            }
            let (result, buffer) = client.get(key, range, &expect, buffer, budget).wait();
            let report = result.map_err(classify_exact)?;
            // A refused GET (404, 412, 403, 5xx) writes the store's error XML
            // into the buffer. Extract object bytes ONLY on 200 or 206.
            let body = match report.end {
                End::Answered(answer) if answer.status == 200 || answer.status == 206 => {
                    if buffer.is_empty() {
                        return Err(atoms::closed());
                    }
                    let len = answer.body_len as usize;
                    let allowed = match range {
                        Some((first, last)) if answer.status == 206 => (last - first + 1) as usize,
                        _ => max_len,
                    };
                    if len > allowed || len > max_len || len > buffer.as_slice().len() {
                        return Err(atoms::too_large());
                    }
                    Some(copy_owned_binary(&buffer.as_slice()[..len])?)
                }
                _ => None,
            };
            Ok(Outcome::Reported {
                report: Box::new(report),
                body,
            })
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

fn classify_exact(error: Error) -> Atom {
    match error {
        Error::BadKey => atoms::bad_key(),
        Error::BadRange => atoms::bad_range(),
        Error::TooLong => atoms::too_large(),
        Error::Closed => atoms::closed(),
        // `Client::{put,head,get}` return `Err` only when nothing was sent.
        _ => atoms::not_sent(),
    }
}

fn encode_bytes<'a>(env: Env<'a>, bytes: &[u8]) -> Result<Term<'a>, Atom> {
    let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::allocation_failed)?;
    binary.as_mut_slice().copy_from_slice(bytes);
    Ok(binary.release(env).encode(env))
}

fn encode_opt_bytes<'a>(env: Env<'a>, bytes: Option<&[u8]>) -> Result<Term<'a>, Atom> {
    match bytes {
        Some(slice) => encode_bytes(env, slice),
        None => Ok(atom::nil().encode(env)),
    }
}

fn encode_cause(cause: Cause) -> Atom {
    match cause {
        Cause::Deadline => atoms::deadline(),
        Cause::NoAddress => atoms::no_address(),
        Cause::Transport(_) => atoms::transport(),
        Cause::Closed => atoms::closed(),
    }
}

fn encode_content_range<'a>(env: Env<'a>, range: ContentRange) -> Result<Term<'a>, Atom> {
    let keys = [
        atoms::first().encode(env),
        atoms::last().encode(env),
        atoms::size().encode(env),
    ];
    let values = [
        range.first.encode(env),
        range.last.encode(env),
        range.size.encode(env),
    ];
    Term::map_from_arrays(env, &keys, &values).map_err(|_| atoms::allocation_failed())
}

fn encode_signed<'a>(env: Env<'a>, signed: &Signed) -> Result<Term<'a>, Atom> {
    let keys = [
        atoms::method().encode(env),
        atoms::date().encode(env),
        atoms::canonical_request_sha256().encode(env),
        atoms::signed_headers().encode(env),
    ];
    let values = [
        encode_bytes(env, signed.method.as_bytes())?,
        encode_bytes(env, &signed.date)?,
        encode_bytes(env, &signed.canonical_request_sha256)?,
        encode_bytes(env, signed.signed_headers.as_bytes())?,
    ];
    Term::map_from_arrays(env, &keys, &values).map_err(|_| atoms::allocation_failed())
}

fn encode_answer<'a>(
    env: Env<'a>,
    answer: &Answer,
    body: Option<OwnedBinary>,
) -> Result<Term<'a>, Atom> {
    let content_range = match answer.content_range {
        Some(range) => encode_content_range(env, range)?,
        None => atom::nil().encode(env),
    };
    let encryption = match answer.encryption {
        Some(ServerEncryption::Aes256) => atoms::aes256().encode(env),
        Some(ServerEncryption::Other) => atoms::other().encode(env),
        None => atom::nil().encode(env),
    };
    let body_term = match body {
        Some(binary) => binary.release(env).encode(env),
        None => atom::nil().encode(env),
    };
    let keys = [
        atoms::status().encode(env),
        atoms::etag().encode(env),
        atoms::version().encode(env),
        atoms::request_id().encode(env),
        atoms::content_length().encode(env),
        atoms::content_range().encode(env),
        atoms::encryption().encode(env),
        atoms::sha256().encode(env),
        atoms::crc64().encode(env),
        atoms::body_len().encode(env),
        atoms::body().encode(env),
        atoms::verified().encode(env),
        atoms::malformed().encode(env),
    ];
    let values = [
        answer.status.encode(env),
        encode_opt_bytes(env, answer.etag.as_ref().map(|v| v.as_bytes()))?,
        encode_opt_bytes(env, answer.version.as_ref().map(|v| v.as_bytes()))?,
        encode_opt_bytes(env, answer.request_id.as_ref().map(|v| v.as_bytes()))?,
        answer.content_length.encode(env),
        content_range,
        encryption,
        encode_opt_bytes(env, answer.sha256.as_ref().map(|v| v.as_slice()))?,
        encode_opt_bytes(env, answer.crc64.as_ref().map(|v| v.as_slice()))?,
        answer.body_len.encode(env),
        body_term,
        answer.verified.encode(env),
        answer.malformed.encode(env),
    ];
    Term::map_from_arrays(env, &keys, &values).map_err(|_| atoms::allocation_failed())
}

fn encode_report<'a>(
    env: Env<'a>,
    report: &Report,
    body: Option<OwnedBinary>,
) -> Result<Term<'a>, Atom> {
    let end = match &report.end {
        End::NotSent(cause) => (atoms::not_sent(), encode_cause(*cause)).encode(env),
        End::Unknown(cause) => (atoms::unknown(), encode_cause(*cause)).encode(env),
        End::Answered(answer) => (atoms::answered(), encode_answer(env, answer, body)?).encode(env),
    };
    let request = match &report.request {
        Some(signed) => encode_signed(env, signed)?,
        None => atom::nil().encode(env),
    };
    let keys = [
        atoms::end().encode(env),
        atoms::request().encode(env),
        atoms::sent().encode(env),
        atoms::unanswered().encode(env),
    ];
    let values = [
        end,
        request,
        report.sent.encode(env),
        report.unanswered.encode(env),
    ];
    Term::map_from_arrays(env, &keys, &values).map_err(|_| atoms::allocation_failed())
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
        Ok(Outcome::Fetched(Some(binary))) => (atoms::ok(), binary.release(env)).encode(env),
        Ok(Outcome::Reported { report, body }) => match encode_report(env, &report, body) {
            Ok(encoded) => (atoms::ok(), encoded).encode(env),
            Err(reason) => (atoms::error(), reason).encode(env),
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

fn start(config: Config, portable: bool) -> Result<ResourceArc<Handle>, (Atom, Option<String>)> {
    let concurrency = config.concurrency;
    let buffer_size = config.buffer_size;
    let builder = config.builder(portable).map_err(|reason| (reason, None))?;
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
        // Longshore can wrap the OS error with setup context, losing raw errno.
        // Preserve that local initialization diagnostic for operator remediation.
        BuildError::Io(error) => (atoms::io_setup_failed(), Some(error.to_string())),
    })?;
    let (sender, receiver) = bounded(concurrency);
    let (scratch_tx, scratch_rx) = bounded(concurrency);
    for _ in 0..concurrency {
        let _ = scratch_tx.try_send(Vec::new());
    }
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
        scratch_tx,
        scratch_rx,
        outstanding: Arc::new(AtomicUsize::new(0)),
        workers,
        concurrency,
        buffer_size,
    }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn open<'a>(env: Env<'a>, config: Term<'a>) -> Term<'a> {
    match catch_unwind(AssertUnwindSafe(|| {
        // NifMap decodes required fields but otherwise ignores unknown options.
        // Check the exact schema before allocating a client or native buffers:
        // 10 required fields, plus an optional boolean `portable` field.
        let portable = match config.map_size().ok() {
            Some(10) => false,
            Some(11) => config
                .map_get(atoms::portable())
                .and_then(|term| term.decode::<bool>())
                .map_err(|_| (atoms::bad_config(), None))?,
            _ => return Err((atoms::bad_config(), None)),
        };
        let config = config
            .decode::<Config>()
            .map_err(|_| (atoms::bad_config(), None))?;
        start(config, portable)
    }))
    .unwrap_or_else(|_| Err((atoms::native_panic(), None)))
    {
        Ok(handle) => (atoms::ok(), handle).encode(env),
        Err((reason, Some(detail))) => (atoms::error(), (reason, detail)).encode(env),
        Err((reason, None)) => (atoms::error(), reason).encode(env),
    }
}

fn decode_put_options<'a>(env: Env<'a>, term: Term<'a>) -> Result<Put, Atom> {
    if term.map_size().ok() != Some(3) {
        return Err(atoms::bad_config());
    }
    let no_clobber = term
        .map_get(atoms::no_clobber().encode(env))
        .and_then(|v| v.decode::<bool>())
        .map_err(|_| atoms::bad_config())?;
    let encryption_term = term
        .map_get(atoms::encryption().encode(env))
        .map_err(|_| atoms::bad_config())?;
    let encryption = if encryption_term == atom::nil().encode(env) {
        None
    } else if encryption_term == atoms::aes256().encode(env) {
        Some(Encryption::Aes256)
    } else {
        return Err(atoms::bad_config());
    };
    let checksum_term = term
        .map_get(atoms::checksum().encode(env))
        .map_err(|_| atoms::bad_config())?;
    let checksum = if checksum_term == atoms::none().encode(env) {
        Checksum::None
    } else if checksum_term == atoms::crc64nvme().encode(env) {
        Checksum::Compute
    } else if let Ok((tag, value)) = checksum_term.decode::<(Atom, Term<'a>)>() {
        if tag == atoms::crc64nvme() {
            let crc = value.decode::<u64>().map_err(|_| atoms::bad_config())?;
            Checksum::Provided(crc)
        } else if tag == atoms::sha256() {
            let bin = value
                .decode::<Binary<'a>>()
                .map_err(|_| atoms::bad_config())?;
            let digest: [u8; 32] = bin.as_slice().try_into().map_err(|_| atoms::bad_config())?;
            Checksum::Sha256(digest)
        } else {
            return Err(atoms::bad_config());
        }
    } else {
        return Err(atoms::bad_config());
    };
    Ok(Put {
        no_clobber,
        encryption,
        checksum,
    })
}

fn decode_expect<'a>(env: Env<'a>, term: Term<'a>) -> Result<Expect, Atom> {
    if term.map_size().ok() != Some(2) {
        return Err(atoms::bad_config());
    }
    let etag_term = term
        .map_get(atoms::etag().encode(env))
        .map_err(|_| atoms::bad_config())?;
    let etag = if etag_term == atom::nil().encode(env) {
        None
    } else {
        let bin = etag_term
            .decode::<Binary<'a>>()
            .map_err(|_| atoms::bad_config())?;
        let slice = bin.as_slice();
        if slice.is_empty()
            || slice.len() > ETAG_MAX
            || !slice.iter().all(|b| (b' '..=b'~').contains(b))
        {
            return Err(atoms::bad_config());
        }
        Some(ETag::new(slice).ok_or_else(atoms::bad_config)?)
    };
    let version_term = term
        .map_get(atoms::version().encode(env))
        .map_err(|_| atoms::bad_config())?;
    let version = if version_term == atom::nil().encode(env) {
        None
    } else {
        let bin = version_term
            .decode::<Binary<'a>>()
            .map_err(|_| atoms::bad_config())?;
        let slice = bin.as_slice();
        if slice.is_empty()
            || slice.len() > VERSION_ID_MAX
            || !slice.iter().all(|b| (b' '..=b'~').contains(b))
        {
            return Err(atoms::bad_config());
        }
        Some(VersionId::new(slice).ok_or_else(atoms::bad_config)?)
    };
    Ok(Expect { etag, version })
}

fn decode_timeout_ms<'a>(
    env: Env<'a>,
    term: Term<'a>,
    allow_nil: bool,
) -> Result<Option<Duration>, Atom> {
    if allow_nil && term == atom::nil().encode(env) {
        return Ok(None);
    }
    let ms = term.decode::<u64>().map_err(|_| atoms::bad_config())?;
    if !(1..=MAX_TIMEOUT_MS).contains(&ms) {
        return Err(atoms::bad_config());
    }
    Ok(Some(Duration::from_millis(ms)))
}

fn decode_budget<'a>(env: Env<'a>, term: Term<'a>) -> Result<BudgetSpec, Atom> {
    match term.map_size().ok() {
        Some(1) => {
            let timeout_term = term
                .map_get(atoms::timeout_ms().encode(env))
                .map_err(|_| atoms::bad_config())?;
            let timeout = decode_timeout_ms(env, timeout_term, false)?;
            Ok(BudgetSpec {
                attempts: 1,
                timeout,
            })
        }
        Some(2) => {
            let attempts = term
                .map_get(atoms::attempts().encode(env))
                .and_then(|v| v.decode::<u32>())
                .map_err(|_| atoms::bad_config())?;
            if !(1..=MAX_ATTEMPTS).contains(&attempts) {
                return Err(atoms::bad_config());
            }
            let timeout_term = term
                .map_get(atoms::timeout_ms().encode(env))
                .map_err(|_| atoms::bad_config())?;
            let timeout = decode_timeout_ms(env, timeout_term, true)?;
            Ok(BudgetSpec { attempts, timeout })
        }
        _ => Err(atoms::bad_config()),
    }
}

fn decode_range<'a>(
    env: Env<'a>,
    term: Term<'a>,
    buffer_size: usize,
) -> Result<Option<(u64, u64)>, Atom> {
    if term == atom::nil().encode(env) {
        return Ok(None);
    }
    let (first, last) = term
        .decode::<(u64, u64)>()
        .map_err(|_| atoms::bad_config())?;
    if last < first || last - first >= buffer_size as u64 {
        return Err(atoms::bad_range());
    }
    Ok(Some((first, last)))
}

fn submit<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    key: String,
    operation: impl FnOnce(&Handle, Instant) -> Operation,
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
    let budget_start = Instant::now();
    let op = operation(&handle, budget_start);
    let reference = env.make_ref();
    let owned = OwnedEnv::new();
    let saved = owned.save(reference);
    let admitted = Instant::now();
    let job = Job {
        key,
        operation: op,
        env: owned,
        reference: saved,
        pid: env.pid(),
        admitted,
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
    // Own just the admitted slice in a pooled scratch buffer, never a sub-binary's parent.
    submit(env, handle, key, |h, _| {
        Operation::Put(h.borrow_scratch(bytes.as_slice()))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn put_object<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    key: String,
    bytes: Binary<'a>,
    options: Term<'a>,
    budget: Term<'a>,
) -> Term<'a> {
    let options = match decode_put_options(env, options) {
        Ok(options) => options,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    let budget = match decode_budget(env, budget) {
        Ok(budget) => budget,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    if bytes.len() > handle.buffer_size {
        return (atoms::error(), atoms::too_large()).encode(env);
    }
    submit(env, handle, key, |h, admitted| Operation::PutExact {
        bytes: h.borrow_scratch(bytes.as_slice()),
        options,
        budget: budget.into_budget(admitted),
    })
}

#[rustler::nif]
fn head_object<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    key: String,
    expect: Term<'a>,
    budget: Term<'a>,
) -> Term<'a> {
    let expect = match decode_expect(env, expect) {
        Ok(expect) => expect,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    let budget = match decode_budget(env, budget) {
        Ok(budget) => budget,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    submit(env, handle, key, |_, admitted| Operation::HeadExact {
        expect,
        budget: budget.into_budget(admitted),
    })
}

#[rustler::nif]
fn get_object<'a>(
    env: Env<'a>,
    handle: ResourceArc<Handle>,
    key: String,
    range: Term<'a>,
    expect: Term<'a>,
    budget: Term<'a>,
) -> Term<'a> {
    let range = match decode_range(env, range, handle.buffer_size) {
        Ok(range) => range,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    let expect = match decode_expect(env, expect) {
        Ok(expect) => expect,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    let budget = match decode_budget(env, budget) {
        Ok(budget) => budget,
        Err(reason) => return (atoms::error(), reason).encode(env),
    };
    let max_len = handle.buffer_size;
    submit(env, handle, key, |_, admitted| Operation::GetExact {
        range,
        expect,
        budget: budget.into_budget(admitted),
        max_len,
    })
}

#[rustler::nif]
fn fetch<'a>(env: Env<'a>, handle: ResourceArc<Handle>, key: String) -> Term<'a> {
    let limit = handle.buffer_size;
    submit(env, handle, key, |_, _| Operation::Fetch {
        range: None,
        limit,
    })
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
    submit(env, handle, key, |_, _| Operation::Fetch {
        range: Some((first, last)),
        limit: (last - first + 1) as usize,
    })
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
