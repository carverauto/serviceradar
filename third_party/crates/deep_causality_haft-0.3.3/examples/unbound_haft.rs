/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_haft::{
    Bifunctor, HKT2Unbound, NoConstraint, Profunctor, Promonad, ResultUnboundWitness, Satisfies,
    Tuple3Witness,
};

fn main() {
    println!("=== DeepCausality HKT: Cybernetic Sensor Fusion ===\n");

    // ------------------------------------------------------------------------
    // Step 1: Dual-Track Processing (Bifunctor)
    //
    // ENGINEERING VALUE:
    // In complex systems, operations can fail. Standard error handling often
    // forces you to stop processing or handle errors separately.
    //
    // The Bifunctor pattern allows you to build a single pipeline that processes
    // BOTH the "Happy Path" (Data) and the "Failure Path" (Error) simultaneously.
    // This ensures that even if a sensor fails, the error is normalized and
    // formatted correctly without breaking the flow or requiring `if/else` spaghetti.
    // ------------------------------------------------------------------------
    println!("--- 1. Dual-Track Processing: Calibrate Data OR Format Error ---");

    let raw_success: Result<RawSensorData, &str> = Ok(RawSensorData {
        id: 1,
        value: 100,
        noise_level: 5,
    });
    let raw_failure: Result<RawSensorData, &str> = Err("Sensor Timeout");

    // Transformation Logic
    let calibrate = |raw: RawSensorData| CalibratedData {
        id: raw.id,
        value: raw.value as f64 * 0.98, // Calibration factor
    };
    let format_err = |e: &str| SystemError {
        code: 500,
        message: e.to_string(),
    };

    // Apply the Dual-Track Map (Bifunctor)
    // If Ok: Calibrate the data.
    // If Err: Format the error message.
    let processed_ok = ResultUnboundWitness::bimap(raw_success, calibrate, format_err);
    let processed_err = ResultUnboundWitness::bimap(raw_failure, calibrate, format_err);

    println!("Processed OK: {:?}", processed_ok);
    println!("Processed Err: {:?}", processed_err);

    // ------------------------------------------------------------------------
    // Step 2: The Adapter Pattern (Profunctor)
    //
    // ENGINEERING VALUE:
    // You often have highly optimized core algorithms (like signal processing or AI models)
    // that work on primitive types (f64, Tensor). However, your real-world data comes
    // in messy domain structs (RawSensorData).
    //
    // The Profunctor pattern creates a reusable "Adapter Layer". It wraps your
    // core algorithm, automatically unpacking the input data before it hits the core,
    // and repackaging the output result afterwards.
    //
    // This keeps your core logic pure and reusable, while the adapter handles the
    // dirty work of data integration.
    // ------------------------------------------------------------------------
    println!("\n--- 2. Adapter Pattern: Reusing Core Algorithms ---");

    // The Core Algorithm: A pure signal amplifier (f64 -> f64).
    // It knows nothing about "Sensors" or "IDs".
    let amplifier = DataProcessor(Box::new(|signal: f64| signal * 2.0));

    // The Adapter:
    // 1. Pre-processing (Input Adapter): Extracts f64 from RawSensorData.
    // 2. Post-processing (Output Adapter): Wraps the resulting f64 into CalibratedData.
    let sensor_pipeline = ProcessorWitness::dimap(
        amplifier,
        |raw: RawSensorData| raw.value as f64, // Input Adapter
        |amplified: f64| CalibratedData {
            // Output Adapter
            id: 0, // Dummy ID for example
            value: amplified,
        },
    );

    let input = RawSensorData {
        id: 42,
        value: 10,
        noise_level: 1,
    };

    // Execute the adapted pipeline
    let output = (sensor_pipeline.0)(input);
    println!("Pipeline Output: {:?}", output);
    assert_eq!(output.value, 20.0); // 10.0 * 2.0

    // ------------------------------------------------------------------------
    // Step 3: Multi-Stream Fusion (Promonad)
    //
    // ENGINEERING VALUE:
    // In avionics and robotics, you rarely rely on a single sensor. You need to
    // "fuse" data from multiple sources (e.g., 3-axis accelerometer) to get the truth.
    //
    // The Promonad pattern provides a structured way to merge multiple independent
    // data streams. It handles the complexity of combining inputs (like zipping streams)
    // so you can focus purely on the fusion logic (how to combine X, Y, and Z).
    //
    // Below, we link Step 2 and Step 3: We take raw data, run it through our
    // Adapter Pipeline (Step 2) to calibrate it, and then Fuse it (Step 3).
    // ------------------------------------------------------------------------
    println!("\n--- 3. Sensor Fusion: Calibrate & Merge Streams ---");

    // Raw Sensor X data stream (needs calibration)
    let raw_x_stream = (
        RawSensorData {
            id: 1,
            value: 5,
            noise_level: 2,
        },
        RawSensorData {
            id: 1,
            value: 6,
            noise_level: 1,
        },
        RawSensorData {
            id: 1,
            value: 7,
            noise_level: 3,
        },
    );

    // 1. CALIBRATION PHASE
    // Apply the Adapter Pipeline from Step 2 to the entire X-stream.
    let calibrate_fn = &sensor_pipeline.0;
    let calibrated_x_stream = (
        calibrate_fn(raw_x_stream.0),
        calibrate_fn(raw_x_stream.1),
        calibrate_fn(raw_x_stream.2),
    );

    println!("Calibrated Sensor X: {:?}", calibrated_x_stream);

    // Extract values for fusion (f64)
    let sensor_x = (
        calibrated_x_stream.0.value,
        calibrated_x_stream.1.value,
        calibrated_x_stream.2.value,
    );

    let sensor_y = (2.0, 2.1, 2.2); // Time series Y (already calibrated)
    let sensor_z = (3.0, 3.1, 3.2); // Time series Z (already calibrated)

    // 2. FUSION PHASE
    // Merge the independent streams (X, Y, Z) into a single coherent state.

    // First, merge X and Y streams.
    let partial_xy = Tuple3Witness::merge(sensor_x, sensor_y, |x, y| (x, y));

    // Then, merge the result with Z to create the final FusedState.
    let fused_states = Tuple3Witness::merge(partial_xy, sensor_z, |(x, y), z| {
        FusedState {
            x,
            y,
            z,
            confidence: 0.95, // Calculated confidence score
        }
    });

    println!("Fused States: {:#?}", fused_states);
}

