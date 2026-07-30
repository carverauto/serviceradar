[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# ArrayGrid - A Faster Tensor For Low Dimensional Data

ArrayGrid is an abstraction over scalars, vectors, and lod dimensional matrices similar in idea to a tensor.
In contrast to a tensor, an ArrayGrid is limited to low dimensions (1 to 4), only allowing a scalar,
vector, or matrix type, but all of them are represented as a static fixed-size const generic array.
Fixed-sized arrays allow for several compiler optimizations, including a cache aligned data layout and the removal of
runtime array boundary checks, because all structural parameters are known upfront, providing a significant
performance boost over tensors.


## Usage

Important details:

* All const generic parameters are requires regardless of which ArrayType you are using
* To change the ArrayGrid type, just change the enum and your good.
* There are no array bounds checks past compilation, so you have to ensure PointIndex does not exceed the Array boundaries.

```rust
use dcl_data_structures::prelude::{ArrayGrid, ArrayType, PointIndex};

// Consts dimensions requires for const generic paramaters
// Use these to check whether your PointIndex stays within the Array boundaries.
const WIDTH: usize = 5;
const HEIGHT: usize = 5;
const DEPTH: usize = 5;
const TIME: usize = 5;

pub fn main(){
    // Make a simple 1D Array of type usize
    let array_type = ArrayType::Array1D;
    let ag: ArrayGrid<usize, WIDTH, HEIGHT, DEPTH, TIME> = ArrayGrid::new(array_type);

    // Create a 1D index
    let p = PointIndex::new1d(1);

    // Store a usize with the point index
    ag.set(p, 42);

    // Get the usize for the point index
    let res = ag.get(p);
    assert_eq!(res, 42);
    
    // Make a custom struct 
    // ArrayGrid requires Copy + Default to store MyStuct
    #[derive(Debug, Default, Copy, Clone)]
    struct MyStruct{
        number: usize,
        mod_five: bool,
    }
    
    // Make a 4D array aka matrix over x,y,z that stores My struct
    // Notice, only the ArrayType changes to do that. 
    let array_type = ArrayType::Array4D;
    let ag: ArrayGrid<MyStruct, WIDTH, HEIGHT, DEPTH, TIME> = ArrayGrid::new(array_type);

    // Create a new 4D point index where only time varies
    let idx_t0 = PointIndex::new4d(1, 1, 1, 0);
    let idx_t1 = PointIndex::new4d(1, 1, 1, 1);
    let idx_t2 = PointIndex::new4d(1, 1, 1, 2);

    // Create some data for each index 
    let my_struct_t0 = MyStruct{ number: 23, mod_five: false };
    let my_struct_t1 = MyStruct{ number: 24, mod_five: false };
    let my_struct_t2 = MyStruct{ number: 25, mod_five: true };

    // Store data
    ag.set(idx_t0, my_struct_t0);
    ag.set(idx_t1, my_struct_t1);
    ag.set(idx_t2, my_struct_t2);

    // Get data at t2
    let res = ag.get(idx_t2);
    
    // Verify results
    let exp_number = 25;
    assert_eq!(res.number, exp_number);
    let exp_mod = true;
    assert_eq!(res.mod_five, exp_mod);
}
```

## Performance

The benchmark measures the performance of set operations on a 1D, 2D, 3D, and 4D ArryGrid.
Because of the const generic, the get operation performs at a near constant time O(1),
therefore the benchmark skips the get operation because there is nothing worth measuring.


### Performance Summary
- **1D Grid**: 604.71 ps (±5.01 ps) 
- **2D Grid**: 581.33 ps (±2.81 ps) 
- **3D Grid**: 862.16 ps (±13.60 ps) 
- **4D Grid**: 1.137 ns (±0.029 ns) 


### Key Observations
1. The 1D and 2D grid operations maintain excellent performance
2. Performance degrades progressively with higher dimensions, particularly noticeable in 3D and 4D operations
3. The 4D grid operations show the most significant performance impact, taking nearly twice as long as lower-dimensional operations

## Technical Details
- Sample size: 100 measurements per benchmark
- Outliers properly detected and handled (2-8% outliers per benchmark)
- All benchmarks were run with random access patterns to simulate real-world usage

## Hardware & OS
- Architecture: ARM64 (Apple Silicon, M3 Max)
- OS: macOS Darwin 24.1.0 (Seqoia 15.1)
- Kernel: XNU 11215.41.3~2
- Machine: MacBook Pro (T6031)

## Problem

DeepCausality allows fast and efficient adjustment of all values stored in a context hyper-graph.
Often, this requires the formulation of an adjustment matrix. The matrix can already be attached to each element of the
context graph but may require periodic updates depending on the required changes.

The exact adjustment for temporal-spatial data depends on the actual structure of the representative structure.
Theoretically, a tensor would be the preferred data structure to do so because a tensor allowing for multi-dimensional
adjustment representation with just a single structure. In practice, however, tensors incur a non-trivial overhead
leading to a significant performance penalty especially on low (<5) dimensional data. For adjusting values in a context
graph, no more than a 4D matrix is expected in practice hence a tensor really is unnecessary.
The root cause of the tensor performance problem comes from its complex object model that increases the number of CPU
cache misses because of a non-aligned data layout.

## Solution

In response, DeepCausality brings a custom data structure called a ArrayGrid that is indexed with a variable PointIndex
encoded as a struct. The difference to a tensor is that a tensor remains parametric over N dimensions, thus requiring a
complex object representation. In contrast, a Grid is limited to low dimensions (1 to 4), only allowing a scalar,
vector, or matrix type, but all of them are represented as a static fixed-size array. Fixed-sized arrays allow for
several compiler optimizations, including a cache aligned data layout and the removal of runtime array boundary checks,
because all structural parameters are known upfront, providing a significant performance boost over tensors.
Performance is critical because context hyper-graphs may grow large with millions of nodes, and obviously, one wants the
fastest possible global adjustment in those cases.

## Index

To index a grid of variable size, one have to deal with the reality that Rust does not support
variadic arguments. The frequently cited alternative of passing a vector instead bears the risk
of null index errors. Because the grid type is limited to 4D anyways, a simple struct with four usized
index variables is used. The trick is to set unused variables to zero during initialization to preserve
invariant signatures. The full point index type is show below. Here, X,Y,Z referring to 3D coordinates
with T referring to time as the fourth dimension.

```rust
/// A point used to index a GridArray up to four dimensions.
#[derive(Debug, Clone, Copy)]
pub struct PointIndex {
    pub x: usize, // Height 
    pub y: usize, // Width
    pub z: usize, // Depth
    pub t: usize, // Time
}

impl PointIndex{
    pub fn new1d(x: usize) -> Self {Self { x, y: 0, z: 0, t: 0 }}
    pub fn new2d(x: usize, y: usize) -> Self { Self { x, y, z: 0, t: 0 }}
    pub fn new3d(x: usize, y: usize, z: usize) -> Self { Self { x, y, z, t: 0 } }
    pub fn new4d(x: usize, y: usize, z: usize, t: usize) -> Self {Self { x, y, z, t }}
}
```

## Storage API

Because the grid type requires a different storage implementation for each of the four dimensions,
a storage API was designed based to abstract over the implementation details while retaining generic constant array
sizes
for best performance. The storage API is inspired by
the [graph storage API in Petgraph](https://github.com/petgraph/petgraph/issues/563).
Because not all four implementations can return the coordinates other than x (height),
the storage trait contains a default implementation that returns None by default for all other coordinates unless
the getter is overwritten by the implementing type.

```rust
use crate::prelude::PointIndex;

pub trait Storage<T>where  T: Copy {
    fn get(&self, p: PointIndex) -> &T;
    fn set(&mut self, p: PointIndex, elem: T);
    fn height(&self) -> Option<&usize>;
    fn depth(&self) -> Option<&usize> { None }
    fn time(&self) -> Option<&usize> { None }
    fn width(&self) -> Option<&usize> { None }
}
```

Note, the getter methods return an option to a reference instead of
a reference to an option to prevent accidental overwriting in case of mutual reference. Specifically, in case
of a reference to an option i,e, &Option<T>, the option value can be overwritten if the callsite holds a mutual
reference. If the storage contains data, the option would be Some, but the callsite, when holding a mutual reference,
could change the
this to a None and by doing so accidentally overwrite the containing data. Conversely, when returning an Option holding
a reference to the data, the option type cannot be change therefore some data remain some data.

## Storage Implementation

The magic of the grid types happens in the implementation of the storage trait. Theoretically,
one could use any heap allocated type, for example a vector. But because of the PointIndex, once
can also used a fixed sized array via const generics and therefore reach a significant performance gain.
To illustrate the technique, the 2D Matrix type is implemented over a 2D static array as shown below.
It's woth mentioning that the const generic array requires an additional type bound to Sized to prevent compiler errors.

```rust
impl<T, const W: usize, const H: usize> Storage<T> for [[T; W]; H]
    where
        T: Copy,
        [[T; W]; H]: Sized,
{
    fn get(&self, p: PointIndex) -> &T { &self[p.y][p.x] }
    fn set(&mut self, p: PointIndex, elem: T) { self[p.y][p.x] = elem }
    fn height(&self) -> Option<&usize> { Some(&H) }
    fn width(&self) -> Option<&usize> { Some(&W) }
}
```

Besides the set & get value, the 2D array implements the getter for x (height) and overwrites the getter for
w (width) as to expose the underlying array boundaries. Note, because we deal with const generics, the compiler
will remove all runtime array bound checks therefore we have to ensure that, for example, an index is within the
array bounds therefore each type must return all applicable bounds. The same pattern applies to the 3D and 4D type as
well.

## Grid Type

The grid type abstracts over the specific storage using the storage trait in its implementation, a common technique.
There are only a few considerations:

* Because Grid abstracts over Storage<T> without referencing T, we need a PhantomData binding for T
* Because Grid serves as a container abstraction, interior mutability is preferred via RefCell
* Because each storage implementation returns array bounds as Option with a reference to data, we have to dereference
  and return a value since we cannot return an internal reference.

```rust
#[derive(Debug, Clone)]
pub struct Grid<S, T>
    where
        T: Copy,
        S: Storage<T>,
{
    inner: RefCell<S>,  // Requiered for interior mutability
    ty: PhantomData<T>, // Required due to missing binding to type T
}

```

The main idea remains relatively simple, the specific storage gets injected via the constructor and stored in an RefCell
for interior mutability.
Because of the interior mutability, borrow and borrow_mut become required when accessing the storage as seen
in the set and get methods. Type T must implement Default because of the PhantomData binding in the type signature. The
complete Grid type implementation is relatively verbose, the listing below shows only the important parts.

```rust

impl<S, T> Grid<S, T>
    where
        T: Copy + Default,
        S: Storage<T>,
{
    pub fn new(storage: S) -> Self {
        Self {
            inner: RefCell::new(storage),
            ty: Default::default(),
        }
    }

    pub fn get(&self, p: PointIndex) -> T { self.inner.borrow().get(p).to_owned() }

    pub fn set(&self, p: PointIndex, value: T) { self.inner.borrow_mut().set(p, value); }

    pub fn depth(&self) -> Option<usize> { ...}
    pub fn height(&self) -> Option<usize> {...} 
```

The grid type is not meant to be used directly because it still requires the instantiation
of the underlying storage type before the grid type can be constructed. Instead, the GridArray abstracts over
all for storage implementations via algebraic types implemented as enums.

## ArrayGrid

When stepping back, it becomes obvious that each of the four different storage implementations have a different type
signature, which is inconvenient because one would rather have one single type to keep interfaces and function
signatures stable. Because each implementation uses const generic, the generic parameters also differ for each
implementation with the implication that a shared super type must have as much generic parameters as the
highest number of any available implementation, which is the 4DArray implementation. Also, because the
const generic array signatures become a bit hard to read over time, a handful of type aliases have been defined
as shown below.

```rust
// Fixed sized static ArrayGrid
pub type ArrayGrid1DType<T, const H: usize> = Grid<[T; H], T>;
pub type ArrayGrid2DType<T, const W: usize, const H: usize> = Grid<[[T; W]; H], T>;
pub type ArrayGrid3DType<T, const W: usize, const H: usize, const D: usize> = Grid<[[[T; W]; H]; D], T>;
pub type ArrayGrid4DType<T, const W: usize, const H: usize, const D: usize, const C: usize> = Grid<[[[[T; W]; H]; D]; C], T>;
```

Next, we need an enum to identify each of the four storage implementations. A basic enum suffice in this case
as we only need them for identification reasons.

```rust
pub enum ArrayType {
    Array1D,
    Array2D,
    Array3D,
    Array4D,
}
```

The magic of the ArrayGrid type comes in form of an algebraic type encoded as type enum for which each value may contain
an actual instance of the corresponding storage. Because of the previously mentioned const generic requirement, this
enum must have generic parameters over all four dimensional types plus the actual type t that is stored, totalling
in five generic parameters. At this point it becomes painfully obvious why the number of implementations was
deliberately restricted up to a 4D Matrix.

```rust
// T Type
// W Width
// H Height
// D Depth
// C Chronos (Time) since T was already taken for Type T
pub enum ArrayGrid<T, const W: usize, const H: usize, const D: usize, const C: usize>
    where
        T: Copy,
{
    ArrayGrid1D(ArrayGrid1DType<T, H>),
    ArrayGrid2D(ArrayGrid2DType<T, W, H>),
    ArrayGrid3D(ArrayGrid3DType<T, W, H, D>),
    ArrayGrid4D(ArrayGrid4DType<T, W, H, D, C>),
}
```

The type aliases make the enum type signatures quite a bit more human readable and actually help to verify
the correct type embedding. The implementation of the ArrayGrid is split into three parts:

1) Constructor
2) API
3) Getters

