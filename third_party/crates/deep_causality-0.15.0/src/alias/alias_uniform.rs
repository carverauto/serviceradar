/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::context_node_types::symbol::symbol_kind::SymbolKind;
use crate::{
    Causaloid, CausaloidGraph, Context, Contextoid, Data, FloatType, Model, NumberType, SpaceKind,
    SpaceTimeKind, TimeKind,
};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};

/// A type alias for a default, general-purpose `Model` configuration that uses
/// abstract "kind" enums for its spatial, temporal, and symbolic contexts.
///
/// This `UniformModel` alias represents a `Model` instance configured with a
/// standard set of generic parameters, making it suitable for common causal
/// modeling scenarios where the specific underlying concrete types for space,
/// time, and symbols can vary but are represented by their respective "kind" enums.
///
/// It provides a convenient and readable shorthand for defining a `Model`
/// that encapsulates:
///
/// - **`Data<NumberType>`**: Used for its data component. `NumberType` is a
///   generic numeric type, typically an alias for a floating-point or integer,
///   allowing for flexible data representation within the model.
/// - **`SpaceKind`**: Defines the spatial context using an abstract `SpaceKind`
///   enum. This allows the model to operate with various spatial representations
///   (e.g., `EuclideanSpace`, `EcefSpace`, `NedSpace`, `GeoSpace`) without
///   changing the `Model`'s type signature, providing uniformity across different
///   spatial contexts.
/// - **`TimeKind`**: Specifies the temporal context using an abstract `TimeKind`
///   enum. This enables the model to handle different temporal representations
///   (e.g., `EuclideanTime`, `DiscreteTime`, `EntropicTime`, `LorentzianTime`)
///   flexibly, offering a uniform temporal interface.
/// - **`SpaceTimeKind`**: Combines the spatial and temporal contexts into a
///   unified spacetime representation using an abstract `SpaceTimeKind` enum,
///   allowing for various spacetime geometries (e.g., `EuclideanSpacetime`,
///   `LorentzianSpacetime`, `MinkowskiSpacetime`) in a uniform manner.
/// - **`SymbolKind`**: Provides a basic symbolic representation for elements
///   within the model using an abstract `SymbolKind` enum, useful for labeling,
///   identification, or abstract reasoning across different symbolic types.
/// - **`FloatType` (x2)**: Two `FloatType` parameters, typically used for
///   internal calculations, scalar values, metrics, or other generic numerical
///   requirements within the `Model` structure, such as probabilities, weights,
///   or magnitudes. `FloatType` is generally an alias for a standard floating-point type.
///
/// This `UniformModel` is designed to be a sensible default for many applications
/// requiring a flexible yet consistent model structure that can adapt to different
/// underlying spatial, temporal, and symbolic representations through their
/// respective `Kind` enums. It promotes code reusability and simplifies type
/// declarations when the exact concrete type of a context component is not
/// fixed but rather belongs to a set of predefined "kinds".
pub type UniformModel = Model<bool, bool, UniformContext>;

/// A type alias for a default, general-purpose `Causaloid` configuration that uses
/// abstract "kind" enums for its spatial, temporal, and symbolic contexts.
///
/// This `UniformCausaloid` alias represents a single, identity-bearing causal unit
/// (`Causaloid`) configured with a standard set of generic parameters. It is designed
/// for common causal modeling scenarios where the specific underlying concrete types
/// for space, time, and symbols can vary but are represented by their respective
/// "kind" enums.
///
/// It provides a convenient and readable shorthand for defining a `Causaloid`
/// that encapsulates:
///
/// - **`Data<NumberType>`**: Represents the data component associated with the causaloid.
///   `NumberType` is a generic numeric type, typically an alias for a floating-point
///   or integer, allowing for flexible data representation.
/// - **`SpaceKind`**: Defines the spatial context using an abstract `SpaceKind`
///   enum. This allows the causaloid to operate with various spatial representations
///   (e.g., `EuclideanSpace`, `EcefSpace`, `NedSpace`, `GeoSpace`) without
///   changing the `Causaloid`'s type signature, providing uniformity across different
///   spatial contexts.
/// - **`TimeKind`**: Specifies the temporal context using an abstract `TimeKind`
///   enum. This enables the causaloid to handle different temporal representations
///   (e.g., `EuclideanTime`, `DiscreteTime`, `EntropicTime`, `LorentzianTime`)
///   flexibly, offering a uniform temporal interface.
/// - **`SpaceTimeKind`**: Combines the spatial and temporal contexts into a
///   unified spacetime representation using an abstract `SpaceTimeKind` enum,
///   allowing for various spacetime geometries (e.g., `EuclideanSpacetime`,
///   `LorentzianSpacetime`, `MinkowskiSpacetime`) in a uniform manner.
/// - **`SymbolKind`**: Provides a basic symbolic representation for the causaloid
///   using an abstract `SymbolKind` enum, useful for labeling, identification,
///   or abstract reasoning across different symbolic types.
/// - **`FloatType` (x2)**: Two `FloatType` parameters, typically used for
///   internal calculations, scalar values, or other generic numerical
///   requirements within the `Causaloid` structure, such as probabilities,
///   weights, or magnitudes. `FloatType` is generally an alias for a standard
///   floating-point type.
///
/// This `UniformCausaloid` is designed to be a sensible default for many applications
/// requiring a flexible yet consistent causal unit structure that can adapt to different
/// underlying spatial, temporal, and symbolic representations through their
/// respective `Kind` enums. It promotes code reusability and simplifies type
/// declarations when the exact concrete type of a context component is not
/// fixed but rather belongs to a set of predefined "kinds".
pub type UniformCausaloid = Causaloid<bool, bool, (), Arc<RwLock<UniformContext>>>;

