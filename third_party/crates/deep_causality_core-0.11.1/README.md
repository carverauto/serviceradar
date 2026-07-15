[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# DeepCausality Core

[![Crates.io][crates-badge]][crates-url]
[![Docs.rs][docs-badge]][docs-url]
[![MIT licensed][mit-badge]][mit-url]
![Tests][test-url]

[crates-badge]: https://img.shields.io/badge/Crates.io-Latest-blue
[crates-url]: https://crates.io/crates/deep_causality_core
[docs-badge]: https://img.shields.io/badge/Docs.rs-Latest-blue
[docs-url]: https://docs.rs/deep_causality_core/latest/deep_causality_core/
[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg
[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE
[test-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/run_tests.yml/badge.svg

**Core types and abstractions for the [DeepCausality project](http://www.deepcausality.com).**

This crate provides the foundational building blocks for causal reasoning and effect propagation. It is the monadic foundation of the wider DeepCausality ecosystem and supports `no_std` (with `alloc`) for embedded and high-assurance systems.

### Architecture

`deep_causality_core` is built on a single, unified abstraction: a **monadic effect system** for dynamic causal
reasoning.

*   **What It Is**: A flexible, functional foundation for modeling processes using monadic types like
    `PropagatingEffect` (stateless) and `PropagatingProcess` (stateful), all built on the unified
    `CausalEffectPropagationProcess` container.
*   **Key Feature**: **Flexibility & Composability**. It allows for dynamic chaining of operations (`bind`), state
    propagation, context-awareness, and causal interventions (Pearl's do-calculus).
*   **Best For**:
    *   The foundation of the main `deep_causality` library.
    *   Complex simulations where state and context evolve.
    *   Systems that need to reason about and dynamically respond to events.
*   **Relationship**: This system is the foundation that enables the advanced causal reasoning capabilities of the wider
    DeepCausality ecosystem.

## Core Capabilities

### Causal Effect Systems
The crate defines the core types for modeling causal systems using **Monadic Effect Systems**.
*   **`CausalMonad`**: A monadic interface for chaining causal effects, allowing for composable and testable logic.
*   **`PropagatingEffect` / `PropagatingProcess`**: Types that model how effects ripple through a system, integrated with Higher-Kinded Types (HKT) via `deep_causality_haft`.
*   **`Intervenable`**: Support for causal interventions (Pearl's do-calculus) over both effect and process types.

## Feature Flags

| Feature | Default | Description |
| :--- | :--- | :--- |
| **`std`** | Yes | Enables standard library support. Suitable for servers, desktops, and research. |
| **`alloc`** | Yes | Enables heap allocation (`Vec`, `Box`). Required for `no_std` use on embedded Linux / RTOS. |

Use **default features** for general applications. For bare-metal `no_std`, disable defaults and enable only `alloc` (see [non-std Support](#non-std-support) below).

## Usage Examples

### PropagatingEffect (Stateless)

`PropagatingEffect` is a monadic container for stateless causal effects. It supports standard functional transformations (`map`, `bind`) via the `Functor` and `Monad` traits.

```rust
use deep_causality_core::{PropagatingEffect, PropagatingEffectWitness};
use deep_causality_haft::{Functor, Applicative};

fn main() {
    // Create a pure effect
    let effect = PropagatingEffectWitness::pure(10);
    
    // Transform value (Functor)
    let mapped = PropagatingEffectWitness::fmap(effect, |x| x * 2);
    
    println!("Result: {:?}", mapped.value()); // Some(20)
}
```

### PropagatingProcess (Stateful)

`PropagatingProcess` extends `PropagatingEffect` with **State** and **Context**. It allows you to model Markovian processes where each step can read/write state and access configuration context.

```rust
use deep_causality_core::{PropagatingProcess, PropagatingEffectWitness, EffectValue};
use deep_causality_haft::Applicative;

#[derive(Clone, Default, Debug)]
struct State { count: i32 }

fn main() {
    // Lift a pure effect into a stateful process
    let effect = PropagatingEffectWitness::pure(10);
    let process = PropagatingProcess::with_state(effect, State::default(), None);

    // Chain stateful computation. Value and error are one channel (`outcome`), so a step
    // builds the process with `new(Ok(..)/Err(..), state, context, logs)`.
    let next = process.bind(|val, mut state, ctx| {
        state.count += 1;
        deep_causality_core::CausalEffectPropagationProcess::new(
            Ok(EffectValue::Value(val.into_value().unwrap() + 1)),
            state,
            ctx,
            Default::default(),
        )
    });

    println!("State: {:?}", next.state()); // State { count: 1 }
}
```


### Intervention & Counterfactuals

DeepCausality Core supports **Causal Interventions** (Pearl's "Do-calculus"). You can intervene on a running process to override values and simulate counterfactual scenarios ("What if X had been Y?").

The `Intervenable` trait adds the `.intervene(value)` method to both `PropagatingEffect` and `PropagatingProcess`.

```rust
use deep_causality_core::{PropagatingEffectWitness, Intervenable};

// 1. Create a factual effect
let effect = PropagatingEffectWitness::pure(10);

// 2. Intervene to force a new value (Counterfactual)
// This preserves logs and error states but overrides the value.
let counterfactual = effect.intervene(42);
```

### CausalFlow (Fluent DSL)

`CausalFlow` is a thin, fluent facade over the causal monad. It hides the HKT witness types, the verbose `pure` / `with_state` constructors, the `EffectValue` wrapping, and the manual error short-circuit, so a pipeline reads top to bottom. Every method lowers to an existing monad operation, so the facade adds sugar, not new semantics.

```rust
use deep_causality_core::CausalFlow;

// `try_step` runs a fallible stage (`Ok` lifts a value, `Err` short-circuits),
// `map` is an infallible transform, and `finish` extracts the final value or the
// error the flow stopped on. The witness types and `EffectValue` never appear.
let outcome = CausalFlow::value(2_i64)
    .try_step(|x| Ok(x + 3))
    .map(|x| x * 10)
    .finish();

assert_eq!(outcome, Ok(50));
```

The same facade covers the whole monad surface, grouped by role:

**Construction**

| Operator | Description |
| :--- | :--- |
| `value(v)` | Start a stateless flow carrying `v`. |
| `effect()` | Start a stateless flow seeded with the unit value. |
| `fail(err)` | Start a flow already in the error channel. |
| `process(state)` | Start a stateful flow with an initial state. |
| `context(ctx)` | Attach a read-only context. |
| `From<PropagatingProcess>` | Wrap an existing monad chain. |

**Steps**

| Operator | Description |
| :--- | :--- |
| `and_then(f)` | Full monadic step; effect-returning stages adapt with `.into()`. |
| `try_step(f)` | Fallible step: `Ok` lifts a value, `Err` short-circuits. |
| `map(f)` | Infallible value transform. |
| `guard(f)` | Validate the value; `Err` short-circuits. |
| `recover(f)` | Turn the error channel back into a value. |
| `try_step_with(f)` | Stateful step with read-only state and context. |
| `step_mut(f)` | Stateful step that mutates state while transforming the value. |
| `update_value(f)` | Update the value in place; a same-type sibling of `map`. |
| `update_state(f)` | Evolve the state from the value; the value flows on. |
| `update_context(f)` | Evolve the context from the value; the value flows on. |
| `update_value_state_context(f)` | Rewrite value, state, and context together in one closure. |

**Intervention**

| Operator | Description |
| :--- | :--- |
| `intervene(value)` | Apply Pearl's `do(value)` mid-flow, recording the override in the audit log. |
| `intervene_if(cond, f)` | Intervene only when `cond` holds over the current value. |

**Terminals**

| Operator | Description |
| :--- | :--- |
| `finish()` | Extract the final value, or the error the flow stopped on, as a `Result`. |
| `run(on_ok, on_err)` | Consume the flow, dispatching by outcome. |
| `is_err()` | Whether the flow is in the error channel. |
| `into_process()` / `into_effect()` | Drop back to the concrete monad type. |

The stateless and stateful forms share one type: `CausalFlow<Value>` lowers to `PropagatingEffect`, while a non-unit `State` / `Context` lowers to `PropagatingProcess`. See the [`causal_intervention_examples`](https://github.com/deepcausality-rs/deep_causality/tree/main/examples/causal_intervention_examples) and [`causal_uncertain_examples`](https://github.com/deepcausality-rs/deep_causality/tree/main/examples/causal_uncertain_examples) crates for end-to-end pipelines built this way.

## non-std Support

To use this crate in a bare-metal `no_std` environment:

```toml
[dependencies]
deep_causality_core = { version = "...", default-features = false, features = ["alloc"] }
```

## License

This project is licensed under the [MIT license](LICENSE).

## Security

For details about security, please read the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).

