use arbitrary::Unstructured;
use dlmalloc::Dlmalloc;
use rand::{rngs::SmallRng, RngCore, SeedableRng};

#[test]
fn smoke() {
    let mut a = Dlmalloc::new();
    unsafe {
        let ptr = a.malloc(1, 1);
        assert!(!ptr.is_null());
        *ptr = 9;
        assert_eq!(*ptr, 9);
        a.free(ptr, 1, 1);

        let ptr = a.malloc(1, 1);
        assert!(!ptr.is_null());
        *ptr = 10;
        assert_eq!(*ptr, 10);
        a.free(ptr, 1, 1);
    }
}

#[test]
fn c_round_trip() {
    let mut a = Dlmalloc::new();
    unsafe {
        let ptr = a.c_malloc(32);
        assert!(!ptr.is_null());
        ptr.write_bytes(0xab, 32);
        assert_eq!(*ptr, 0xab);
        assert_eq!(*ptr.add(31), 0xab);

        let grown = a.c_realloc(ptr, 128);
        assert!(!grown.is_null());
        for i in 0..32 {
            assert_eq!(*grown.add(i), 0xab);
        }
        grown.add(32).write_bytes(0xcd, 96);
        assert_eq!(*grown.add(127), 0xcd);

        let shrunk = a.c_realloc(grown, 16);
        assert!(!shrunk.is_null());
        for i in 0..16 {
            assert_eq!(*shrunk.add(i), 0xab);
        }

        a.c_free(shrunk);
    }
}

#[test]
fn c_null_handling() {
    let mut a = Dlmalloc::new();
    unsafe {
        a.c_free(core::ptr::null_mut());

        let ptr = a.c_realloc(core::ptr::null_mut(), 64);
        assert!(!ptr.is_null());
        ptr.write_bytes(0x5a, 64);
        assert_eq!(*ptr, 0x5a);
        assert_eq!(*ptr.add(63), 0x5a);
        a.c_free(ptr);
    }
}

#[test]
fn c_memalign_round_trip() {
    let mut a = Dlmalloc::new();
    unsafe {
        for &align in &[1usize, 2, 8, 16, 32, 64, 256, 4096] {
            let ptr = a.c_memalign(align, 96);
            assert!(!ptr.is_null(), "c_memalign({align}, 96) failed");
            assert_eq!(
                (ptr as usize) & (align - 1),
                0,
                "ptr {ptr:p} not aligned to {align}"
            );
            ptr.write_bytes(0x77, 96);
            assert_eq!(*ptr, 0x77);
            assert_eq!(*ptr.add(95), 0x77);

            let grown = a.c_realloc(ptr, 256);
            assert!(!grown.is_null());
            for i in 0..96 {
                assert_eq!(*grown.add(i), 0x77);
            }

            a.c_free(grown);
        }
    }
}

#[test]
fn mixed_api_round_trip() {
    let mut a = Dlmalloc::new();
    let natural = core::mem::size_of::<usize>() * 2;
    unsafe {
        // c_malloc -> layout-carrying free
        let ptr = a.c_malloc(64);
        assert!(!ptr.is_null());
        ptr.write_bytes(0x11, 64);
        a.free(ptr, 64, natural);

        // layout-carrying malloc -> c_free
        let ptr = a.malloc(64, natural);
        assert!(!ptr.is_null());
        ptr.write_bytes(0x22, 64);
        a.c_free(ptr);

        // c_malloc -> layout-carrying realloc -> c_free
        let ptr = a.c_malloc(48);
        assert!(!ptr.is_null());
        ptr.write_bytes(0x33, 48);
        let grown = a.realloc(ptr, 48, natural, 192);
        assert!(!grown.is_null());
        for i in 0..48 {
            assert_eq!(*grown.add(i), 0x33);
        }
        a.c_free(grown);

        // layout-carrying malloc -> c_realloc -> layout-carrying free
        let ptr = a.malloc(48, natural);
        assert!(!ptr.is_null());
        ptr.write_bytes(0x44, 48);
        let grown = a.c_realloc(ptr, 192);
        assert!(!grown.is_null());
        for i in 0..48 {
            assert_eq!(*grown.add(i), 0x44);
        }
        a.free(grown, 192, natural);

        // over-aligned c_memalign -> c_free
        let ptr = a.c_memalign(4096, 96);
        assert!(!ptr.is_null());
        assert_eq!((ptr as usize) & (4096 - 1), 0);
        ptr.write_bytes(0x55, 96);
        a.c_free(ptr);

        // over-aligned c_memalign -> layout-carrying free
        let ptr = a.c_memalign(4096, 96);
        assert!(!ptr.is_null());
        assert_eq!((ptr as usize) & (4096 - 1), 0);
        ptr.write_bytes(0x66, 96);
        a.free(ptr, 96, 4096);

        // over-aligned c_memalign -> layout-carrying realloc preserves
        // alignment, then layout-carrying free
        let ptr = a.c_memalign(4096, 96);
        assert!(!ptr.is_null());
        assert_eq!((ptr as usize) & (4096 - 1), 0);
        ptr.write_bytes(0x77, 96);
        let grown = a.realloc(ptr, 96, 4096, 256);
        assert!(!grown.is_null());
        assert_eq!(
            (grown as usize) & (4096 - 1),
            0,
            "layout-carrying realloc must preserve over-alignment"
        );
        for i in 0..96 {
            assert_eq!(*grown.add(i), 0x77);
        }
        a.free(grown, 256, 4096);
    }
}