/// A type alias for a `Vec` (vector) containing `UniformCausaloid` instances.
///
/// This alias provides a convenient shorthand for an ordered collection of causaloids,
/// where each causaloid adheres to a "uniform" configuration using abstract "kind"
/// enums for its contextual components. It is designed to represent a list or
/// sequence of `Causaloid` instances that share a common, flexible generic structure.
///
/// Each `Causaloid` within this vector is parameterized with the following types,
/// defining its uniform context and data handling:
///
/// - **`Data<NumberType>`**: Represents the data component associated with each causaloid.
///   `NumberType` is a generic numeric type, typically a floating-point or integer.
/// - **`SpaceKind`**: Defines the spatial context using an abstract `SpaceKind`
///   enum. This allows the causaloids to operate with various spatial representations
///   (e.g., `EuclideanSpace`, `GeoSpace`) under a single, uniform type.
/// - **`TimeKind`**: Specifies the temporal context using an abstract `TimeKind`
///   enum. This enables the causaloids to handle different temporal representations
///   (e.g., `EuclideanTime`, `DiscreteTime`) flexibly.
/// - **`SpaceTimeKind`**: Combines the spatial and temporal contexts into a
///   unified spacetime representation using an abstract `SpaceTimeKind` enum,
///   allowing for various spacetime geometries.
/// - **`SymbolKind`**: Provides a symbolic representation for the causaloids
///   using an abstract `SymbolKind` enum, useful for labeling and identification.
/// - **`FloatType` (x2)**: Two `FloatType` parameters, typically used for internal
///   calculations, such as probabilities, weights, or magnitudes.
///
/// This `UniformCausaloidVec` is ideal for use cases requiring a flexible yet
/// consistent structure for managing ordered collections of causal entities. It
/// simplifies the representation of sequential events or related causal agents,
/// especially when the specific underlying context types can vary.
pub type UniformCausaloidVec = Vec<Causaloid<bool, bool, (), Arc<RwLock<UniformContext>>>>;

/// A type alias for a `HashMap` that stores `UniformCausaloid` instances, typically indexed by their unique identifiers.
///
/// This alias provides a convenient shorthand for a collection of causaloids,
/// where each causaloid adheres to a "uniform" configuration using abstract "kind"
/// enums for its contextual components. It is designed to represent a mapping
/// from an integer ID (e.g., a node index or a unique identifier) to a
/// `UniformCausaloid` instance.
///
/// The `UniformCausaloid` type, which forms the value of this map, is parameterized
/// with the following types, defining its flexible and consistent structure:
///
/// - **`Data<NumberType>`**: Represents the data component associated with each causaloid.
///   `NumberType` is a generic numeric type, typically an alias for a floating-point
///   or integer, allowing for flexible data representation.
/// - **`SpaceKind`**: Defines the spatial context using an abstract `SpaceKind`
///   enum. This allows the causaloids to operate with various spatial representations
///   (e.g., `EuclideanSpace`, `EcefSpace`, `NedSpace`, `GeoSpace`) without
///   changing the `Causaloid`'s type signature, providing uniformity across different
///   spatial contexts.
/// - **`TimeKind`**: Specifies the temporal context using an abstract `TimeKind`
///   enum. This enables the causaloids to handle different temporal representations
///   (e.g., `EuclideanTime`, `DiscreteTime`, `EntropicTime`, `LorentzianTime`)
///   flexibly, offering a uniform temporal interface.
/// - **`SpaceTimeKind`**: Combines the spatial and temporal contexts into a
///   unified spacetime representation using an abstract `SpaceTimeKind` enum,
///   allowing for various spacetime geometries (e.g., `EuclideanSpacetime`,
///   `LorentzianSpacetime`, `MinkowskiSpacetime`) in a uniform manner.
/// - **`SymbolKind`**: Provides a basic symbolic representation for the causaloids
///   using an abstract `SymbolKind` enum, useful for labeling, identification,
///   or abstract reasoning across different symbolic types.
/// - **`FloatType` (x2)**: Two `FloatType` parameters, typically used for
///   internal calculations, scalar values, or other generic numerical
///   requirements within the `Causaloid` structure, such as probabilities,
///   weights, or magnitudes. `FloatType` is generally an alias for a standard
///   floating-point type.
///
/// This `UniformCausalMap` is suitable for general-purpose use cases where a
/// flexible yet consistent structure is required for managing causal entities
/// within a map structure. It promotes code reusability and simplifies type
/// declarations when the exact concrete type of a context component is not
/// fixed but rather belongs to a set of predefined "kinds".
pub type UniformCausalMap = HashMap<usize, Causaloid<bool, bool, (), Arc<RwLock<UniformContext>>>>;

