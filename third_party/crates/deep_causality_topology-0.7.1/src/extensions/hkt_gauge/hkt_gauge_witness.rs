/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{GaugeField, GaugeGroup, TopologyError};
use deep_causality_algebra::Field;
use deep_causality_algebra::RealField;
use deep_causality_haft::{HKT3Unbound, MonoidalMerge, NoConstraint, ParametricMonad, Satisfies};
use deep_causality_tensor::CausalTensor;
use std::marker::PhantomData;

/// HKT3 witness for GaugeField<G, A, F>.
///
/// This witness enables GaugeField to participate in HKT3 operations
/// like MonoidalMerge (merging contexts) and ParametricMonad (indexed state transitions).
///
/// # Type Structure
///
/// GaugeField<G, A, F> where:
/// - G: Gauge group (determines symmetry)
/// - A: Connection type (gauge potential)
/// - F: Field strength type (curvature)
///
/// # Important
///
/// Due to Rust's type system limitations, the HKT3Unbound implementation
/// uses NoConstraint, but actual GaugeField construction enforces G: GaugeGroup.
#[derive(Debug, Clone, Copy, Default)]
pub struct GaugeFieldWitness<T>(PhantomData<T>);

/// Wrapper type for GaugeField that can be used with HKT3Unbound.
///
/// This wrapper exists because GaugeField<G, A, F> requires G: GaugeGroup,
/// but HKT3Unbound expects Type<A, B, C> without extra bounds.
///
/// # Implementation Note
///
/// This wrapper stores the actual GaugeField data as a type-erased Box.
/// The HKT trait methods use **unsafe dispatch** to convert between generic
/// types and concrete GaugeField instances.
///
/// **SAFETY:** Callers MUST ensure that the generic types match the stored
/// GaugeField's type parameters. Misuse causes Undefined Behavior.
#[derive(Debug, Clone)]
pub struct GaugeFieldHKT<G, A, F, T> {
    /// Type-erased storage for a GaugeField.
    /// None represents an empty/identity context.
    inner: Option<Box<GaugeFieldData<T>>>,
    _phantom: PhantomData<(G, A, F, T)>,
}

/// Type-erased storage for GaugeField data.
/// This is necessary because we can't directly store GaugeField<G, A, F>
/// when G, A, F are generic HKT parameters.
#[derive(Debug, Clone)]
struct GaugeFieldData<T> {
    /// Serialized representation of the gauge field.
    /// In production, this would be the actual tensor data.
    connection_data: Vec<T>,
    field_strength_data: Vec<T>,
    connection_shape: Vec<usize>,
    field_strength_shape: Vec<usize>,
}

impl<G, A, F, T> Default for GaugeFieldHKT<G, A, F, T> {
    fn default() -> Self {
        Self::empty()
    }
}

impl<G, A, F, T> GaugeFieldHKT<G, A, F, T> {
    /// Creates an empty HKT wrapper (identity element).
    pub fn empty() -> Self {
        Self {
            inner: None,
            _phantom: PhantomData,
        }
    }

    /// Creates a wrapper from serialized data.
    pub fn from_data(
        connection_data: Vec<T>,
        field_strength_data: Vec<T>,
        connection_shape: Vec<usize>,
        field_strength_shape: Vec<usize>,
    ) -> Self {
        Self {
            inner: Some(Box::new(GaugeFieldData {
                connection_data,
                field_strength_data,
                connection_shape,
                field_strength_shape,
            })),
            _phantom: PhantomData,
        }
    }

    /// Returns true if this wrapper contains data.
    pub fn has_data(&self) -> bool {
        self.inner.is_some()
    }

    /// Returns the connection data if present.
    pub fn connection_data(&self) -> Option<&[T]> {
        self.inner.as_ref().map(|d| d.connection_data.as_slice())
    }

    /// Returns the field strength data if present.
    pub fn field_strength_data(&self) -> Option<&[T]> {
        self.inner
            .as_ref()
            .map(|d| d.field_strength_data.as_slice())
    }
}