**Constructor**

The constructor follows the standard pattern of implementing the an enum type. Ignoring the generic type signature,
all the constructor does it takes the ArrayType enum, matches it and for the match creates a new Grid with the correct
dimensions and storage implementations. Default for type T is required for the PhantomData binding in the Grid
implementation.

```rust
impl<T, const W: usize, const H: usize, const D: usize, const C: usize> ArrayGrid<T, W, H, D, C>
    where
        T: Copy + Default,
{
    pub fn new(array_type: ArrayType) -> ArrayGrid<T, W, H, D, C> {
        match array_type {
            ArrayType::Array1D => ArrayGrid::ArrayGrid1D(Grid::new([T::default(); H])),
            ArrayType::Array2D => ArrayGrid::ArrayGrid2D(Grid::new([[T::default(); W]; H])),
            ArrayType::Array3D => ArrayGrid::ArrayGrid3D(Grid::new([[[T::default(); W]; H]; D])),
            ArrayType::Array4D => ArrayGrid::ArrayGrid4D(Grid::new([[[[T::default(); W]; H]; D]; C])),
        }
    }
}
```

**API**

The API is relatively simple and only sets or gets a value of type T. Considering the intended use case
as adjustment matrix, get and set will be the most commonly used operations. Notice, the standard API does
not exposes array dimensions. While it would be possible, matching over each enum type feels cumbersome for
a questionable gain. Instead, low level access to the underlying grid is possible through the getter.