#[path = "../fuzz/src/lib.rs"]
mod fuzz;

#[test]
fn stress() {
    let mut rng = SmallRng::seed_from_u64(0);
    let mut buf = vec![0; 4096];
    let iters = if cfg!(miri) { 5 } else { 2000 };
    for _ in 0..iters {
        rng.fill_bytes(&mut buf);
        let mut u = Unstructured::new(&buf);
        let _ = fuzz::run(&mut u);
    }
}

// Exercises the public configuration API (`set_max_release_check_rate`,
// `set_granularity`) end-to-end through the `Dlmalloc<System>` wrapper,
// configured via a `const` block to also verify the const-fn chain.
#[test]
fn configurable_api_smoke() {
    let mut a = const {
        let mut a = Dlmalloc::new();
        assert!(a.set_granularity(64 * 1024));
        a.set_max_release_check_rate(4);
        a
    };

    // Disable, then re-enable: with the bug present this would leave the
    // countdown stuck at usize::MAX and the rate change silently ignored.
    a.set_max_release_check_rate(0);
    a.set_max_release_check_rate(4);

    unsafe {
        // A few rounds of large-chunk alloc/free to tick the release
        // countdown to zero and trip the periodic pass.
        for _ in 0..16 {
            let p1 = a.malloc(4096, 8);
            let p2 = a.malloc(4096, 8);
            assert!(!p1.is_null());
            assert!(!p2.is_null());
            a.free(p1, 4096, 8);
            a.free(p2, 4096, 8);
        }
    }

    // set_granularity rejects invalid values and accepts valid ones,
    // including sub-page values down to `2 * size_of::<usize>()`.
    assert!(!a.set_granularity(0));
    assert!(!a.set_granularity(64 * 1024 + 1));
    assert!(!a.set_granularity(core::mem::size_of::<usize>())); // below malloc_alignment
    assert!(a.set_granularity(2 * core::mem::size_of::<usize>())); // exactly malloc_alignment
    assert!(a.set_granularity(64 * 1024));
}

// Sub-page granularity end-to-end through the public API. The system
// allocator on Linux/macOS will round each request up to its page size,
// so this primarily exercises the dlmalloc-side accounting; on embedded
// targets it also packs allocations tightly into the application heap.
// Skipped under miri: with 32-byte granularity, chunks are packed tightly
// enough that small-bin unlink paths get exercised in a way that trips
// dlmalloc-rs's pre-existing Stacked Borrows quirk with `smallbins`
// self-aliasing (the internal `custom_sub_page_granularity_alloc_free`
// test in `src/dlmalloc.rs` is skipped for the same reason).
#[test]
#[cfg(not(miri))]
fn sub_page_granularity_alloc_free() {
    let sub_page = 4 * core::mem::size_of::<usize>();
    let mut a = Dlmalloc::new();
    assert!(a.set_granularity(sub_page));
    unsafe {
        let mut ptrs = [core::ptr::null_mut::<u8>(); 8];
        for (i, slot) in ptrs.iter_mut().enumerate() {
            let p = a.malloc(32 + i * 5, 8);
            assert!(!p.is_null());
            *p = i as u8;
            *slot = p;
        }
        for (i, &p) in ptrs.iter().enumerate() {
            assert_eq!(*p, i as u8);
            a.free(p, 32 + i * 5, 8);
        }
    }
}
