use criterion::{
    BatchSize, BenchmarkGroup, Criterion, criterion_group, criterion_main, measurement::Measurement,
};
use crypto_bigint::{Random, RandomMod, U256, const_monty_params, modular::ConstMontyParams};
use rand_chacha::ChaChaRng;
use rand_core::SeedableRng;
use std::hint::black_box;

#[cfg(feature = "alloc")]
use crypto_bigint::MultiExponentiate;

const_monty_params!(
    Modulus,
    U256,
    "7fffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
);

type ConstMontyForm = crypto_bigint::modular::ConstMontyForm<Modulus, { U256::LIMBS }>;

fn bench_montgomery_conversion<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let mut rng = ChaChaRng::from_os_rng();
    group.bench_function("ConstMontyForm creation", |b| {
        b.iter_batched(
            || U256::random_mod(&mut rng, Modulus::PARAMS.modulus().as_nz_ref()),
            |x| black_box(ConstMontyForm::new(&x)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("ConstMontyForm retrieve", |b| {
        b.iter_batched(
            || ConstMontyForm::random(&mut rng),
            |x| black_box(x.retrieve()),
            BatchSize::SmallInput,
        )
    });
}

fn bench_montgomery_ops<M: Measurement>(group: &mut BenchmarkGroup<'_, M>) {
    let mut rng = ChaChaRng::from_os_rng();

    group.bench_function("add, U256", |b| {
        b.iter_batched(
            || {
                let a = ConstMontyForm::random(&mut rng);
                let b = ConstMontyForm::random(&mut rng);
                (a, b)
            },
            |(a, b)| black_box(a).add(&black_box(b)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("double, U256", |b| {
        b.iter_batched(
            || ConstMontyForm::random(&mut rng),
            |a| black_box(a).double(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("sub, U256", |b| {
        b.iter_batched(
            || {
                let a = ConstMontyForm::random(&mut rng);
                let b = ConstMontyForm::random(&mut rng);
                (a, b)
            },
            |(a, b)| black_box(a).sub(&black_box(b)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("neg, U256", |b| {
        b.iter_batched(
            || ConstMontyForm::random(&mut rng),
            |a| black_box(a).neg(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("invert, U256", |b| {
        b.iter_batched(
            || ConstMontyForm::random(&mut rng),
            |x| black_box(x).invert(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("multiplication, U256*U256", |b| {
        b.iter_batched(
            || {
                let x = ConstMontyForm::random(&mut rng);
                let y = ConstMontyForm::random(&mut rng);
                (x, y)
            },
            |(x, y)| black_box(x).mul(&black_box(y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("squaring, U256*U256", |b| {
        b.iter_batched(
            || ConstMontyForm::random(&mut rng),
            |x| black_box(x).square(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("modpow, U256^U256", |b| {
        b.iter_batched(
            || {
                let x_m = ConstMontyForm::random(&mut rng);
                let p = U256::random(&mut rng) | (U256::ONE << (U256::BITS - 1));
                (x_m, p)
            },
            |(x, p)| black_box(x.pow(&p)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("jacobi_symbol", |b| {
        b.iter_batched(
            || ConstMontyForm::random(&mut rng),
            |a| a.jacobi_symbol(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("jacobi_symbol_vartime", |b| {
        b.iter_batched(
            || ConstMontyForm::random(&mut rng),
            |a| a.jacobi_symbol_vartime(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("lincomb, U256*U256+U256*U256", |b| {
        b.iter_batched(
            || ConstMontyForm::random(&mut rng),
            |a| {
                ConstMontyForm::lincomb(&[
                    (black_box(a), black_box(a)),
                    (black_box(a), black_box(a)),
                ])
            },
            BatchSize::SmallInput,
        )
    });

    #[cfg(feature = "alloc")]
    for i in [1, 2, 3, 4, 10, 100] {
        group.bench_function(
            format!("multi_exponentiate for {i} bases, U256^U256"),
            |b| {
                b.iter_batched(
                    || {
                        let bases_and_exponents: Vec<(ConstMontyForm, U256)> = (1..=i)
                            .map(|_| {
                                let x_m = ConstMontyForm::random(&mut rng);
                                let p = U256::random(&mut rng) | (U256::ONE << (U256::BITS - 1));
                                (x_m, p)
                            })
                            .collect();

                        bases_and_exponents
                    },
                    |bases_and_exponents| {
                        black_box(ConstMontyForm::multi_exponentiate(
                            bases_and_exponents.as_slice(),
                        ))
                    },
                    BatchSize::SmallInput,
                )
            },
        );
    }
}

fn bench_montgomery(c: &mut Criterion) {
    let mut group = c.benchmark_group("Const Montgomery arithmetic");
    bench_montgomery_conversion(&mut group);
    bench_montgomery_ops(&mut group);
    group.finish();
}

criterion_group!(benches, bench_montgomery);

criterion_main!(benches);
