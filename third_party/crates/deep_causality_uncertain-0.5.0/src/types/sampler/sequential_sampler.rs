/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{
    DistributionEnum, IntoSampledValue, LogicalOperator, ProbabilisticType, SampledValue, Sampler,
    UncertainError, UncertainNodeContent,
};
use deep_causality_ast::ConstTree;
use deep_causality_num::Float106;
use deep_causality_rand::Rng;
use std::collections::HashMap;

/// A basic, single-threaded sampler.
#[derive(Default)]
pub struct SequentialSampler;

// Implementation of the Sampler trait.
impl<T: ProbabilisticType> Sampler<T> for SequentialSampler {
    /// Samples a value from the given root computation node.
    ///
    /// This method initiates the sampling process by evaluating the computation graph
    /// starting from the `root_node`. It uses a `HashMap` for memoization to avoid
    /// recomputing values for the same node multiple times within a single sample operation.
    ///
    /// # Arguments
    ///
    /// * `root_node` - An `Arc` to the root `ComputationNode` of the graph to be sampled.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(SampledValue)` containing the sampled value if the sampling is successful.
    /// - `Err(UncertainError)` if an error occurs during sampling (e.g., type mismatch, distribution error).
    fn sample(
        &self,
        root_node: &ConstTree<UncertainNodeContent>,
        _sample_index: u64,
    ) -> Result<SampledValue, UncertainError> {
        // `_sample_index` is unused: this sampler draws from a stateful RNG, so the index only
        // serves as the global-cache tag (applied by the caller), not as a draw selector.
        let mut context: HashMap<usize, SampledValue> = HashMap::new();
        // Draw from the seeded RNG when `seed_sampler` is in effect on this thread, else the
        // OS-entropy thread RNG. Branching keeps each arm monomorphic over its concrete RNG.
        crate::types::sampler::sampler_seed::with_seed_slot(|slot| match slot {
            Some(rng) => self.evaluate_node(root_node, &mut context, rng),
            None => self.evaluate_node(root_node, &mut context, &mut deep_causality_rand::rng()),
        })
    }
}

