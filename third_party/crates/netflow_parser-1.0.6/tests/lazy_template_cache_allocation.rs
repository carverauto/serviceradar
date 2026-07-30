use netflow_parser::NetflowParser;
use std::alloc::{GlobalAlloc, Layout, System};
use std::hint::black_box;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

struct CountingAllocator;

static TRACKING: AtomicBool = AtomicBool::new(false);
static REQUESTED_BYTES: AtomicUsize = AtomicUsize::new(0);
static LIVE_BYTES: AtomicUsize = AtomicUsize::new(0);

fn record_allocation(size: usize) {
    if TRACKING.load(Ordering::Relaxed) {
        REQUESTED_BYTES.fetch_add(size, Ordering::Relaxed);
    }
}

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() {
            LIVE_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
            record_allocation(layout.size());
        }
        pointer
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc_zeroed(layout) };
        if !pointer.is_null() {
            LIVE_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
            record_allocation(layout.size());
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        LIVE_BYTES.fetch_sub(layout.size(), Ordering::Relaxed);
        unsafe { System.dealloc(pointer, layout) };
    }

    unsafe fn realloc(&self, pointer: *mut u8, old: Layout, new_size: usize) -> *mut u8 {
        let new_pointer = unsafe { System.realloc(pointer, old, new_size) };
        if !new_pointer.is_null() {
            if new_size >= old.size() {
                LIVE_BYTES.fetch_add(new_size - old.size(), Ordering::Relaxed);
            } else {
                LIVE_BYTES.fetch_sub(old.size() - new_size, Ordering::Relaxed);
            }
            record_allocation(new_size);
        }
        new_pointer
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

#[test]
fn parser_construction_does_not_reserve_template_cache_storage() {
    // Warm process-global allocator and hashing state before measuring the parser.
    drop(NetflowParser::builder().with_cache_size(1).build().unwrap());

    let baseline = LIVE_BYTES.load(Ordering::SeqCst);
    REQUESTED_BYTES.store(0, Ordering::SeqCst);
    TRACKING.store(true, Ordering::SeqCst);
    let parser = black_box(NetflowParser::default());
    TRACKING.store(false, Ordering::SeqCst);

    let requested = REQUESTED_BYTES.load(Ordering::SeqCst);
    let retained = LIVE_BYTES.load(Ordering::SeqCst).saturating_sub(baseline);
    eprintln!("parser construction requested={requested} retained={retained}");

    const CONSTRUCTION_BUDGET: usize = 16 * 1024;
    assert!(
        requested <= CONSTRUCTION_BUDGET,
        "parser construction requested {requested} bytes; template caches must allocate on first use"
    );
    assert!(
        retained <= CONSTRUCTION_BUDGET,
        "parser construction retained {retained} bytes; template caches must allocate on first use"
    );

    drop(parser);

    let mut parser = NetflowParser::builder()
        .with_cache_size(100_000)
        .build()
        .unwrap();
    let template = [
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 12, 1, 0, 0, 1, 0,
        1, 0, 4,
    ];
    REQUESTED_BYTES.store(0, Ordering::SeqCst);
    TRACKING.store(true, Ordering::SeqCst);
    let result = black_box(parser.parse_bytes(&template));
    TRACKING.store(false, Ordering::SeqCst);

    assert!(result.error.is_none());
    assert_eq!(parser.v9_cache_info().current_size, 1);
    assert_eq!(parser.v9_cache_info().max_size_per_cache, 100_000);
    let requested = REQUESTED_BYTES.load(Ordering::SeqCst);
    eprintln!("first template insertion requested={requested}");
    assert!(
        requested <= 64 * 1024,
        "first template insertion requested {requested} bytes; the cache must grow incrementally"
    );
}
