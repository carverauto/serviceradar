use criterion::{
    BatchSize, BenchmarkGroup, Criterion, criterion_group, criterion_main, measurement::Measurement,
};
use crypto_bigint::{
    BoxedUint, Odd, RandomBits, RandomMod,
    modular::{BoxedMontyForm, BoxedMontyParams},
};
use num_bigint::BigUint;
use rand_chacha::ChaChaRng;
use rand_core::SeedableRng;
use std::hint::black_box;

/// Size of `BoxedUint` to use in benchmark.
const UINT_BITS: u32 = 4096;

fn to_biguint(uint: &BoxedUint) -> BigUint {
    BigUint::from_bytes_be(&uint.to_be_bytes())
}

fn bench_montgomery_ops<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let mut rng = ChaChaRng::from_os_rng();
    let params = BoxedMontyParams::new(Odd::<BoxedUint>::random(&mut rng, UINT_BITS));

    group.bench_function(format!("add, {UINT_BITS}-bit"), |b| {
        b.iter_batched(
            || {
                let a = BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                );
                let b = BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                );
                (a, b)
            },
            |(a, b)| black_box(a).add(&black_box(b)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function(format!("double, {UINT_BITS}-bit"), |b| {
        b.iter_batched(
            || {
                BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                )
            },
            |a| black_box(a).double(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function(format!("sub, {UINT_BITS}-bit"), |b| {
        b.iter_batched(
            || {
                let a = BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                );
                let b = BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                );
                (a, b)
            },
            |(a, b)| black_box(a).sub(&black_box(b)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function(format!("neg, {UINT_BITS}-bit"), |b| {
        b.iter_batched(
            || {
                BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                )
            },
            |a| black_box(a).neg(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function(format!("invert, {UINT_BITS}-bit"), |b| {
        b.iter_batched(
            || {
                BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                )
            },
            |x| black_box(x).invert(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("multiplication, BoxedUint*BoxedUint", |b| {
        b.iter_batched(
            || {
                let x = BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                );
                let y = BoxedMontyForm::new(
                    BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                    params.clone(),
                );
                (x, y)
            },
            |(x, y)| black_box(x * y),
            BatchSize::SmallInput,
        )
    });

    let modulus = to_biguint(params.modulus());
    group.bench_function("multiplication, BigUint*BigUint (num-bigint-dig)", |b| {
        b.iter_batched(
            || {
                let x = to_biguint(&BoxedUint::random_bits(&mut rng, UINT_BITS)) % &modulus;
                let y = to_biguint(&BoxedUint::random_bits(&mut rng, UINT_BITS)) % &modulus;
                (x, y)
            },
            |(x, y)| x * y % &modulus,
            BatchSize::SmallInput,
        )
    });

    let m = Odd::<BoxedUint>::random(&mut rng, UINT_BITS);
    let params = BoxedMontyParams::new(m);
    group.bench_function("modpow, BoxedUint^BoxedUint", |b| {
        b.iter_batched(
            || {
                let x = BoxedUint::random_bits(&mut rng, UINT_BITS);
                let x_m = BoxedMontyForm::new(x, params.clone());
                let p = BoxedUint::random_bits(&mut rng, UINT_BITS)
                    | (BoxedUint::one_with_precision(UINT_BITS) << (UINT_BITS - 1));
                (x_m, p)
            },
            |(x, p)| black_box(x.pow(&p)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("modpow, BigUint^BigUint (num-bigint-dig)", |b| {
        b.iter_batched(
            || {
                let x = to_biguint(&BoxedUint::random_bits(&mut rng, UINT_BITS));
                let x_m = x % &modulus;
                let p = to_biguint(
                    &(BoxedUint::random_bits(&mut rng, UINT_BITS)
                        | (BoxedUint::one_with_precision(UINT_BITS) << (UINT_BITS - 1))),
                );
                (x_m, p)
            },
            |(x, p)| black_box(x.modpow(&p, &modulus)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function(
        "lincomb_vartime, BoxedUint*BoxedUint+BoxedUint*BoxedUint",
        |b| {
            b.iter_batched(
                || {
                    BoxedMontyForm::new(
                        BoxedUint::random_mod(&mut rng, params.modulus().as_nz_ref()),
                        params.clone(),
                    )
                },
                |a| {
                    BoxedMontyForm::lincomb_vartime(&[
                        (black_box(&a), black_box(&a)),
                        (black_box(&a), black_box(&a)),
                    ])
                },
                BatchSize::SmallInput,
            )
        },
    );
}

fn bench_montgomery_conversion<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let mut rng = ChaChaRng::from_os_rng();
    group.bench_function("BoxedMontyParams::new", |b| {
        b.iter_batched(
            || Odd::<BoxedUint>::random(&mut rng, UINT_BITS),
            |modulus| black_box(BoxedMontyParams::new(modulus)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("BoxedMontyParams::new_vartime", |b| {
        b.iter_batched(
            || Odd::<BoxedUint>::random(&mut rng, UINT_BITS),
            |modulus| black_box(BoxedMontyParams::new_vartime(modulus)),
            BatchSize::SmallInput,
        )
    });

    let params = BoxedMontyParams::new(Odd::<BoxedUint>::random(&mut rng, UINT_BITS));
    group.bench_function("BoxedMontyForm::new", |b| {
        b.iter_batched(
            || BoxedUint::random_bits(&mut rng, UINT_BITS),
            |x| black_box(BoxedMontyForm::new(x, params.clone())),
            BatchSize::SmallInput,
        )
    });

    let params = BoxedMontyParams::new(Odd::<BoxedUint>::random(&mut rng, UINT_BITS));
    group.bench_function("BoxedMontyForm::retrieve", |b| {
        b.iter_batched(
            || BoxedMontyForm::new(BoxedUint::random_bits(&mut rng, UINT_BITS), params.clone()),
            |x| black_box(x.retrieve()),
            BatchSize::SmallInput,
        )
    });
}

fn bench_montgomery(c: &mut Criterion) {
    let mut group = c.benchmark_group("Boxed Montgomery arithmetic");
    bench_montgomery_conversion(&mut group);
    bench_montgomery_ops(&mut group);
    group.finish();
}

criterion_group!(benches, bench_montgomery);

criterion_main!(benches);