/// A type alias for a `CausaloidGraph` composed of `UniformCausaloid` instances.
///
/// This alias provides a convenient shorthand for defining a causal graph where
/// each node (causaloid) adheres to a "uniform" configuration. This means it
/// utilizes abstract "kind" enums for its spatial, temporal, and symbolic contexts,
/// offering flexibility while maintaining a consistent type signature.
///
/// Specifically, `UniformCausalGraph` is a `CausaloidGraph` parameterized by a
/// `Causaloid` that uses the following types for its generic parameters:
///
/// - **`Data<NumberType>`**: Represents the data component associated with each causaloid.
///   `NumberType` is a generic numeric type, typically an alias for a floating-point
///   or integer, allowing for flexible data representation.
/// - **`SpaceKind`**: Defines the spatial context using an abstract `SpaceKind`
///   enum. This allows the causaloids within the graph to operate with various
///   spatial representations (e.g., `EuclideanSpace`, `EcefSpace`, `NedSpace`,
///   `GeoSpace`) without changing the graph's type signature, providing uniformity
///   across different spatial contexts.
/// - **`TimeKind`**: Specifies the temporal context using an abstract `TimeKind`
///   enum. This enables the causaloids to handle different temporal representations
///   (e.g., `EuclideanTime`, `DiscreteTime`, `EntropicTime`, `LorentzianTime`)
///   flexibly, offering a uniform temporal interface.
/// - **`SpaceTimeKind`**: Combines the spatial and temporal contexts into a
///   unified spacetime representation using an abstract `SpaceTimeKind` enum,
///   allowing for various spacetime geometries (e.g., `EuclideanSpacetime`,
///   `LorentzianSpacetime`, `MinkowskiSpacetime`) in a uniform manner.
/// - **`SymbolKind`**: Provides a basic symbolic representation for the causaloids
///   using an abstract `SymbolKind` enum, useful for labeling, identification,
///   or abstract reasoning across different symbolic types.
/// - **`FloatType` (x2)**: Two `FloatType` parameters, typically used for
///   internal calculations, scalar values, or other generic numerical
///   requirements within the `Causaloid` structure, such as probabilities,
///   weights, or magnitudes. `FloatType` is generally an alias for a standard
///   floating-point type.
///
/// This `UniformCausalGraph` is designed for general-purpose use cases where a
/// flexible yet consistent graph structure is required. It promotes code reusability
/// and simplifies type declarations when the exact concrete type of a context
/// component is not fixed but rather belongs to a set of predefined "kinds".
pub type UniformCausalGraph =
    CausaloidGraph<Causaloid<bool, bool, (), Arc<RwLock<UniformContext>>>>;

