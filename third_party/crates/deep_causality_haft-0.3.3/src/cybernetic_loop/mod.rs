/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT5Unbound, Satisfies};

/// The `CyberneticLoop` trait models a complete feedback control system involving 5 distinct components.
///
/// # Category Theory
/// This models a **Feedback Loop** in a Monoidal Category, often represented using **String Diagrams**.
/// It closes the loop between Sensing, Processing, and Actuation, accounting for Entropy.
///
/// # Components
/// 1.  **Sensor ($S$)**: The raw input data.
/// 2.  **Belief ($B$)**: The internal model or state estimate.
/// 3.  **Context ($C$)**: The external configuration or laws.
/// 4.  **Action ($A$)**: The output command.
/// 5.  **Entropy ($E$)**: The error or noise in the system.
///
/// # Use Cases
/// *   **Autonomous Agents**: The OODA Loop (Observe, Orient, Decide, Act).
/// *   **Quantum Error Correction**: Syndrome Measurement ($S$) -> Decoder ($B$) -> Correction ($A$).
/// *   **Control Theory**: PID Controllers with noise estimation.
pub trait CyberneticLoop<P: HKT5Unbound> {
    /// Executes a single control step (The "OODA Loop").
    ///
    /// # Arguments
    /// * `agent`: The agent structure containing the loop logic.
    /// * `sensor_input`: The raw data observed from the environment.
    /// * `observe_fn`: Function to update Belief based on Sensor and Context ($S \times C \to B$).
    /// * `decide_fn`: Function to determine Action based on Belief and Context ($B \times C \to A$).
    ///
    /// The Context ($C$) represents the external configuration or laws of the system. It is
    /// shared (borrowed) by both the observe and decide steps rather than consumed, since a
    /// single control step is governed by one fixed context.
    ///
    /// # Returns
    /// `Result<A, E>`: The Action to take, or an Error/Entropy value if the loop fails.
    fn control_step<S, B, C, A, E, FObserve, FDecide>(
        agent: P::Type<S, B, C, A, E>,
        sensor_input: S,
        observe_fn: FObserve,
        decide_fn: FDecide,
    ) -> Result<A, E>
    where
        S: Satisfies<P::Constraint>,
        B: Satisfies<P::Constraint>,
        C: Satisfies<P::Constraint>,
        A: Satisfies<P::Constraint>,
        E: Satisfies<P::Constraint>,
        FObserve: Fn(S, &C) -> B,
        FDecide: Fn(B, &C) -> A;
}
