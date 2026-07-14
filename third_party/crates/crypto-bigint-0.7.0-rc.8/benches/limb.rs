use criterion::{
    BatchSize, BenchmarkGroup, Criterion, criterion_group, criterion_main, measurement::Measurement,
};
use crypto_bigint::{Limb, Random};
use rand_chacha::ChaChaRng;
use rand_core::SeedableRng;
use std::hint::black_box;
use subtle::{ConstantTimeEq, ConstantTimeGreater, ConstantTimeLess};

fn bench_cmp<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let mut rng = ChaChaRng::from_os_rng();
    group.bench_function("ct_lt", |b| {
        b.iter_batched(
            || {
                let x = Limb::random(&mut rng);
                let y = Limb::random(&mut rng);
                (x, y)
            },
            |(x, y)| black_box(x.ct_lt(&y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("ct_eq", |b| {
        b.iter_batched(
            || {
                let x = Limb::random(&mut rng);
                let y = Limb::random(&mut rng);
                (x, y)
            },
            |(x, y)| black_box(x.ct_eq(&y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("ct_gt", |b| {
        b.iter_batched(
            || {
                let x = Limb::random(&mut rng);
                let y = Limb::random(&mut rng);
                (x, y)
            },
            |(x, y)| black_box(x.ct_gt(&y)),
            BatchSize::SmallInput,
        )
    });
}

fn bench_ops(c: &mut Criterion) {
    let mut group = c.benchmark_group("ops");
    bench_cmp(&mut group);
    group.finish();
}

criterion_group!(benches, bench_ops);

criterion_main!(benches);
