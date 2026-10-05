//! Process-wide native admission, independent of BEAM caller/monitor lifetime.
//! A killed dirty-NIF caller can send DOWN while its Rust work keeps running;
//! only returning or unwinding the work releases its admission permit.

use std::sync::atomic::{AtomicUsize, Ordering};

use rustler::{Encoder, Env, Term};

pub(crate) static GRAPH_READ: Gate = Gate::new(1);
pub(crate) static WORLD_BUILD: Gate = Gate::new(1);
pub(crate) static HEALTH_BUILD: Gate = Gate::new(1);
pub(crate) static TILE_READ: Gate = Gate::new(4);
pub(crate) static BOUNDED_READ: Gate = Gate::new(16);

pub(crate) struct Gate {
    active: AtomicUsize,
    limit: usize,
}

#[derive(Debug, PartialEq, Eq)]
struct Busy;

impl Gate {
    pub(crate) const fn new(limit: usize) -> Self {
        Self {
            active: AtomicUsize::new(0),
            limit,
        }
    }

    /// Admit work that outlives the calling NIF (an async task): the permit
    /// moves into the task.
    pub(crate) fn try_acquire(&'static self) -> Option<Permit<'static>> {
        self.active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < self.limit).then_some(active + 1)
            })
            .ok()
            .map(|_| Permit(self))
    }

    fn run<T>(&self, work: impl FnOnce() -> T) -> Result<T, Busy> {
        self.active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < self.limit).then_some(active + 1)
            })
            .map_err(|_| Busy)?;
        let _permit = Permit(self);
        Ok(work())
    }
}

/// Held for as long as admitted work runs; released on drop, including during
/// unwind and when an aborted async task is dropped.
pub(crate) struct Permit<'a>(&'a Gate);

impl Drop for Permit<'_> {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::Release);
    }
}

mod atoms {
    rustler::atoms! {error, busy}
}

pub(crate) fn call<'a>(env: Env<'a>, gate: &Gate, work: impl FnOnce() -> Term<'a>) -> Term<'a> {
    match gate.run(work) {
        Ok(reply) => reply,
        Err(Busy) => (atoms::error(), atoms::busy()).encode(env),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{mpsc, Arc};
    use std::thread;

    use super::{Busy, Gate};

    #[test]
    fn native_capacity_survives_caller_retirement_until_work_finishes() {
        let gate = Arc::new(Gate::new(2));
        let mut releases = Vec::new();
        let mut finished = Vec::new();
        for _ in 0..2 {
            let gate = gate.clone();
            let (started_tx, started_rx) = mpsc::sync_channel(0);
            let (release_tx, release_rx) = mpsc::sync_channel(0);
            let (finished_tx, finished_rx) = mpsc::sync_channel(0);
            let caller = thread::spawn(move || {
                let result = gate.run(|| {
                    started_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                });
                finished_tx.send(result).unwrap();
            });
            started_rx.recv().unwrap();
            // Dropping the initiator's handle does not end its native work.
            drop(caller);
            releases.push(release_tx);
            finished.push(finished_rx);
        }
        let while_running = gate.run(|| "must not start");
        for release in releases {
            release.send(()).unwrap();
        }
        for result in finished {
            assert_eq!(result.recv().unwrap(), Ok(()));
        }
        assert_eq!(while_running, Err(Busy));
        assert_eq!(gate.run(|| "ready"), Ok("ready"));
    }

    #[test]
    fn native_failure_releases_admission_during_unwind() {
        let gate = Gate::new(1);
        let failed = std::panic::catch_unwind(|| gate.run(|| panic!("synthetic native failure")));
        assert!(failed.is_err());
        assert_eq!(gate.run(|| "recovered"), Ok("recovered"));
    }
}
