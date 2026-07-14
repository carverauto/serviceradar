/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Quasi-Monte-Carlo sampler.
//!
//! Unlike [`SequentialSampler`](crate::SequentialSampler), which draws each stochastic leaf from
//! a stateful RNG, `QmcSampler` evaluates the graph against a single point of a digitally shifted
//! Sobol sequence: every non-`Point` distribution leaf is assigned a fixed dimension in a
//! deterministic pre-pass, and the sample index selects the Sobol point. Each leaf is then drawn
//! by **inverse-CDF** on its coordinate — the only transform that preserves the sequence's
//! low-discrepancy structure.
//!
//! QMC is sound only for statically-structured trees, so the pre-pass rejects `BindOp` (the
//! drawn structure would depend on a sampled value) and any `ConditionalOp` whose branches draw
//! a different set of distributions.

use crate::{
    DistributionEnum, IntoSampledValue, LogicalOperator, ProbabilisticType, SampledValue, Sampler,
    Uncertain, UncertainError, UncertainNodeContent,
};
use deep_causality_ast::ConstTree;
use deep_causality_num::Float106;
use deep_causality_rand::{
    MAX_SOBOL_DIM, SobolSequence, bernoulli_inverse_cdf, standard_normal_inverse_cdf,
    standard_normal_inverse_cdf_f106, uniform_inverse_cdf,
};
use std::collections::{HashMap, HashSet};

/// A Quasi-Monte-Carlo sampler bound to a specific computation graph's dimension layout.
#[derive(Debug, Clone)]
pub struct QmcSampler {
    sobol: SobolSequence,
    /// Stochastic-leaf node id → Sobol dimension index.
    dims: HashMap<usize, usize>,
}

impl QmcSampler {
    /// Builds a `QmcSampler` for `uncertain`'s computation graph, assigning each non-`Point`
    /// distribution leaf a stable dimension. When `seed` is `Some`, the Sobol sequence carries a
    /// seeded digital shift (reproducible randomized QMC); when `None`, it is the raw
    /// (deterministic) sequence.
    ///
    /// Returns `UncertainError::SamplingError` if the tree is not statically structured
    /// (`BindOp` or branch-divergent `ConditionalOp`), or needs more than [`MAX_SOBOL_DIM`]
    /// stochastic dimensions.
    pub fn new<T: ProbabilisticType + Copy>(
        uncertain: &Uncertain<T>,
        seed: Option<u64>,
    ) -> Result<Self, UncertainError> {
        Self::from_root_node(uncertain.root_node(), seed)
    }

    /// Core constructor over a raw computation-graph root. Crate-internal; [`Self::new`] is the
    /// public, `Uncertain`-based entry point. Kept separate so the static-structure guard can be
    /// unit-tested against node variants (e.g. `BindOp`) that no `Uncertain` builder produces.
    pub(crate) fn from_root_node(
        root: &ConstTree<UncertainNodeContent>,
        seed: Option<u64>,
    ) -> Result<Self, UncertainError> {
        let mut dims = HashMap::new();
        let mut next_dim = 0usize;
        assign_dimensions(root, &mut dims, &mut next_dim)?;

        // The sequence needs at least one dimension even when the tree has no stochastic leaves.
        let dim = next_dim.max(1);
        if dim > MAX_SOBOL_DIM {
            return Err(UncertainError::SamplingError(format!(
                "QMC supports up to {MAX_SOBOL_DIM} stochastic dimensions; this tree needs {next_dim}"
            )));
        }

        let sobol = match seed {
            Some(s) => SobolSequence::new_shifted(dim, s),
            None => SobolSequence::new(dim),
        }
        .map_err(|e| UncertainError::SamplingError(e.to_string()))?;

        Ok(Self { sobol, dims })
    }

    /// The number of stochastic dimensions assigned (the effective QMC dimension `d`).
    pub fn dimension(&self) -> usize {
        self.dims.len()
    }

