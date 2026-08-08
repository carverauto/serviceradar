# deep_causality_fft

Fast Fourier transforms for the DeepCausality stack: plan-based forward and
inverse transforms, generic over `RealField`, with zero external runtime
dependencies. The crate exists to give the DEC-native Navier-Stokes solver a
spectral Poisson solve on periodic lattices (the `add-fft` OpenSpec change),
but the transforms are general-purpose.

## Types

| Type | Transform |
|---|---|
| `FftPlan<R>` | 1-D complex FFT / inverse FFT, any length |
| `RfftPlan<R>` | 1-D real-to-complex (rFFT) / complex-to-real (irFFT), half-spectrum layout |
| `FftPlanNd<R>` | N-dimensional complex FFT by row-column decomposition |
| `RfftPlanNd<R>` | N-dimensional real FFT: rFFT along the last axis, complex along the rest |

`DctPlan<R>` adds plan-based discrete cosine transforms (types I, II, III,
unnormalized with `execute_inverse` applying the exact scaled inverse),
built on the rFFT core via the Makhoul (DCT-II/III) and even-extension
(DCT-I) embeddings — the building block for direct Neumann-Poisson solves
on wall-bounded uniform boxes.

`naive_dft` / `naive_idft` / `naive_dct_*` are the O(n²) correctness
references used by the test suite; the planner never selects them.

## Algorithm layering

Following the survey in `openspec/notes/fft/fft_state_of_the_art.md`:

1. **Hardcoded small-N kernels** (lengths 1–32): in-place, scratch-free
   planner base cases.
2. **Mixed radix-4/radix-2 Stockham pipeline** (powers of two above 32):
   autosorting — no bit-reversal pass — with regular, unit-stride,
   auto-vectorizable access. This is deliberately *not* flop-minimal
   split-radix; regular access wins on real hardware.
3. **Bluestein's chirp-z fallback** (every other length): the DFT as a
   circular convolution against a chirp, evaluated with the power-of-two
   core, so every length is O(N log N).

The inverse is conjugation reuse of the forward path
(`ifft(x) = conj(fft(conj(x))) / N`) — one kernel serves both directions and
the pair stays consistent by construction.

## Normalization contract

Forward transforms are unnormalized; inverse transforms scale by `1/N`
(`N` = total element count). `ifft(fft(x)) = x` to rounding.

## Plans and scratch

Plans are immutable after construction and hold all precomputed state
(twiddle tables, stage schedules, chirp sequences). Execution borrows a
caller-provided scratch buffer of `plan.scratch_len()` elements and performs
no heap allocation. Twiddles are computed directly per index (no recurrence),
so table accuracy is the scalar's `sin`/`cos` accuracy — which is what makes
the transforms meaningful at `Float106` extended precision, not just `f64`.

```rust
use deep_causality_fft::FftPlan;
use deep_causality_num::Complex;

let plan = FftPlan::<f64>::new(1024)?;
let mut data: Vec<Complex<f64>> = vec![Complex::new(0.0, 0.0); 1024];
let mut scratch = vec![Complex::new(0.0, 0.0); plan.scratch_len()];

plan.execute(&mut data, &mut scratch)?;          // forward, in place
plan.execute_inverse(&mut data, &mut scratch)?;  // back to the input
# Ok::<(), deep_causality_fft::FftError>(())
```

## The `parallel` feature

`--features parallel` enables Rayon fan-out of the independent 1-D batches
inside the N-dimensional plans (the same opt-in pattern as
`deep_causality_topology` and `deep_causality_physics`). Results are
identical to the serial path. A measured granularity threshold keeps small
transforms serial: on Apple Silicon, a 32³ pass ran 2× *slower* under an
unconditional fan-out (short lines, fork-join overhead), while 64³ gains
~1.7×; the threshold sits between the two. Parallel sections allocate
per-thread scratch; the serial path allocates nothing.

## Benchmarks

`cargo bench -p deep_causality_fft` covers 1-D lengths (16–65536 plus a
prime Bluestein size) and the 3-D solver grids. Reference numbers (Apple
Silicon, f64, serial):

| Transform | Time |
|---|---|
| 1-D forward, n = 4096 | ~25 µs |
| 1-D forward, n = 1009 (Bluestein) | ~27 µs |
| 3-D complex forward, 32³ | ~268 µs |
| 3-D real round-trip (rFFT + irFFT), 32³ | ~337 µs |
| 3-D complex forward, 64³ | ~4.8 ms (serial) / ~2.8 ms (`parallel`) |

For scale: the CG-based Leray projection this replaced on periodic lattices
dominated the 388 ms (32³) DEC solver step; with the spectral path the
projection is 1.9 ms and the full step is 137 ms serial / 57 ms parallel
(see the Taylor-Green example README for the full table).

## Safety

No `unsafe` — the crate opts into the workspace-wide
`unsafe_code = "forbid"` lint policy.

## Contribution

Contributions are welcomed especially related to documentation, example code, and fixes.
If unsure where to start, just open an issue and ask.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in deep_causality by you,
shall be licensed under the MIT licence, without any additional terms or conditions.

## Licence

This project is licensed under the [MIT license](LICENSE).

## Security

For details about security, please read
the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).

