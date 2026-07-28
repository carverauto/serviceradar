[//]: # (---)

[//]: # (SPDX-License-Identifier: MIT)

[//]: # (---)

# sliding_window

This sliding window implementation over-allocates to trade space (memory) for time complexity by delaying expensive
array copy operations.
Specifically, for a sliding window of size N, the number of elements that can be hold without any array copy
is approx C-1, where C is the total capacity defined as NxM with M as a multiple.

For example, if the window size N is 7, and the multiple M is 7, then the max capacity C is 49 (7*7),
means the sliding window can hold up to 48 elements before a rewind occurs.

Two different implementations are available:

1) Vector backed
2) Array backed

## Vector backed implementation

Take window size N and multiple M as arguments

See:

* [Benchmark](benches/benchmarks)
* [Code](src/window_type/)
* [Test](tests/window_type/)

## Array backed implementation

Takes window size SIZE and a CAPACITY as generic parameters.
This is because static arrays requiring const generics parameter.

See:

* [Benchmark](benches/benchmarks/)
* [Code](src/window_type)
* [Test](tests/window_type)

## Configuration

When N is reasonable small (1 ... 50), then only M determines the performance. In this case, a multiple of 100 to 1000,
gives an additional 30% to 50% performance boost over a comparable small multiplier (2 to 10). However,
when the total capacity exceeds a certain threshold, performance deteriorates significantly because of increased CPU
cache misses. The exact threshold depends on the actual CPU cache size and CPU type.

Therefore, it is generally recommended to run benchmarks with various configurations
to determine the best total capacity based on N and M. When the window size N is known to be fixed,
then it's best to run an optimizer to find the best value for M that maximizes total write throughput.

## Usage


Important details:

* ArrayStorage and VectorStorage have different signatures because only ArrayStorage requires const generics
* Size refers to the maximum number of elements the sliding window can store.
* Capacity refers to the maximum number of elements before a rewind occurs.

```rust
use dcl_data_structures::prelude::{ArrayStorage, SlidingWindow,sliding_window};

// Size refers to the maximum number of elements the sliding window can store.
const SIZE: usize = 4;
// Capacity refers to the maximum number of elements before a rewind occurs.
// Note, CAPACITY > SIZE and capacity should be a multiple of size.
// For example, size 4 should be stored 300 times before rewind;
// 4 * 300 = 1200
const CAPACITY: usize = 1200;

// Util function that helps with type inference.
fn get_sliding_window() -> SlidingWindow<ArrayStorage<Data, SIZE, CAPACITY>, Data> {
    sliding_window::new_with_array_storage()
}

pub fn main(){
    let mut window = get_sliding_window();
    assert_eq!(window.size(), SIZE);

    // Filled means, the window holds 4 elements. 
    assert!(!window.filled());

    // If you try to access an element before the window id filled, you get an error.
    let res = window.first();
    assert!(res.is_err());

    let res = window.last();
    assert!(res.is_err());

    // Add some data
    window.push(Data { dats: 3 });
    window.push(Data { dats: 2 });
    window.push(Data { dats: 1 });
    window.push(Data { dats: 0 });
    assert!(window.filled());

    // Now we can access elements of the window
    // Last element added was 0
    let res = window.last();
    assert!(res.is_ok());
    let data = res.unwrap();
    assert_eq!(data.dats, 0);

    // First (oldest) element added was 3
    let res = window.first();
    assert!(res.is_ok());
    let data = res.unwrap();
    assert_eq!(data.dats, 3);

    // When we add more data after the window filled,
    // the "last" element refers to the last added
    // and the oldest element will be dropped.
    let d = Data { dats: 42 };
    window.push(d);

    let res = window.last();
    assert!(res.is_ok());

    let data = res.unwrap();
    assert_eq!(data.dats, 42);

    // Because 42 was added at the front,
    // 3 was dropped at the end therefore
    // the oldest element is now 2
    let res = window.first();
    assert!(res.is_ok());
    let data = res.unwrap();
    assert_eq!(data.dats, 2);
}
```

## Performance

### Single Push Operations

| Implementation      	| Single Push Time 	| Notes                                                	|
|----------------|----------------|--------------------------| 
| ArrayStorage | ~2.08ns | Good balance | 
| VectorStorage | ~2.5ns | Most flexible |

Batch Operations (100 elements)

| Implementation      	| Batch Push Time 	 | Notes                                                	|
|----------------|----------------|--------------------------| 
| ArrayStorage | ~1.95ns           | Consistent performance |
| VectorStorage | ~2.3ns            | Predictable scaling |

Sequential Operations

| Implementation | Operation Time | Notes                    | 
|----------------|----------------|--------------------------| 
| ArrayStorage | ~605ps | Excellent cache locality | 
| VectorStorage | ~850ps | Most predictable         |


## Technical Details
- Sample size: 100 measurements per benchmark
- Outliers properly detected and handled (2-8% outliers per benchmark)
- All benchmarks were run with random access patterns to simulate real-world usage


## Hardware & OS
- Architecture: ARM64 (Apple Silicon, M3 Max)
- OS: macOS Darwin 24.1.0
- Kernel: XNU 11215.41.3~2
- Machine: MacBook Pro (T6031)

# Implementation Details

**Memory Layout**
* Contiguous stack memory allocation
* Better cache line utilization
* No heap allocation overhead

**Optimized Head Management**
* Branchless head adjustment
* Reduced CPU pipeline stalls
* Better branch prediction

**Direct Memory Access**
* No safety abstractions overhead
* Minimal pointer indirection 

## When to Use Each Implementation

### ArrayStorage

✅ Use When:
* Safety is a primary concern 
* Performance needs are moderate to high
* Window size is fixed
* Code maintainability is important

❌ Avoid When:
* Dynamic sizing is required
* Absolute maximum performance is needed

### VectorStorage
✅ Use When:
* Dynamic sizing is needed
* Memory usage varies significantly
* Code safety is critical
* Flexibility is key

❌ Avoid When:
* Fixed size windows are used
* Performance is critical
* Memory is constrained


### Recommendation
**Start with ArrayStorage**
* Safe default choice
* Good performance characteristics
* Easy to maintain and debug

**Use VectorStorage variants if:**
Dynamic sizing is required
Safety is more important than performance
Memory usage patterns are unpredictable

### Remember to benchmark with your specific use case:

Performance can vary based on
* Window size
* Data types
* Access patterns
* System architecture
* CPU type