// ============================================================================
// Domain Types: Cybernetic Sensor System
// ============================================================================

#[derive(Debug, Clone, PartialEq)]
struct RawSensorData {
    id: u32,
    value: i32,
    noise_level: u8,
}

#[derive(Debug, Clone, PartialEq)]
struct CalibratedData {
    id: u32,
    value: f64,
}

#[derive(Debug, Clone, PartialEq)]
struct SystemError {
    code: u16,
    message: String,
}

#[derive(Debug, Clone, PartialEq)]
struct FusedState {
    x: f64,
    y: f64,
    z: f64,
    confidence: f64,
}

// ============================================================================
// Profunctor: Data Adapter
// ============================================================================

// A generic data processor: Input -> Output
struct DataProcessor<I, O>(Box<dyn Fn(I) -> O>);

struct ProcessorWitness;
impl HKT2Unbound for ProcessorWitness {
    type Constraint = NoConstraint;
    type Type<A, B> = DataProcessor<A, B>;
}

impl Profunctor<ProcessorWitness> for ProcessorWitness {
    fn dimap<A, B, C, D, F1, F2>(
        pab: DataProcessor<A, B>,
        f_pre: F1,
        f_post: F2,
    ) -> DataProcessor<C, D>
    where
        A: 'static + Satisfies<NoConstraint>,
        B: 'static + Satisfies<NoConstraint>,
        C: 'static + Satisfies<NoConstraint>,
        D: 'static + Satisfies<NoConstraint>,
        F1: FnMut(C) -> A + 'static,
        F2: FnMut(B) -> D + 'static,
    {
        let inner = pab.0;
        let f_pre = std::cell::RefCell::new(f_pre);
        let f_post = std::cell::RefCell::new(f_post);

        DataProcessor(Box::new(move |c| {
            let a = (f_pre.borrow_mut())(c);
            let b = inner(a);
            (f_post.borrow_mut())(b)
        }))
    }
}