/// A type alias for a default, general-purpose `Context` configuration that uses
/// abstract "kind" enums for its spatial, temporal, and symbolic contexts.
///
/// This `UniformContext` alias represents a `Context` instance configured with a
/// standard set of generic parameters, making it suitable for common causal
/// modeling scenarios where the specific underlying concrete types for space,
/// time, and symbols can vary but are represented by their respective "kind" enums.
///
/// It provides a convenient and readable shorthand for defining a `Context`
/// that encapsulates:
///
/// - **`Data<NumberType>`**: Used for its data component. `NumberType` is a
///   generic numeric type, typically an alias for a floating-point or integer,
///   allowing for flexible data representation within the context.
/// - **`SpaceKind`**: Defines the spatial context using an abstract `SpaceKind`
///   enum. This allows the context to operate with various spatial representations
///   (e.g., `EuclideanSpace`, `EcefSpace`, `NedSpace`, `GeoSpace`) without
///   changing the `Context`'s type signature, providing uniformity across different
///   spatial contexts.
/// - **`TimeKind`**: Specifies the temporal context using an abstract `TimeKind`
///   enum. This enables the context to handle different temporal representations
///   (e.g., `EuclideanTime`, `DiscreteTime`, `EntropicTime`, `LorentzianTime`)
///   flexibly, offering a uniform temporal interface.
/// - **`SpaceTimeKind`**: Combines the spatial and temporal contexts into a
///   unified spacetime representation using an abstract `SpaceTimeKind` enum,
///   allowing for various spacetime geometries (e.g., `EuclideanSpacetime`,
///   `LorentzianSpacetime`, `MinkowskiSpacetime`) in a uniform manner.
/// - **`SymbolKind`**: Provides a basic symbolic representation for elements
///   within the context using an abstract `SymbolKind` enum, useful for labeling,
///   identification, or abstract reasoning across different symbolic types.
/// - **`FloatType` (x2)**: Two `FloatType` parameters, typically used for
///   internal calculations, scalar values, metrics, or other generic numerical
///   requirements within the `Context` structure, such as probabilities, weights,
///   or magnitudes. `FloatType` is generally an alias for a standard floating-point type.
///
/// This `UniformContext` is designed to be a sensible default for many applications
/// requiring a flexible yet consistent context structure that can adapt to different
/// underlying spatial, temporal, and symbolic representations through their
/// respective `Kind` enums. It promotes code reusability and simplifies type
/// declarations when the exact concrete type of a context component is not
/// fixed but rather belongs to a set of predefined "kinds".
pub type UniformContext =
    Context<Data<NumberType>, SpaceKind, TimeKind, SpaceTimeKind, SymbolKind, FloatType, FloatType>;

/// A type alias for a default, general-purpose `Contextoid` configuration that uses
/// abstract "kind" enums for its spatial, temporal, and symbolic contexts.
///
/// This `UniformContextoid` alias represents a `Contextoid` instance configured with a
/// standard set of generic parameters, making it suitable for common causal
/// modeling scenarios where the specific underlying concrete types for space,
/// time, and symbols can vary but are represented by their respective "kind" enums.
///
/// It provides a convenient and readable shorthand for defining a `Contextoid`
/// that encapsulates:
///
/// - **`Data<NumberType>`**: Used for its data component. `NumberType` is a
///   generic numeric type, typically an alias for a floating-point or integer,
///   allowing for flexible data representation within the contextoid.
/// - **`SpaceKind`**: Defines the spatial context using an abstract `SpaceKind`
///   enum. This allows the contextoid to operate with various spatial representations
///   (e.g., `EuclideanSpace`, `EcefSpace`, `NedSpace`, `GeoSpace`) without
///   changing the `Contextoid`'s type signature, providing uniformity across different
///   spatial contexts.
/// - **`TimeKind`**: Specifies the temporal context using an abstract `TimeKind`
///   enum. This enables the contextoid to handle different temporal representations
///   (e.g., `EuclideanTime`, `DiscreteTime`, `EntropicTime`, `LorentzianTime`)
///   flexibly, offering a uniform temporal interface.
/// - **`SpaceTimeKind`**: Combines the spatial and temporal contexts into a
///   unified spacetime representation using an abstract `SpaceTimeKind` enum,
///   allowing for various spacetime geometries (e.g., `EuclideanSpacetime`,
///   `LorentzianSpacetime`, `MinkowskiSpacetime`) in a uniform manner.
/// - **`SymbolKind`**: Provides a basic symbolic representation for elements
///   within the contextoid using an abstract `SymbolKind` enum, useful for labeling,
///   identification, or abstract reasoning across different symbolic types.
/// - **`FloatType` (x2)**: Two `FloatType` parameters, typically used for
///   internal calculations, scalar values, metrics, or other generic numerical
///   requirements within the `Contextoid` structure, such as probabilities, weights,
///   or magnitudes. `FloatType` is generally an alias for a standard floating-point type.
///
/// This `UniformContextoid` is designed to be a sensible default for many applications
/// requiring a flexible yet consistent contextoid structure that can adapt to different
/// underlying spatial, temporal, and symbolic representations through their
/// respective `Kind` enums. It promotes code reusability and simplifies type
/// declarations when the exact concrete type of a context component is not
/// fixed but rather belongs to a set of predefined "kinds".
pub type UniformContextoid = Contextoid<
    Data<NumberType>,
    SpaceKind,
    TimeKind,
    SpaceTimeKind,
    SymbolKind,
    FloatType,
    FloatType,
>;