```rust
impl<T, const W: usize, const H: usize, const D: usize, const C: usize> ArrayGrid<T, W, H, D, C>
    where
        T: Copy + Default,
{
    pub fn get(&self, p: PointIndex) -> T {
        match self {
            ArrayGrid::ArrayGrid1D(grid) => { grid.get(p) }
            ArrayGrid::ArrayGrid2D(grid) => { grid.get(p) }
            ArrayGrid::ArrayGrid3D(grid) => { grid.get(p) }
            ArrayGrid::ArrayGrid4D(grid) => { grid.get(p) }
        }
    }

    pub fn set(&self, p: PointIndex, value: T) {
        match self {
            ArrayGrid::ArrayGrid1D(grid) => { grid.set(p, value) }
            ArrayGrid::ArrayGrid2D(grid) => { grid.set(p, value) }
            ArrayGrid::ArrayGrid3D(grid) => { grid.set(p, value) }
            ArrayGrid::ArrayGrid4D(grid) => { grid.set(p, value) }
        }
    }
}
```

**Getters**

There are use cases where a more low level access to the underlying grid implementation might be warranted and
in that case the grid can be retrieved via the corresponding getter. Notice, the the return type is an option with
a reference for the same reasons as discussed earlier: preventing accidental data loss in case of a mutable reference.
The other reason for returning an option is that the enum stores, say a 2D Grid, but all other variants are set to
None by default. In case the callsite accidentally calls the wrong getter, the option check makes the mistake clear.