    /// The `[0,1)` coordinate for the leaf `node_id` at sample `index`.
    fn coordinate(&self, node_id: usize, index: u64) -> Result<f64, UncertainError> {
        let dim = self.dims.get(&node_id).copied().ok_or_else(|| {
            UncertainError::SamplingError("QMC leaf has no assigned dimension".to_string())
        })?;
        Ok(self.sobol.coordinate(index, dim))
    }

    /// Recursively evaluates a node against the Sobol point at `index`, memoizing by node id so a
    /// shared leaf yields one draw per sample (matching `SequentialSampler`'s semantics).
    fn evaluate_node(
        &self,
        node: &ConstTree<UncertainNodeContent>,
        index: u64,
        context: &mut HashMap<usize, SampledValue>,
    ) -> Result<SampledValue, UncertainError> {
        let current_node_id = node.get_id();
        if let Some(value) = context.get(&current_node_id) {
            return Ok(*value);
        }

        let result = match node.value() {
            UncertainNodeContent::Value(v) => (*v).into_sampled_value(),
            UncertainNodeContent::DistributionF64(dist) => match dist {
                DistributionEnum::Point(v) => (*v).into_sampled_value(),
                DistributionEnum::Normal(params) => {
                    let u = self.coordinate(current_node_id, index)?;
                    let z = standard_normal_inverse_cdf(u);
                    SampledValue::Float(params.mean + params.std_dev * z)
                }
                DistributionEnum::Uniform(params) => {
                    let u = self.coordinate(current_node_id, index)?;
                    SampledValue::Float(uniform_inverse_cdf(u, params.low, params.high))
                }
                _ => {
                    return Err(UncertainError::UnsupportedTypeError(
                        "Expected f64 distribution".into(),
                    ));
                }
            },
            UncertainNodeContent::DistributionF106(dist) => match dist {
                DistributionEnum::Point(v) => (*v).into_sampled_value(),
                DistributionEnum::Normal(params) => {
                    let u = self.coordinate(current_node_id, index)?;
                    let z = standard_normal_inverse_cdf_f106(Float106::from_f64(u));
                    SampledValue::DoubleFloat(params.mean + params.std_dev * z)
                }
                DistributionEnum::Uniform(params) => {
                    let u = self.coordinate(current_node_id, index)?;
                    SampledValue::DoubleFloat(uniform_inverse_cdf(
                        Float106::from_f64(u),
                        params.low,
                        params.high,
                    ))
                }
                _ => {
                    return Err(UncertainError::UnsupportedTypeError(
                        "Expected Float106 distribution".into(),
                    ));
                }
            },
            UncertainNodeContent::DistributionBool(dist) => match dist {
                DistributionEnum::Point(v) => (*v).into_sampled_value(),
                DistributionEnum::Bernoulli(params) => {
                    let u = self.coordinate(current_node_id, index)?;
                    SampledValue::Bool(bernoulli_inverse_cdf(u, params.p))
                }
                _ => {
                    return Err(UncertainError::UnsupportedTypeError(
                        "Expected bool distribution".into(),
                    ));
                }
            },
            UncertainNodeContent::PureOp { value } => (*value).into_sampled_value(),
            UncertainNodeContent::FmapOp { func, operand } => {
                let operand_val = self.evaluate_node(operand, index, context)?;
                func.call(operand_val)
            }
            UncertainNodeContent::ApplyOp { func, arg } => {
                let arg_val = self.evaluate_node(arg, index, context)?;
                func.call(arg_val)
            }
            UncertainNodeContent::BindOp { .. } => {
                // Unreachable: the pre-pass rejects BindOp. Defensive guard.
                return Err(UncertainError::SamplingError(
                    "QMC requires a static stochastic structure: BindOp is not supported".into(),
                ));
            }
            UncertainNodeContent::ArithmeticOp { op, lhs, rhs } => {
                let lhs_val = self.evaluate_node(lhs, index, context)?;
                let rhs_val = self.evaluate_node(rhs, index, context)?;
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
                let operand_val = self.evaluate_node(operand, index, context)?;
                match operand_val {
                    SampledValue::Float(o) => SampledValue::Bool(op.apply(o, *threshold)),
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
                    match self.evaluate_node(operand_node, index, context)? {
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
                let operand_val = self.evaluate_node(operand, index, context)?;
                match operand_val {
                    SampledValue::Float(o) => SampledValue::Float(func(o)),
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
                let operand_val = self.evaluate_node(operand, index, context)?;
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
                let operand_val = self.evaluate_node(operand, index, context)?;
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
                let condition_val = match self.evaluate_node(condition, index, context)? {
                    SampledValue::Bool(b) => b,
                    _ => {
                        return Err(UncertainError::UnsupportedTypeError(
                            "Conditional condition must be boolean".into(),
                        ));
                    }
                };
                if condition_val {
                    self.evaluate_node(if_true, index, context)
                } else {
                    self.evaluate_node(if_false, index, context)
                }?
            }
        };

        context.insert(current_node_id, result);
        Ok(result)
    }
}

impl<T: ProbabilisticType> Sampler<T> for QmcSampler {
    fn sample(
        &self,
        root_node: &ConstTree<UncertainNodeContent>,
        sample_index: u64,
    ) -> Result<SampledValue, UncertainError> {
        let mut context: HashMap<usize, SampledValue> = HashMap::new();
        self.evaluate_node(root_node, sample_index, &mut context)
    }
}

/// Assigns a Sobol dimension to every non-`Point` distribution leaf, rejecting non-static
/// structure (`BindOp`, branch-divergent `ConditionalOp`).
fn assign_dimensions(
    node: &ConstTree<UncertainNodeContent>,
    dims: &mut HashMap<usize, usize>,
    next_dim: &mut usize,
) -> Result<(), UncertainError> {
    match node.value() {
        UncertainNodeContent::Value(_) | UncertainNodeContent::PureOp { .. } => Ok(()),
        UncertainNodeContent::DistributionF64(dist) => {
            assign_leaf(
                !matches!(dist, DistributionEnum::Point(_)),
                node,
                dims,
                next_dim,
            );
            Ok(())
        }
        UncertainNodeContent::DistributionF106(dist) => {
            assign_leaf(
                !matches!(dist, DistributionEnum::Point(_)),
                node,
                dims,
                next_dim,
            );
            Ok(())
        }
        UncertainNodeContent::DistributionBool(dist) => {
            assign_leaf(
                !matches!(dist, DistributionEnum::Point(_)),
                node,
                dims,
                next_dim,
            );
            Ok(())
        }
        UncertainNodeContent::FmapOp { operand, .. }
        | UncertainNodeContent::NegationOp { operand }
        | UncertainNodeContent::FunctionOpF64 { operand, .. }
        | UncertainNodeContent::FunctionOpBool { operand, .. }
        | UncertainNodeContent::ComparisonOp { operand, .. } => {
            assign_dimensions(operand, dims, next_dim)
        }
        UncertainNodeContent::ApplyOp { arg, .. } => assign_dimensions(arg, dims, next_dim),
        UncertainNodeContent::ArithmeticOp { lhs, rhs, .. } => {
            assign_dimensions(lhs, dims, next_dim)?;
            assign_dimensions(rhs, dims, next_dim)
        }
        UncertainNodeContent::LogicalOp { operands, .. } => {
            for operand in operands {
                assign_dimensions(operand, dims, next_dim)?;
            }
            Ok(())
        }
        UncertainNodeContent::BindOp { .. } => Err(UncertainError::SamplingError(
            "QMC requires a static stochastic structure: BindOp is not supported".into(),
        )),
        UncertainNodeContent::ConditionalOp {
            condition,
            if_true,
            if_false,
        } => {
            assign_dimensions(condition, dims, next_dim)?;
            assign_dimensions(if_true, dims, next_dim)?;
            assign_dimensions(if_false, dims, next_dim)?;

            let mut true_leaves = HashSet::new();
            collect_stochastic_leaves(if_true, &mut true_leaves);
            let mut false_leaves = HashSet::new();
            collect_stochastic_leaves(if_false, &mut false_leaves);
            if true_leaves != false_leaves {
                return Err(UncertainError::SamplingError(
                    "QMC requires a static stochastic structure: ConditionalOp branches draw \
                     different distributions"
                        .into(),
                ));
            }
            Ok(())
        }
    }
}

/// Assigns the next free dimension to `node` if it is a stochastic (non-`Point`) leaf.
fn assign_leaf(
    is_stochastic: bool,
    node: &ConstTree<UncertainNodeContent>,
    dims: &mut HashMap<usize, usize>,
    next_dim: &mut usize,
) {
    if is_stochastic {
        dims.entry(node.get_id()).or_insert_with(|| {
            let d = *next_dim;
            *next_dim += 1;
            d
        });
    }
}

/// Collects the node ids of every non-`Point` distribution leaf in `node`'s subtree.
fn collect_stochastic_leaves(node: &ConstTree<UncertainNodeContent>, set: &mut HashSet<usize>) {
    match node.value() {
        UncertainNodeContent::DistributionF64(dist) => {
            if !matches!(dist, DistributionEnum::Point(_)) {
                set.insert(node.get_id());
            }
        }
        UncertainNodeContent::DistributionF106(dist) => {
            if !matches!(dist, DistributionEnum::Point(_)) {
                set.insert(node.get_id());
            }
        }
        UncertainNodeContent::DistributionBool(dist) => {
            if !matches!(dist, DistributionEnum::Point(_)) {
                set.insert(node.get_id());
            }
        }
        UncertainNodeContent::Value(_) | UncertainNodeContent::PureOp { .. } => {}
        UncertainNodeContent::FmapOp { operand, .. }
        | UncertainNodeContent::NegationOp { operand }
        | UncertainNodeContent::FunctionOpF64 { operand, .. }
        | UncertainNodeContent::FunctionOpBool { operand, .. }
        | UncertainNodeContent::ComparisonOp { operand, .. } => {
            collect_stochastic_leaves(operand, set)
        }
        UncertainNodeContent::ApplyOp { arg, .. } => collect_stochastic_leaves(arg, set),
        UncertainNodeContent::BindOp { operand, .. } => collect_stochastic_leaves(operand, set),
        UncertainNodeContent::ArithmeticOp { lhs, rhs, .. } => {
            collect_stochastic_leaves(lhs, set);
            collect_stochastic_leaves(rhs, set);
        }
        UncertainNodeContent::LogicalOp { operands, .. } => {
            for operand in operands {
                collect_stochastic_leaves(operand, set);
            }
        }
        UncertainNodeContent::ConditionalOp {
            condition,
            if_true,
            if_false,
        } => {
            collect_stochastic_leaves(condition, set);
            collect_stochastic_leaves(if_true, set);
            collect_stochastic_leaves(if_false, set);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NormalDistributionParams;
    use crate::SampledBindFn;
    use std::sync::Arc;

    // `BindOp` is rejected by the static-structure guard. No `Uncertain` builder produces a
    // `BindOp` node (the public `new(&Uncertain)` entry can therefore never receive one), so this
    // defensive arm is exercised here against a hand-built tree via the crate-internal
    // `from_root_node`. The publicly reachable rejection paths (branch-divergent conditionals,
    // over-dimension trees) are covered by the integration tests.
    #[test]
    fn from_root_node_rejects_bind_op() {
        let operand = ConstTree::new(UncertainNodeContent::DistributionF64(
            DistributionEnum::Normal(NormalDistributionParams::new(0.0, 1.0)),
        ));
        let func: Arc<dyn SampledBindFn> = Arc::new(|_v: SampledValue| {
            ConstTree::new(UncertainNodeContent::Value(SampledValue::Float(0.0)))
        });
        let root = ConstTree::new(UncertainNodeContent::BindOp { func, operand });

        let err = QmcSampler::from_root_node(&root, None).unwrap_err();
        assert!(matches!(err, UncertainError::SamplingError(_)));
    }
}
