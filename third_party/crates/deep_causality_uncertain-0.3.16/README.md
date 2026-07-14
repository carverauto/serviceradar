# deep_causality_uncertain

[![Crates.io](https://img.shields.io/crates/v/deep_causality_uncertain.svg)](https://crates.io/crates/deep_causality_uncertain)
[![Docs.rs](https://docs.rs/deep_causality_uncertain/badge.svg)](https://docs.rs/deep_causality_uncertain)

[![MIT licensed][mit-badge]][mit-url]
![Tests][test-url]

[mit-badge]: https://img.shields.io/badge/License-MIT-blue.svg

[mit-url]: https://github.com/deepcausality-rs/deep_causality/blob/main/LICENSE

[audit-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/audit.yml/badge.svg

[test-url]: https://github.com/deepcausality-rs/deep_causality/actions/workflows/run_tests.yml/badge.svg

A Rust library for first-order uncertain data types, enabling robust computation and decision-making under uncertainty.


## Introduction

In many modern applications, from sensor data processing and machine learning to probabilistic modeling, estimates are often treated as precise facts. This can lead to "uncertainty bugs" where random errors are ignored, computations compound these errors, and probabilistic data leads to misleading boolean decisions (false positives/negatives).

`deep_causality_uncertain` introduces `Uncertain<T>`, a programming language abstraction for explicitly modeling and propagating uncertainty. Inspired by the research presented in "Uncertain<T>: A First-Order Type for Uncertain Data" by Bornholt et al., this crate provides a powerful yet intuitive way to work with probabilistic data. By treating uncertainty as a first-class citizen, `Uncertain<T>` improves the expressiveness, accuracy, and correctness of applications dealing with inherent data variability.

## Key Features

*   **First-Order Uncertainty:** `Uncertain<T>` is a generic type that encapsulates a value along with its inherent uncertainty, modeled as a probability distribution.
*   **Probabilistic Presence (`MaybeUncertain<T>`):** Introduces `MaybeUncertain<T>`, a specialized type for modeling values whose very presence is uncertain. This is crucial for scenarios with sparse or intermittently available data, allowing explicit reasoning about the probability of a value existing, in addition to its inherent uncertainty if present.
*   **Rich Distribution Support:** Create uncertain values from various probability distributions, including:
    *   `Point(T)`: For precise, known values.
    *   `Normal(mean, std_dev)`: Gaussian distribution for continuous data with noise.
    *   `Uniform(low, high)`: For values within a defined range.
    *   `Bernoulli(p)`: For uncertain boolean outcomes.
*   **Intuitive Operator Overloading:** Perform standard arithmetic (`+`, `-`, `*`, `/`), unary negation (`-`), comparison (`>`, `<`, `==`), and logical (`&`, `|`, `!`, `^`) operations directly on `Uncertain` types. The uncertainty is automatically propagated through these operations.
*   **Implicit Computation Graph:** Operations on `Uncertain` types implicitly build a computation graph (similar to a Bayesian network), allowing for lazy and efficient evaluation.
*   **Sampling-Based Evaluation:** The runtime uses intelligent sampling and statistical hypothesis tests (like SPRT) to evaluate computations and conditionals lazily and efficiently, drawing only as many samples as necessary.
*   **Comprehensive Statistical Analysis:** Extract meaningful insights from uncertain results:
    *   `expected_value()`: Estimate the mean of an uncertain `f64` value.
    *   `standard_deviation()`: Estimate the spread of an uncertain `f64` value.
    *   `estimate_probability()`: Estimate the probability of an uncertain `bool` condition being true.
*   **Robust Decision Making:** Make informed decisions under uncertainty:
    *   `to_bool()`: Convert an `Uncertain<bool>` to a concrete boolean with a specified confidence.
    *   `probability_exceeds()`: Test if the probability of a condition being true exceeds a threshold.
    *   `implicit_conditional()`: A convenient method for "more likely than not" decisions.
    *   `conditional()`: Implement `if-then-else` logic where the condition itself is uncertain.
*   **Global Sample Cache:** An efficient, thread-local caching mechanism memoizes sampled values, preventing redundant computations and improving performance.

## Installation

Add `deep_causality_uncertain` to your `Cargo.toml` file:

```toml
[dependencies]
deep_causality_uncertain = "0.1.0" # Or the latest version
```

## Usage

Here are some basic examples to get started with `deep_causality_uncertain`.

### Creating Uncertain Values

```rust
use deep_causality_uncertain::Uncertain;

// A precise, known value
let precise_value = Uncertain::<f64>::point(10.0);

// A value with normal distribution (e.g., sensor reading with noise)
let noisy_sensor_reading = Uncertain::<f64>::normal(50.0, 2.5); // mean 50.0, std_dev 2.5

// A value uniformly distributed within a range
let uncertain_range = Uncertain::<f64>::uniform(0.0, 100.0);

// An uncertain boolean (e.g., outcome of a coin flip)
let coin_flip = Uncertain::<bool>::bernoulli(0.5);
```

### Arithmetic Operations

Uncertain values can be combined using standard arithmetic operators. The uncertainty is automatically propagated.

```rust
use deep_causality_uncertain::Uncertain;

let a = Uncertain::<f64>::normal(10.0, 1.0);
let b = Uncertain::<f64>::normal(5.0, 0.5);

// Addition: (10.0 +/- 1.0) + (5.0 +/- 0.5)
let sum = a + b;
println!("Expected sum: {:.2}", sum.expected_value(1000).unwrap()); // e.g., 15.00

// Subtraction
let diff = a - b;
println!("Expected difference: {:.2}", diff.expected_value(1000).unwrap()); // e.g., 5.00

// Multiplication
let product = a * b;
println!("Expected product: {:.2}", product.expected_value(1000).unwrap()); // e.g., 50.00

// Division
let quotient = a / b;
println!("Expected quotient: {:.2}", quotient.expected_value(1000).unwrap()); // e.g., 2.00

// Unary Negation
let neg_a = -a;
println!("Expected -a: {:.2}", neg_a.expected_value(1000).unwrap()); // e.g., -10.00
```

### Mapping and Transformations

Apply custom functions to uncertain values.

```rust
use deep_causality_uncertain::Uncertain;

let temperature_celsius = Uncertain::<f64>::normal(25.0, 1.0);

// Map to Fahrenheit: F = C * 1.8 + 32
let temperature_fahrenheit = temperature_celsius.map(|c| c * 1.8 + 32.0);
println!("Expected temperature in Fahrenheit: {:.2}", temperature_fahrenheit.expected_value(1000).unwrap());

// Map to a boolean condition: Is it hot? (> 30 Celsius)
let is_hot = temperature_celsius.map_to_bool(|c| c > 30.0);
println!("Probability of being hot: {:.2}%", is_hot.estimate_probability(1000).unwrap() * 100.0);
```

### Comparison Operations

Compare uncertain values or an uncertain value against a threshold. These operations return `Uncertain<bool>`.

```rust
use deep_causality_uncertain::Uncertain;

let sensor_reading = Uncertain::<f64>::normal(100.0, 5.0);
let threshold = 105.0;

// Is sensor reading greater than threshold?
let is_greater = sensor_reading.greater_than(threshold);
println!("Probability sensor reading > {}: {:.2}%", threshold, is_greater.estimate_probability(1000).unwrap() * 100.0);

let target_value = Uncertain::<f64>::normal(98.0, 3.0);
// Is sensor reading greater than another uncertain value?
let sensor_gt_target = sensor_reading.gt_uncertain(&target_value);
println!("Probability sensor reading > target: {:.2}%", sensor_gt_target.estimate_probability(1000).unwrap() * 100.0);

// Check approximate equality within a tolerance
let is_approx_100 = sensor_reading.approx_eq(100.0, 1.0); // within +/- 1.0
println!("Probability sensor reading approx 100: {:.2}%", is_approx_100.estimate_probability(1000).unwrap() * 100.0);
```

### Conditional Logic

Implement `if-then-else` logic where the condition itself is uncertain.

```rust
use deep_causality_uncertain::Uncertain;

let traffic_heavy = Uncertain::<bool>::bernoulli(0.7); // 70% chance of heavy traffic
let time_via_main_road = Uncertain::<f64>::normal(30.0, 5.0); // 30 +/- 5 min
let time_via_back_road = Uncertain::<f64>::normal(45.0, 2.0); // 45 +/- 2 min

// If traffic is heavy, take back road, else take main road
let estimated_travel_time = Uncertain::conditional(
    traffic_heavy,
    time_via_back_road,  // if traffic_heavy is true
    time_via_main_road,  // if traffic_heavy is false
);

println!("Expected travel time: {:.2} minutes", estimated_travel_time.expected_value(1000).unwrap());
```

### Statistical Properties

Calculate statistical measures of uncertain values.

```rust
use deep_causality_uncertain::Uncertain;

let stock_price = Uncertain::<f64>::normal(150.0, 10.0); // Current stock price

println!("Expected stock price: {:.2}", stock_price.expected_value(1000).unwrap());
println!("Standard deviation of stock price: {:.2}", stock_price.standard_deviation(1000).unwrap());
```

### Decision Making

Convert uncertain boolean conditions into concrete decisions.

```rust
use deep_causality_uncertain::Uncertain;

let system_healthy = Uncertain::<bool>::bernoulli(0.9); // 90% chance system is healthy

// Make a decision with 95% confidence
let decision_healthy = system_healthy.to_bool(0.95).unwrap();
if decision_healthy {
    println!("System is healthy (with 95% confidence).");
} else {
    println!("System is NOT healthy (with 95% confidence).");
}

// Implicit conditional (equivalent to probability_exceeds(0.5, 0.95, 1000))
if system_healthy.implicit_conditional().unwrap() {
    println!("System is more likely than not healthy.");
}
```

### Probabilistic Presence (`MaybeUncertain<T>`)

Model values that might be present or absent with a certain probability.

```rust
use deep_causality_uncertain::{MaybeUncertain, Uncertain, UncertainError};

// A value that is certainly present, but its value is uncertain
let certain_but_uncertain = MaybeUncertain::<f64>::from_uncertain(Uncertain::normal(10.0, 2.0));
println!("Sampled value (certainly present): {:?}", certain_but_uncertain.sample().unwrap());

// A value that is certainly absent
let certainly_absent = MaybeUncertain::<f64>::always_none();
println!("Sampled value (certainly absent): {:?}", certainly_absent.sample().unwrap());

// A value that is probabilistically present (e.g., 70% chance)
let probabilistically_present = MaybeUncertain::<f64>::from_bernoulli_and_uncertain(0.7, Uncertain::normal(5.0, 1.0));
println!("Sampled value (probabilistically present): {:?}", probabilistically_present.sample().unwrap());

// Check probability of presence
println!("Probability of being present: {:.1}%", probabilistically_present.is_some().estimate_probability(1000).unwrap() * 100.0);

// Arithmetic operations propagate None
let sum_with_absent = certain_but_uncertain.clone() + certainly_absent.clone();
println!("Sum with absent value: {:?}", sum_with_absent.sample().unwrap());

// Lift to Uncertain<T> if evidence of presence is sufficient
match probabilistically_present.lift_to_uncertain(0.6, 0.95, 0.05, 1000) {
    Ok(uncertain_value) => println!("Lifted to Uncertain<f64>: Expected value {:.2}", uncertain_value.expected_value(1000).unwrap()),
    Err(e) => println!("Failed to lift: {}", e),
}
```

## More Examples

For more complex and real-world scenarios, refer to the `examples` directory:

*   **GPS Navigation (`example_gps_navigation.rs`)**: Simulates GPS readings, propagates uncertainty through distance and time calculations, and makes route decisions.
  
*   **Sensor Data Processing (`example_sensor_processing.rs`)**: Demonstrates robust sensor data processing with error handling, sensor fusion, and anomaly detection under uncertainty.

*   **Aspirin Headache Trial Analysis (`example_clinical_trial.rs`)**: Demonstrates using `MaybeUncertain<T>` to model clinical trial data with probabilistic presence, analyzing drug effectiveness under uncertainty.

To run an example:

```bash
cargo run --example example_gps_navigation 

cargo run --example example_sensor_processing 

cargo run --example example_clinical_trial 
```

## Benchmarks

```bash
cargo bench -p deep_causality_uncertain --bench maybe_uncertain_benchmarks

cargo bench -p deep_causality_uncertain --bench uncertain_benchmarks
```

## Acknowledgements

This crate is inspired by the Blog post ["Uncertain⟨T⟩"](https://nshipster.com/uncertainty) by [@Mattt](https://github.com/mattt) and his Implementation of [Uncertain for Swift](https://github.com/mattt/Uncertain).
Furthermore, prior art in the [uncertain crate](https://crates.io/crates/uncertain) and [uncertain-rs](https://crates.io/crates/uncertain-rs) crate inspired some of the implementation and examples. 

The Uncertain⟨T⟩ type is based by the foundational research presented in:

*   Bornholt, J., Mytkowicz, T., & McKinley, K. S. (2014). [**Uncertain<T>: A First-Order Type for Uncertain Data**.](https://www.microsoft.com/en-us/research/publication/uncertaint-a-first-order-type-for-uncertain-data-2) *Proceedings of the 19th International Conference on Architectural Support for Programming Languages and Operating Systems (ASPLOS '14)*. ACM, New York, NY, USA, 123-136. ([Download Paper](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/asplos077-bornholtA.pdf))

## Contributing

Contributions are welcome! Please refer to the [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License. See the [LICENSE](../LICENSE) file for details.

## 💻 Author

* [Marvin Hansen](https://github.com/marvin-hansen).
* Github GPG key ID: 369D5A0B210D39BC
* GPG Fingerprint: 4B18 F7B2 04B9 7A72 967E 663E 369D 5A0B 210D 39BC