impl<T> HKT3Unbound for GaugeFieldWitness<T>
where
    T: Satisfies<NoConstraint>,
{
    type Constraint = NoConstraint;
    type Type<A, B, C>
        = GaugeFieldHKT<A, B, C, T>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        C: Satisfies<NoConstraint>;
}

// ============================================================================
// MonoidalMerge Implementation
// ============================================================================

/// MonoidalMerge for GaugeField models current-field coupling.
///
/// # Physics Interpretation
///
/// The merge operation represents the coupling of sources to fields:
/// - Maxwell: ∂_μF^μν = J^ν (current J couples to field A to produce F)
/// - Yang-Mills: D_μF^μν = J^ν (with covariant derivative)
///
/// # Implementation Note
///
/// The HKT trait methods operate on the type-erased `GaugeFieldData`.
/// For strongly-typed operations with proper `GaugeGroup` constraints,
/// use the `merge_fields()` method on `GaugeFieldWitness` instead.
impl<T> MonoidalMerge<GaugeFieldWitness<T>> for GaugeFieldWitness<T>
where
    T: Field + From<f64> + Copy + Satisfies<NoConstraint>,
{
    /// Merges two gauge field contexts using a coupling function.
    ///
    /// # Physics
    ///
    /// This models the field equation coupling where current density J
    /// and potential A combine to produce field strength F.
    ///
    /// # Implementation — ACKNOWLEDGED HKT Limitation
    ///
    /// **Rust Trait Limitation:** The MonoidalMerge trait from deep_causality_haft does not
    /// include `'static` bounds on type parameters. TypeId-based runtime type checking
    /// requires `'static` bounds. Therefore, we cannot safely invoke the user-provided
    /// function `f` without potentially unsound transmutation.
    ///
    /// **Workaround:** This implementation uses simple element-wise averaging as a
    /// placeholder. For actual physics computations, use the type-safe `merge_fields()`
    /// method which enforces `GaugeGroup` bounds and properly invokes the coupling function.
    ///
    /// **Status:** ACKNOWLEDGED. Resolution requires either:
    /// 1. Upstream trait changes to add `'static` bounds to MonoidalMerge
    /// 2. New trait solver (`-Ztrait-solver=next`) for better GAT support
    fn merge<A, B, C, Func>(
        pa: GaugeFieldHKT<A, A, A, T>,
        pb: GaugeFieldHKT<B, B, B, T>,
        _f: Func,
    ) -> GaugeFieldHKT<C, C, C, T>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        C: Satisfies<NoConstraint>,
        Func: FnMut(A, B) -> C,
    {
        // If either context is empty, return empty (identity behavior)
        let (Some(data_a), Some(data_b)) = (&pa.inner, &pb.inner) else {
            return GaugeFieldHKT::empty();
        };

        let conn_len = data_a
            .connection_data
            .len()
            .min(data_b.connection_data.len());
        let fs_len = data_a
            .field_strength_data
            .len()
            .min(data_b.field_strength_data.len());

        // Placeholder: element-wise average
        // For production physics, use merge_fields() which is type-safe.
        let two = <T as From<f64>>::from(2.0);
        let merged_conn: Vec<T> = data_a
            .connection_data
            .iter()
            .zip(data_b.connection_data.iter())
            .take(conn_len)
            .map(|(&a, &b)| (a + b) / two)
            .collect();

        let merged_fs: Vec<T> = data_a
            .field_strength_data
            .iter()
            .zip(data_b.field_strength_data.iter())
            .take(fs_len)
            .map(|(&a, &b)| (a + b) / two)
            .collect();

        GaugeFieldHKT::from_data(
            merged_conn,
            merged_fs,
            data_a.connection_shape.clone(),
            data_a.field_strength_shape.clone(),
        )
    }
}

// ============================================================================
// ParametricMonad Implementation
// ============================================================================

