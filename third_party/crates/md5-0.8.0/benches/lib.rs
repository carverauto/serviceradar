#![feature(test)]

extern crate test;

use md5::Context;

macro_rules! implement(
    ($($size:literal => ($compute:ident, $context:ident),)*) => ($(
        #[bench]
        fn $compute(bencher: &mut test::Bencher) {
            compute($size, bencher);
        }

        #[bench]
        fn $context(bencher: &mut test::Bencher) {
            context($size, bencher);
        }
    )*);
);

implement! {
    1000    => (compute_0001000, context_0001000),
    10000   => (compute_0010000, context_0010000),
    100000  => (compute_0100000, context_0100000),
    1000000 => (compute_1000000, context_1000000),
}

fn compute(size: usize, bencher: &mut test::Bencher) {
    let data = vec![0xffu8; size];
    bencher.iter(|| {
        test::black_box(md5::compute(&data));
    });
}

fn context(size: usize, bencher: &mut test::Bencher) {
    let data = vec![0xffu8; size];
    bencher.iter(|| {
        let mut context = Context::new();
        context.consume(&data);
        test::black_box(context.finalize());
    });
}
