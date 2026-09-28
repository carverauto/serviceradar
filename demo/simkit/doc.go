// Package simkit is the deterministic simulation kit behind the ServiceRadar
// showcase demos.
//
// Plugin runs share no state, so everything simkit produces is a pure function
// of a scenario seed, an entity identity and wall-clock time: two evaluations
// of the same pack at the same instant yield identical records, and a restart
// changes nothing. The package is intentionally free of reflection, file
// access and goroutines so it compiles under TinyGo for wasip1.
//
// The pieces:
//   - Hash / Unit: seeded, stable pseudo-randomness.
//   - Minter: stable asset ids, serials, MACs and addresses.
//   - Window / CadenceDue: the run window, fine-grained back-fill, slow cadences.
//   - Wave / Counter: gauges and closed-form monotonic counters.
//   - Schedule: recurring faults, injected overrides, transitions and overlays.
//   - Source / Normalizer / Batch: the boundary between device-native
//     observations and product contracts, so a real source can replace the
//     simulator without touching the rest of a plugin.
package simkit