#[allow(clippy::only_used_in_recursion)]
impl SequentialSampler {
    /// This function is a private helper method for SequentialSampler.
    /// Recursively evaluates a computation node and its dependencies to produce a `SampledValue`.
    ///
    /// This is a private helper method used by the `sample` method. It performs a depth-first
    /// traversal of the computation graph, evaluating each node based on its type and
    /// its children's evaluated values. It uses a `context` `HashMap` for memoization
    /// to store and retrieve already computed node values, preventing redundant calculations.
    ///
    /// # Arguments
    ///
    /// * `node` - A reference to the current `ConstTree<UncertainNodeContent<T>>` to be evaluated.
    /// * `context` - A mutable reference to a `HashMap` used for memoization. Keys are `usize`
    ///   from `ConstTree::get_id()`, and values are their `SampledValue`s.
    /// * `rng` - A mutable reference to a random number generator implementing the `rand::Rng` trait,
    ///   used for sampling from distributions.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// - `Ok(SampledValue)` containing the evaluated value of the node.
    /// - `Err(UncertainError)` if an error occurs during evaluation (e.g., type mismatch,
    ///   distribution sampling error).
    fn evaluate_node(
        &self,
        node: &ConstTree<UncertainNodeContent>,
        context: &mut HashMap<usize, SampledValue>,
        rng: &mut impl Rng,
    ) -> Result<SampledValue, UncertainError> {
        let current_node_id = node.get_id();

        if let Some(value) = context.get(&current_node_id) {
            return Ok(*value);
        }

        let result = match node.value() {
            UncertainNodeContent::Value(v) => (*v).into_sampled_value(),
            UncertainNodeContent::DistributionF64(dist) => match dist {
                DistributionEnum::Point(v) => (*v).into_sampled_value(),
                DistributionEnum::Normal(params) => SampledValue::Float(
                    (DistributionEnum::Normal(*params) as DistributionEnum<f64>).sample(rng)?,
                ),
                DistributionEnum::Uniform(params) => SampledValue::Float(
                    (DistributionEnum::Uniform(*params) as DistributionEnum<f64>).sample(rng)?,
                ),
                _ => {
                    return Err(UncertainError::UnsupportedTypeError(
                        "Expected f64 distribution".into(),
                    ));
                }
            },
            UncertainNodeContent::DistributionF106(dist) => match dist {
                DistributionEnum::Point(v) => (*v).into_sampled_value(),
                DistributionEnum::Normal(params) => SampledValue::DoubleFloat(
                    (DistributionEnum::Normal(*params) as DistributionEnum<Float106>)
                        .sample(rng)?,
                ),
                DistributionEnum::Uniform(params) => SampledValue::DoubleFloat(
                    (DistributionEnum::Uniform(*params) as DistributionEnum<Float106>)
                        .sample(rng)?,
                ),
                _ => {
                    return Err(UncertainError::UnsupportedTypeError(
                        "Expected Float106 distribution".into(),
                    ));
                }
            },
            UncertainNodeContent::DistributionBool(dist) => match dist {
                DistributionEnum::Point(v) => (*v).into_sampled_value(),
                DistributionEnum::Bernoulli(params) => SampledValue::Bool(
                    (DistributionEnum::Bernoulli(*params) as DistributionEnum<bool>).sample(rng)?,
                ),
                _ => {
                    return Err(UncertainError::UnsupportedTypeError(
                        "Expected bool distribution".into(),
                    ));
                }
            },
            UncertainNodeContent::PureOp { value } => (*value).into_sampled_value(),
            UncertainNodeContent::FmapOp { func, operand } => {
                let operand_val = self.evaluate_node(operand, context, rng)?;
                func.call(operand_val)
            }
            UncertainNodeContent::ApplyOp { func, arg } => {
                let arg_val = self.evaluate_node(arg, context, rng)?;
                func.call(arg_val)
            }
            UncertainNodeContent::BindOp { func, operand } => {
                let operand_val = self.evaluate_node(operand, context, rng)?;
                let new_tree = func.call(operand_val);
                self.evaluate_node(&new_tree, context, rng)?
            }
            UncertainNodeContent::ArithmeticOp { op, lhs, rhs } => {
                let lhs_val = self.evaluate_node(lhs, context, rng)?;
                let rhs_val = self.evaluate_node(rhs, context, rng)?;
                match (lhs_val, rhs_val) {
                    (SampledValue::Float(l), SampledValue::Float(r)) => {
                        SampledValue::Float(op.apply(l, r))
                    }
                    (SampledValue::DoubleFloat(l), SampledValue::DoubleFloat(r)) => {
                        SampledValue::DoubleFloat(op.apply(l, r))
                    }
                    _ => {
                        return Err(UncertainError::UnsupportedTypeError(
                            "Arithmetic op requires matching float inputs".into(),
                        ));
                    }
                }
            }
            UncertainNodeContent::ComparisonOp {
                op,
                threshold,
                operand,
            } => {
                let operand_val = self.evaluate_node(operand, context, rng)?;
                match operand_val {
                    SampledValue::Float(o) => SampledValue::Bool(op.apply(o, *threshold)),
                    // The threshold is f64-sourced (a documented boundary); widen it to the
                    // operand's precision so the *sample* keeps its double-double value.
                    SampledValue::DoubleFloat(o) => {
                        SampledValue::Bool(op.apply(o, Float106::from_f64(*threshold)))
                    }
                    _ => {
                        return Err(UncertainError::UnsupportedTypeError(
                            "Comparison op requires float input".into(),
                        ));
                    }
                }
            }
            UncertainNodeContent::LogicalOp { op, operands } => {
                let mut vals = Vec::with_capacity(operands.len());
                for operand_node in operands {
                    match self.evaluate_node(operand_node, context, rng)? {
                        SampledValue::Bool(b) => vals.push(b),
                        _ => {
                            return Err(UncertainError::UnsupportedTypeError(
                                "Logical op requires boolean inputs".into(),
                            ));
                        }
                    }
                }
                let result = match op {
                    LogicalOperator::Not => {
                        if vals.len() != 1 {
                            return Err(UncertainError::UnsupportedTypeError(
                                "NOT expects exactly 1 operand".into(),
                            ));
                        }
                        !vals[0]
                    }
                    LogicalOperator::And
                    | LogicalOperator::Or
                    | LogicalOperator::NOR
                    | LogicalOperator::XOR => {
                        if vals.len() != 2 {
                            return Err(UncertainError::UnsupportedTypeError(
                                "Binary logical op expects exactly 2 operands".into(),
                            ));
                        }
                        match op {
                            LogicalOperator::And => vals[0] && vals[1],
                            LogicalOperator::Or => vals[0] || vals[1],
                            LogicalOperator::NOR => !(vals[0] || vals[1]),
                            LogicalOperator::XOR => vals[0] ^ vals[1],
                            LogicalOperator::Not => unreachable!(),
                        }
                    }
                };
                SampledValue::Bool(result)
            }
            UncertainNodeContent::FunctionOpF64 { func, operand } => {
                let operand_val = self.evaluate_node(operand, context, rng)?;
                match operand_val {
                    SampledValue::Float(o) => SampledValue::Float(func(o)),
                    // User `.map` closures are f64-typed (a documented boundary): apply at
                    // f64 then re-widen, preserving representation but not sub-f64 precision.
                    SampledValue::DoubleFloat(o) => {
                        SampledValue::DoubleFloat(Float106::from_f64(func(o.to_f64())))
                    }
                    _ => {
                        return Err(UncertainError::UnsupportedTypeError(
                            "Function op requires float input".into(),
                        ));
                    }
                }
            }
            UncertainNodeContent::NegationOp { operand } => {
                let operand_val = self.evaluate_node(operand, context, rng)?;
                match operand_val {
                    SampledValue::Float(o) => SampledValue::Float(-o),
                    SampledValue::DoubleFloat(o) => SampledValue::DoubleFloat(-o),
                    _ => {
                        return Err(UncertainError::UnsupportedTypeError(
                            "Negation op requires float input".into(),
                        ));
                    }
                }
            }
            UncertainNodeContent::FunctionOpBool { func, operand } => {
                let operand_val = self.evaluate_node(operand, context, rng)?;
                match operand_val {
                    SampledValue::Float(o) => SampledValue::Bool(func(o)),
                    SampledValue::DoubleFloat(o) => SampledValue::Bool(func(o.to_f64())),
                    _ => {
                        return Err(UncertainError::UnsupportedTypeError(
                            "FunctionOpBool requires float input".into(),
                        ));
                    }
                }
            }
            UncertainNodeContent::ConditionalOp {
                condition,
                if_true,
                if_false,
            } => {
                let condition_val = match self.evaluate_node(condition, context, rng)? {
                    SampledValue::Bool(b) => b,
                    _ => {
                        return Err(UncertainError::UnsupportedTypeError(
                            "Conditional condition must be boolean".into(),
                        ));
                    }
                };

                if condition_val {
                    self.evaluate_node(if_true, context, rng)
                } else {
                    self.evaluate_node(if_false, context, rng)
                }?
            }
        };

        context.insert(current_node_id, result);
        Ok(result)
    }
}