/// ParametricMonad for GaugeField models gauge transformations.
///
/// # Physics Interpretation
///
/// Gauge transformations change the representation while preserving physics:
/// - Connection transforms: A' = gAg⁻¹ + g∂g⁻¹
/// - Field strength transforms covariantly: F' = gFg⁻¹
///
/// # Implementation Note
///
/// The HKT trait methods operate on the type-erased `GaugeFieldData`.
/// For strongly-typed operations with proper `GaugeGroup` constraints,
/// use the `gauge_transform()` method on `GaugeFieldWitness` instead.
impl<T> ParametricMonad<GaugeFieldWitness<T>> for GaugeFieldWitness<T>
where
    T: Satisfies<NoConstraint> + Clone,
{
    /// Injects a value into a trivial gauge field context.
    ///
    /// # Implementation
    ///
    /// Creates an empty HKT wrapper. For injection of actual field values,
    /// use `GaugeField::new()` with proper type constraints.
    fn pure<S, A>(value: A) -> GaugeFieldHKT<S, S, A, T>
    where
        S: Satisfies<NoConstraint>,
        A: Satisfies<NoConstraint>,
    {
        // Cannot store arbitrary A without knowing its layout.
        // Return empty wrapper (unit of the monad).
        let _ = value;
        GaugeFieldHKT::empty()
    }

    /// Indexed bind for gauge transformation composition.
    ///
    /// # Physics
    ///
    /// Composes gauge transformations: if we have a field in gauge S1→S2
    /// and a transformation S2→S3, we get a field in gauge S1→S3.
    ///
    /// # Implementation — ACKNOWLEDGED HKT Limitation
    ///
    /// **Rust Trait Limitation:** The ParametricMonad trait does not include `'static`
    /// bounds on type parameters. TypeId-based runtime type checking requires `'static`.
    /// Therefore, we cannot safely invoke the user-provided function `f`.
    ///
    /// **Workaround:** This implementation propagates data unchanged. For actual physics
    /// transformations, use the type-safe `gauge_transform()` method which enforces
    /// `GaugeGroup` bounds and properly applies the transformation.
    ///
    /// **Status:** ACKNOWLEDGED. Resolution requires upstream trait changes.
    fn ibind<S1, S2, S3, A, B, Func>(
        m: GaugeFieldHKT<S1, S2, A, T>,
        _f: Func,
    ) -> GaugeFieldHKT<S1, S3, B, T>
    where
        S1: Satisfies<NoConstraint>,
        S2: Satisfies<NoConstraint>,
        S3: Satisfies<NoConstraint>,
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> GaugeFieldHKT<S2, S3, B, T>,
    {
        // If the input has no data, return empty (short-circuit)
        let Some(data) = &m.inner else {
            return GaugeFieldHKT::empty();
        };

        // Placeholder: propagate data unchanged
        // For production physics transformations, use gauge_transform()
        GaugeFieldHKT::from_data(
            data.connection_data.clone(),
            data.field_strength_data.clone(),
            data.connection_shape.clone(),
            data.field_strength_shape.clone(),
        )
    }
}

// ============================================================================
//  Operations (Type-Safe)
// ============================================================================