```rust
impl<T, const W: usize, const H: usize, const D: usize, const C: usize> ArrayGrid<T, W, H, D, C>
    where
        T: Copy + Default,
{
    pub fn array_grid_1d(&self) -> Option<&ArrayGrid1DType<T, H>>
    {
        if let ArrayGrid::ArrayGrid1D(array_grid) = self {
            Some(array_grid)
        } else {
            None
        }
    }

    pub fn array_grid_2d(&self) -> Option<&ArrayGrid2DType<T, W, H>> { ... }
    pub fn array_grid_3d(&self) -> Option<&ArrayGrid3DType<T, W, H, D>> { ... }
    pub fn array_grid_4d(&self) -> Option<&ArrayGrid4DType<T, W, H, D, C>> { ... }
```

## Usage

At this point, the reader may wonder how all the above will be used?
In practice, there are three steps requires to build an ArrayGrid:

1) Define constant array boundaries.
2) Set the storage type
3) Construct an ArrayGrid with a chosen type

```rust
// 1) Define constant array boundaries.
const WIDTH: usize = 5;
const HEIGHT: usize = 5;
const DEPTH: usize = 5;
const TIME: usize = 5;

    // 2) Set the storage type. Use float64 in this case 
    let storage = [[0.0f64; WIDTH]; HEIGHT];

    // 3) Construct an ArrayGrid with a chosen type 
    let array_type = Array2D;
    let ag: ArrayGrid<usize, WIDTH, HEIGHT, DEPTH, TIME> = ArrayGrid::new(array_type);

    // Create an index 
    let p = PointIndex::new2d(1, 2);
    
    // set a value 
    ag.set(p, 2);
    
    // get a value 
    let res = ag.get(p);
    
    // Make it a 3D Matrix
    let array_type = Array3D;
    let ag: ArrayGrid<usize, WIDTH, HEIGHT, DEPTH, TIME> = ArrayGrid::new(array_type);
    
    // set and get values in a 3D Matrix
    let p = PointIndex::new3d(1, 2, 3);
    ag.set(p, 3);
    let res = ag.get(p);
    
    // Low level access to the 3D grid
      let g = ag.array_grid_3d()
        .expect("failed to create array grid");

    assert_eq!(g.height().unwrap(), HEIGHT);
    assert_eq!(g.width().unwrap(), WIDTH);
    assert_eq!(g.depth().unwrap(), DEPTH);
```

One important detail is that the ArrayGrid constructor requires all generic parameter regardless of
which specific storage will be instantiated. When writing a library that, for example, at most relies on
a 2D Matrix, then its best to set the remaining const generic values (Depth, Time) to one. As explained above,
there is no practical way around this requirement. Another observation is that the ArrayGrid type, once created,
behaves like any other API with the added bonus of interior mutability.
