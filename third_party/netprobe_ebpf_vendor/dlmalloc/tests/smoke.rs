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