impl<T> GaugeFieldWitness<T>
where
    T: Field + From<f64> + Copy + Satisfies<NoConstraint> + std::cmp::PartialEq,
{
    /// Merges two gauge fields using a coupling function.
    ///
    /// This is the type-safe production version that enforces GaugeGroup bounds.
    ///
    /// # Arguments
    ///
    /// * `current` - The current density field
    /// * `potential` - The gauge potential field
    /// * `coupling` - Function combining current and potential values
    ///
    /// # Returns
    ///
    /// A new gauge field with coupled field strength, or error if shape validation fails.
    pub fn merge_fields<G, A, B, F2, R, Func>(
        current: &GaugeField<G, A, R>,
        potential: &GaugeField<G, B, R>,
        coupling: Func,
    ) -> Result<GaugeField<G, F2, R>, TopologyError>
    where
        G: GaugeGroup,
        A: Field + Copy + Default + PartialOrd + Clone,
        B: Field + Copy + Default + PartialOrd + Clone,
        F2: Field + Copy + Default + PartialOrd + Clone + Default, // Must serve as M
        R: RealField,
        Func: Fn(&A, &B) -> F2,
    {
        // Use the potential's base manifold and metric
        let base = potential.base().clone();
        let metric = potential.metric();

        // Apply coupling function to create new connection
        let current_conn = current.connection();
        let potential_conn = potential.connection();

        // Combine connections element-wise
        let conn_data: Vec<F2> = current_conn
            .as_slice()
            .iter()
            .zip(potential_conn.as_slice().iter())
            .map(|(a, b)| coupling(a, b))
            .collect();

        let connection = CausalTensor::from_vec(conn_data, current_conn.shape());

        // Combine field strengths
        let current_fs = current.field_strength();
        let potential_fs = potential.field_strength();

        let fs_data: Vec<F2> = current_fs
            .as_slice()
            .iter()
            .zip(potential_fs.as_slice().iter())
            .map(|(a, b)| coupling(a, b))
            .collect();

        let field_strength = CausalTensor::from_vec(fs_data, current_fs.shape());

        GaugeField::new(base, metric, connection, field_strength)
    }

    /// Applies a gauge transformation to a field.
    ///
    /// # Physics
    ///
    /// For a gauge transformation g:
    /// - Connection: A' = gAg⁻¹ + g(∂g⁻¹)
    /// - Field strength: F' = gFg⁻¹ (covariant transformation)
    ///
    /// # Errors
    ///
    /// Returns `TopologyError::GaugeFieldError` if shape validation fails.
    pub fn gauge_transform<G, A, F2, R, Func>(
        field: &GaugeField<G, A, R>,
        transform: Func,
    ) -> Result<GaugeField<G, F2, R>, TopologyError>
    where
        G: GaugeGroup,
        A: Field + Copy + Default + PartialOrd + Clone,
        F2: Field + Copy + Default + PartialOrd + Clone + Default,
        R: RealField,
        Func: Fn(&A) -> F2,
    {
        let base = field.base().clone();
        let metric = field.metric();

        // Transform connection
        let conn_data: Vec<F2> = field
            .connection()
            .as_slice()
            .iter()
            .map(&transform)
            .collect();
        let connection = CausalTensor::from_vec(conn_data, field.connection().shape());

        // Transform field strength
        let fs_data: Vec<F2> = field
            .field_strength()
            .as_slice()
            .iter()
            .map(&transform)
            .collect();
        let field_strength = CausalTensor::from_vec(fs_data, field.field_strength().shape());

        GaugeField::new(base, metric, connection, field_strength)
    }

    /// Computes field strength from connection (for abelian gauge fields).
    ///
    /// # Mathematical Definition
    ///
    /// For abelian groups (U(1)):
    /// ```text
    /// F_μν = ∂_μ A_ν - ∂_ν A_μ
    /// ```
    ///
    /// This is the exterior derivative of the connection 1-form: F = dA.
    ///
    /// # Implementation
    ///
    /// Uses finite differences to approximate derivatives between adjacent
    /// spacetime points. For single-point fields, uses the connection values
    /// directly to construct the antisymmetric field strength tensor.
    ///
    /// # Returns
    ///
    /// - `Some(F_μν)` for abelian gauge groups
    /// - `None` for non-abelian groups (require additional A∧A term)
    pub fn compute_field_strength_abelian<G, R>(
        field: &GaugeField<G, T, R>,
    ) -> Option<CausalTensor<T>>
    where
        G: GaugeGroup,
        T: Field + Copy + Default + PartialOrd, // T is from impl bounds
        R: RealField,
    {
        if !G::IS_ABELIAN {
            return None;
        }

        // For abelian: F_μν = ∂_μA_ν - ∂_νA_μ
        let connection = field.connection();
        let dim = G::SPACETIME_DIM;
        let lie_dim = G::LIE_ALGEBRA_DIM;

        // Get connection shape [num_points, spacetime_dim, lie_dim]
        let conn_shape = connection.shape();
        let num_points = if conn_shape.is_empty() {
            1
        } else {
            conn_shape[0]
        };

        // F has shape [num_points, dim, dim, lie_dim]
        let total = num_points * dim * dim * lie_dim;
        let mut fs_data = vec![T::zero(); total];

        let conn_data = connection.as_slice();

        // Compute antisymmetric field strength F_μν = ∂_μA_ν - ∂_νA_μ
        // For each point, each Lie algebra index
        for p in 0..num_points {
            for a in 0..lie_dim {
                for mu in 0..dim {
                    for nu in 0..dim {
                        // F_μν^a = ∂_μ A_ν^a - ∂_ν A_μ^a
                        // For discrete manifold, approximate derivative using
                        // the connection values at the current point.

                        // Connection index: A_μ^a at point p
                        // Shape [num_points, spacetime_dim, lie_dim]
                        // Linear index: p * (dim * lie_dim) + mu * lie_dim + a
                        let a_mu_idx = p * (dim * lie_dim) + mu * lie_dim + a;
                        let a_nu_idx = p * (dim * lie_dim) + nu * lie_dim + a;

                        let a_mu = conn_data.get(a_mu_idx).copied().unwrap_or(T::zero());
                        let a_nu = conn_data.get(a_nu_idx).copied().unwrap_or(T::zero());

                        // For a single-point field, we construct the antisymmetric
                        // part from the connection components.
                        // F_μν = A_μ - A_ν (simplified for uniform grid with unit spacing)
                        // This gives F_μν = -F_νμ automatically.

                        // More accurate: use finite difference if multiple points exist
                        let f_mu_nu = if num_points > 1 && p < num_points - 1 {
                            // Forward difference approximation
                            let next_a_nu_idx = (p + 1) * (dim * lie_dim) + nu * lie_dim + a;
                            let next_a_mu_idx = (p + 1) * (dim * lie_dim) + mu * lie_dim + a;

                            let next_a_nu = conn_data.get(next_a_nu_idx).copied().unwrap_or(a_nu);
                            let next_a_mu = conn_data.get(next_a_mu_idx).copied().unwrap_or(a_mu);

                            // ∂_μ A_ν ≈ (A_ν(x+Δx_μ) - A_ν(x)) / Δx
                            // Assuming unit spacing Δx = 1
                            let d_mu_a_nu = next_a_nu - a_nu;
                            let d_nu_a_mu = next_a_mu - a_mu;

                            d_mu_a_nu - d_nu_a_mu
                        } else {
                            // For single point: antisymmetrize the connection components
                            // This gives 0 on diagonal and ±(A_μ - A_ν) off-diagonal
                            a_nu - a_mu
                        };

                        // Field strength index: F_μν^a at point p
                        // Shape [num_points, dim, dim, lie_dim]
                        // Linear index: p * (dim * dim * lie_dim) + mu * (dim * lie_dim) + nu * lie_dim + a
                        let fs_idx =
                            p * (dim * dim * lie_dim) + mu * (dim * lie_dim) + nu * lie_dim + a;

                        if fs_idx < total {
                            fs_data[fs_idx] = f_mu_nu;
                        }
                    }
                }
            }
        }

        Some(CausalTensor::from_vec(
            fs_data,
            &[num_points, dim, dim, lie_dim],
        ))
    }

    /// Computes field strength for non-abelian gauge fields (e.g. SU(2), SU(3)).
    ///
    /// # Mathematical Definition
    ///
    /// ```text
    /// F_μν^a = ∂_μ A_ν^a - ∂_ν A_μ^a + g f^{abc} A_μ^b A_ν^c
    /// ```
    ///
    /// - First two terms: Abelian derivative part
    /// - Third term: Non-abelian self-interaction (commutator)
    /// - g: Coupling constant
    /// - f^{abc}: Structure constants of the Lie algebra
    ///
    /// # Arguments
    ///
    /// * `field` - The non-abelian gauge field
    /// * `coupling` - The coupling constant g
    ///
    /// # Returns
    ///
    /// - The computed field strength tensor F_μν^a
    pub fn compute_field_strength_non_abelian<G, R>(
        field: &GaugeField<G, T, R>,
        coupling: T,
    ) -> CausalTensor<T>
    where
        G: GaugeGroup,
        T: Field + Copy + PartialOrd,
        R: deep_causality_algebra::RealField,
    {
        let connection = field.connection();
        let dim = G::SPACETIME_DIM;
        let lie_dim = G::LIE_ALGEBRA_DIM;

        let conn_shape = connection.shape();
        let num_points = if conn_shape.is_empty() {
            1
        } else {
            conn_shape[0]
        };

        let total = num_points * dim * dim * lie_dim;
        let mut fs_data = vec![T::zero(); total];
        let conn_data = connection.as_slice();

        for p in 0..num_points {
            for a in 0..lie_dim {
                for mu in 0..dim {
                    for nu in 0..dim {
                        // 1. Abelian part: ∂_μ A_ν^a - ∂_ν A_μ^a
                        // -----------------------------------------
                        let a_mu_idx = p * (dim * lie_dim) + mu * lie_dim + a;
                        let a_nu_idx = p * (dim * lie_dim) + nu * lie_dim + a;

                        let a_mu_val = conn_data.get(a_mu_idx).copied().unwrap_or(T::zero());
                        let a_nu_val = conn_data.get(a_nu_idx).copied().unwrap_or(T::zero());

                        let abelian_term = if num_points > 1 && p < num_points - 1 {
                            // Forward difference approximation
                            let next_pt_offset = dim * lie_dim;
                            let a_nu_next = conn_data
                                .get(a_nu_idx + next_pt_offset)
                                .copied()
                                .unwrap_or(a_mu_val);
                            let a_mu_next = conn_data
                                .get(a_mu_idx + next_pt_offset)
                                .copied()
                                .unwrap_or(a_nu_val);

                            let d_mu_a_nu = a_nu_next - a_nu_val;
                            let d_nu_a_mu = a_mu_next - a_mu_val;
                            d_mu_a_nu - d_nu_a_mu
                        } else {
                            // Single point approx (commutator-like)
                            a_nu_val - a_mu_val
                        };

                        // 2. Non-Abelian part: g f^{abc} A_μ^b A_ν^c
                        // ------------------------------------------
                        let mut non_abelian_term = T::zero();
                        if coupling != T::zero() {
                            for b in 0..lie_dim {
                                for c in 0..lie_dim {
                                    let f_abc_f64 = G::structure_constant(a, b, c);
                                    let f_abc: T = f_abc_f64.into();

                                    if f_abc != T::zero() {
                                        let a_mu_b = conn_data
                                            .get(p * (dim * lie_dim) + mu * lie_dim + b)
                                            .copied()
                                            .unwrap_or(T::zero());
                                        let a_nu_c = conn_data
                                            .get(p * (dim * lie_dim) + nu * lie_dim + c)
                                            .copied()
                                            .unwrap_or(T::zero());

                                        non_abelian_term =
                                            non_abelian_term + (coupling * f_abc * a_mu_b * a_nu_c);
                                    }
                                }
                            }
                        }

                        let f_val = abelian_term + non_abelian_term;
                        let idx =
                            p * (dim * dim * lie_dim) + mu * (dim * lie_dim) + nu * lie_dim + a;
                        if idx < total {
                            fs_data[idx] = f_val;
                        }
                    }
                }
            }
        }

        CausalTensor::from_vec(fs_data, &[num_points, dim, dim, lie_dim])
    }

    /// Constructs the electromagnetic field strength tensor F_μν directly from E and B vectors.
    ///
    /// # Mathematical Definition
    ///
    /// The field strength tensor is constructed as:
    /// ```text
    ///        ⎛  0    E_x   E_y   E_z ⎞
    /// F_μν = ⎜-E_x   0    -B_z   B_y ⎟
    ///        ⎜-E_y  B_z    0    -B_x ⎟
    ///        ⎝-E_z -B_y   B_x    0   ⎠
    /// ```
    ///
    /// Uses West Coast (+---) signature convention.
    ///
    /// # Arguments
    ///
    /// * `e` - Electric field components [E_x, E_y, E_z]
    /// * `b` - Magnetic field components [B_x, B_y, B_z]
    /// * `num_points` - Number of spacetime points (default 1)
    ///
    /// # Returns
    ///
    /// Field strength tensor of shape [num_points, 4, 4, 1] for U(1).
    ///
    /// # Panics
    ///
    /// Panics if `e` or `b` do not have exactly 3 elements.
    pub fn field_strength_from_eb_vectors(e: &[T], b: &[T], num_points: usize) -> CausalTensor<T> {
        assert_eq!(e.len(), 3, "Electric field must have 3 components");
        assert_eq!(b.len(), 3, "Magnetic field must have 3 components");

        let dim = 4;
        let lie_dim = 1; // U(1)
        let n = num_points.max(1);
        let total = n * dim * dim * lie_dim;
        let mut fs_data = vec![T::zero(); total];

        let ex = e[0];
        let ey = e[1];
        let ez = e[2];
        let bx = b[0];
        let by = b[1];
        let bz = b[2];

        for p in 0..n {
            let offset = p * dim * dim * lie_dim;

            // F_01 = E_x, F_10 = -E_x
            fs_data[offset + 1] = ex;
            fs_data[offset + 4] = T::zero() - ex;

            // F_02 = E_y, F_20 = -E_y
            fs_data[offset + 2] = ey;
            fs_data[offset + 8] = T::zero() - ey;

            // F_03 = E_z, F_30 = -E_z
            fs_data[offset + 3] = ez;
            fs_data[offset + 12] = T::zero() - ez;

            // F_ij = -epsilon_ijk B_k (matching physics convention)
            // F_23 = B_x, F_32 = -B_x (index 23 = 2*4+3 = 11, index 32 = 3*4+2 = 14)
            fs_data[offset + 11] = bx;
            fs_data[offset + 14] = T::zero() - bx;

            // F_31 = B_y, F_13 = -B_y (index 31 = 3*4+1 = 13, index 13 = 1*4+3 = 7)
            fs_data[offset + 13] = by;
            fs_data[offset + 7] = T::zero() - by;

            // F_12 = B_z, F_21 = -B_z (index 12 = 1*4+2 = 6, index 21 = 2*4+1 = 9)
            fs_data[offset + 6] = bz;
            fs_data[offset + 9] = T::zero() - bz;
        }

        CausalTensor::from_vec(fs_data, &[n, dim, dim, lie_dim])
    }

    /// Performs a gauge rotation (Weinberg mixing) on a gauge field.
    ///
    /// # Mathematical Definition
    ///
    /// This implements the rotation that mixes gauge components:
    /// ```text
    /// A'_μ^a = R^a_b(θ) A_μ^b
    /// ```
    ///
    /// For electroweak symmetry breaking (Weinberg mixing):
    /// ```text
    /// A_μ = B_μ cos(θ_W) + W³_μ sin(θ_W)   (Photon)
    /// Z_μ = -B_μ sin(θ_W) + W³_μ cos(θ_W)  (Z boson)
    /// ```
    ///
    /// # Arguments
    ///
    /// * `connection` - The original connection tensor [num_points, dim, lie_dim]
    /// * `field_strength` - The original field strength tensor [num_points, dim, dim, lie_dim]
    /// * `index_a` - First Lie algebra index to mix
    /// * `index_b` - Second Lie algebra index to mix
    /// * `cos_angle` - Cosine of the mixing angle
    /// * `sin_angle` - Sine of the mixing angle
    ///
    /// # Returns
    ///
    /// Tuple of (rotated_connection, rotated_field_strength) for the first mixed component.
    ///
    /// # Example
    ///
    /// ```ignore
    /// // Extract photon from electroweak field (Weinberg mixing)
    /// let cos_w = 0.8768; // cos(θ_W)
    /// let sin_w = 0.4808; // sin(θ_W)
    /// let (photon_conn, photon_fs) = GaugeFieldWitness::gauge_rotation(
    ///     ew_conn, ew_fs,
    ///     2, 3,  // W³ and B indices
    ///     cos_w, sin_w
    /// );
    /// ```
    pub fn gauge_rotation(
        connection: &CausalTensor<T>,
        field_strength: &CausalTensor<T>,
        index_a: usize,
        index_b: usize,
        cos_angle: T,
        sin_angle: T,
    ) -> (CausalTensor<T>, CausalTensor<T>) {
        let conn_shape = connection.shape();
        let fs_shape = field_strength.shape();

        // Validate shapes
        if conn_shape.len() < 3 || fs_shape.len() < 4 {
            // Return empty tensors on invalid input
            return (
                CausalTensor::from_vec(vec![], &[0]),
                CausalTensor::from_vec(vec![], &[0]),
            );
        }

        let num_points = conn_shape[0];
        let dim = conn_shape[1];
        let lie_dim = conn_shape[2];

        // Validate indices
        if index_a >= lie_dim || index_b >= lie_dim {
            return (
                CausalTensor::from_vec(vec![], &[0]),
                CausalTensor::from_vec(vec![], &[0]),
            );
        }

        // New connection has lie_dim = 1 (single gauge component after mixing)
        let new_conn_total = num_points * dim;
        let mut new_conn_data = vec![T::zero(); new_conn_total];

        let conn_data = connection.as_slice();

        // A'_μ = A_μ^a cos(θ) + A_μ^b sin(θ)
        for p in 0..num_points {
            for mu in 0..dim {
                let conn_a_idx = p * (dim * lie_dim) + mu * lie_dim + index_a;
                let conn_b_idx = p * (dim * lie_dim) + mu * lie_dim + index_b;

                let a_mu_a = conn_data.get(conn_a_idx).copied().unwrap_or(T::zero());
                let a_mu_b = conn_data.get(conn_b_idx).copied().unwrap_or(T::zero());

                // Mixed component: A' = A^a sin(θ) + A^b cos(θ)
                // For photon: A = W³ sin(θ_W) + B cos(θ_W)
                let mixed = a_mu_a * sin_angle + a_mu_b * cos_angle;

                let new_idx = p * dim + mu;
                new_conn_data[new_idx] = mixed;
            }
        }

        // New field strength has lie_dim = 1
        let new_fs_total = num_points * dim * dim;
        let mut new_fs_data = vec![T::zero(); new_fs_total];

        let fs_data = field_strength.as_slice();

        // F'_μν = F_μν^a cos(θ) + F_μν^b sin(θ)
        for p in 0..num_points {
            for mu in 0..dim {
                for nu in 0..dim {
                    let fs_a_idx =
                        p * (dim * dim * lie_dim) + mu * (dim * lie_dim) + nu * lie_dim + index_a;
                    let fs_b_idx =
                        p * (dim * dim * lie_dim) + mu * (dim * lie_dim) + nu * lie_dim + index_b;

                    let f_a = fs_data.get(fs_a_idx).copied().unwrap_or(T::zero());
                    let f_b = fs_data.get(fs_b_idx).copied().unwrap_or(T::zero());

                    // Mixed component
                    let mixed = f_a * sin_angle + f_b * cos_angle;

                    let new_idx = p * (dim * dim) + mu * dim + nu;
                    new_fs_data[new_idx] = mixed;
                }
            }
        }

        let new_conn = CausalTensor::from_vec(new_conn_data, &[num_points, dim, 1]);
        let new_fs = CausalTensor::from_vec(new_fs_data, &[num_points, dim, dim, 1]);

        (new_conn, new_fs)
    }
}
