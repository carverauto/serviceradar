use criterion::measurement::WallTime;
use criterion::{
    BatchSize, BenchmarkGroup, BenchmarkId, Criterion, criterion_group, criterion_main,
};
use crypto_bigint::{
    Gcd, Limb, NonZero, Odd, OddUint, Random, RandomBits, RandomMod, Reciprocal, U128, U256, U512,
    U1024, U2048, U4096, U8192, Uint,
};
use rand_chacha::ChaCha8Rng;
use rand_core::{RngCore, SeedableRng};
use std::hint::black_box;

fn make_rng() -> ChaCha8Rng {
    ChaCha8Rng::from_seed(*b"01234567890123456789012345678901")
}

fn bench_random(c: &mut Criterion) {
    let mut group = c.benchmark_group("bounded random");

    let mut rng = make_rng();
    group.bench_function("random_mod, U1024", |b| {
        let bound = U1024::random(&mut rng);
        let bound_nz = NonZero::new(bound).unwrap();
        b.iter(|| black_box(U1024::random_mod(&mut rng, &bound_nz)));
    });

    let mut rng = make_rng();
    group.bench_function("random_bits, U1024", |b| {
        let bound = U1024::random(&mut rng);
        let bound_bits = bound.bits_vartime();
        b.iter(|| {
            let mut r = U1024::random_bits(&mut rng, bound_bits);
            while r >= bound {
                r = U1024::random_bits(&mut rng, bound_bits);
            }
            black_box(r)
        });
    });

    let mut rng = make_rng();
    group.bench_function("random_mod, U1024, small bound", |b| {
        let bound = U1024::from_u64(rng.next_u64());
        let bound_nz = NonZero::new(bound).unwrap();
        b.iter(|| black_box(U1024::random_mod(&mut rng, &bound_nz)));
    });

    let mut rng = make_rng();
    group.bench_function("random_bits, U1024, small bound", |b| {
        let bound = U1024::from_u64(rng.next_u64());
        let bound_bits = bound.bits_vartime();
        b.iter(|| {
            let mut r = U1024::random_bits(&mut rng, bound_bits);
            while r >= bound {
                r = U1024::random_bits(&mut rng, bound_bits);
            }
            black_box(r)
        });
    });

    let mut rng = make_rng();
    group.bench_function("random_mod, U1024, 512 bit bound low", |b| {
        let bound = U512::random(&mut rng);
        let bound = U1024::from((bound, U512::ZERO));
        let bound_nz = NonZero::new(bound).unwrap();
        b.iter(|| black_box(U1024::random_mod(&mut rng, &bound_nz)));
    });

    let mut rng = make_rng();
    group.bench_function("random_bits, U1024, 512 bit bound low", |b| {
        let bound = U512::random(&mut rng);
        let bound = U1024::from((bound, U512::ZERO));
        let bound_bits = bound.bits_vartime();
        b.iter(|| {
            let mut r = U1024::random_bits(&mut rng, bound_bits);
            while r >= bound {
                r = U1024::random_bits(&mut rng, bound_bits);
            }
            black_box(r)
        });
    });

    let mut rng = make_rng();
    group.bench_function("random_mod, U1024, 512 bit bound hi", |b| {
        let bound = U512::random(&mut rng);
        let bound = U1024::from((U512::ZERO, bound));
        let bound_nz = NonZero::new(bound).unwrap();
        b.iter(|| black_box(U1024::random_mod(&mut rng, &bound_nz)));
    });

    let mut rng = make_rng();
    group.bench_function("random_bits, U1024, 512 bit bound hi", |b| {
        let bound = U512::random(&mut rng);
        let bound = U1024::from((U512::ZERO, bound));
        let bound_bits = bound.bits_vartime();
        b.iter(|| {
            let mut r = U1024::random_bits(&mut rng, bound_bits);
            while r >= bound {
                r = U1024::random_bits(&mut rng, bound_bits);
            }
            black_box(r)
        });
    });

    // Slow case: the hi limb is just `2`
    let mut rng = make_rng();
    group.bench_function("random_mod, U1024, tiny high limb", |b| {
        let hex_1024 = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000291A6B42D1C7D2A7184D13E36F65773BBEFB4FA7996101300D49F09962A361F00";
        let modulus = U1024::from_be_hex(hex_1024);
        let modulus_nz = NonZero::new(modulus).unwrap();
        b.iter(|| black_box(U1024::random_mod(&mut rng, &modulus_nz)));
    });

    // Slow case: the hi limb is just `2`
    let mut rng = make_rng();
    group.bench_function("random_bits, U1024, tiny high limb", |b| {
        let hex_1024 = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000291A6B42D1C7D2A7184D13E36F65773BBEFB4FA7996101300D49F09962A361F00";
        let bound = U1024::from_be_hex(hex_1024);
        let bound_bits = bound.bits_vartime();
        b.iter(|| {
            let mut r = U1024::random_bits(&mut rng, bound_bits);
            while r >= bound {
                r = U1024::random_bits(&mut rng, bound_bits);
            }
        });
    });
}

fn bench_random_bits(c: &mut Criterion) {
    let mut group = c.benchmark_group("random_bits");

    let mut rng = make_rng();
    group.bench_function("random_bits, U256, full", |b| {
        b.iter(|| black_box(U256::random_bits(&mut rng, U256::BITS)));
    });

    group.bench_function("random_bits, U256, bounded", |b| {
        b.iter(|| black_box(U256::random_bits(&mut rng, 219)));
    });

    group.bench_function("random_bits, U2048, full", |b| {
        b.iter(|| black_box(U2048::random_bits(&mut rng, U2048::BITS)));
    });

    group.bench_function("random_bits, U2048, bounded", |b| {
        b.iter(|| black_box(U2048::random_bits(&mut rng, 1947)));
    });
}

fn bench_mul(c: &mut Criterion) {
    let mut group = c.benchmark_group("wrapping ops");

    let mut rng = make_rng();
    group.bench_function("widening_mul, U256xU256", |b| {
        b.iter_batched(
            || (U256::random(&mut rng), U256::random(&mut rng)),
            |(x, y)| black_box(x.widening_mul(&y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("widening_mul, U4096xU4096", |b| {
        b.iter_batched(
            || (U4096::random(&mut rng), U4096::random(&mut rng)),
            |(x, y)| black_box(x.widening_mul(&y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("widening_mul, U8192xU4096", |b| {
        b.iter_batched(
            || (U8192::random(&mut rng), U4096::random(&mut rng)),
            |(x, y)| black_box(x.widening_mul(&y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("wrapping_mul, U256xU256", |b| {
        b.iter_batched(
            || (U256::random(&mut rng), U256::random(&mut rng)),
            |(x, y)| black_box(x.wrapping_mul(&y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("wrapping_mul, U4096xU4096", |b| {
        b.iter_batched(
            || (U4096::random(&mut rng), U4096::random(&mut rng)),
            |(x, y)| black_box(x.wrapping_mul(&y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("wrapping_mul, U8192xU4096", |b| {
        b.iter_batched(
            || (U8192::random(&mut rng), U4096::random(&mut rng)),
            |(x, y)| black_box(x.wrapping_mul(&y)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("square_wide, U256", |b| {
        b.iter_batched(
            || U256::random(&mut rng),
            |x| black_box(x.square_wide()),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("square_wide, U4096", |b| {
        b.iter_batched(
            || U4096::random(&mut rng),
            |x| black_box(x.square_wide()),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("wrapping_square, U256xU256", |b| {
        b.iter_batched(
            || U256::random(&mut rng),
            |x| x.wrapping_square(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("wrapping_square, U4096xU4096", |b| {
        b.iter_batched(
            || U4096::random(&mut rng),
            |x| x.wrapping_square(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("mul_mod, U256", |b| {
        b.iter_batched(
            || {
                let m = Odd::<U256>::random(&mut rng);
                let x = U256::random_mod(&mut rng, m.as_nz_ref());
                (m.to_nz().unwrap(), x)
            },
            |(m, x)| black_box(x).mul_mod(black_box(&x), &m),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("mul_mod_vartime, U256", |b| {
        b.iter_batched(
            || {
                let m = Odd::<U256>::random(&mut rng);
                let x = U256::random_mod(&mut rng, m.as_nz_ref());
                (m.to_nz().unwrap(), x)
            },
            |(m, x)| black_box(x).mul_mod_vartime(black_box(&x), &m),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("mul_mod_special, U256", |b| {
        b.iter_batched(
            || {
                let m = Limb::random(&mut rng);
                let x = U256::random(&mut rng);
                (m, x)
            },
            |(m, x)| black_box(x).mul_mod_special(black_box(&x), m),
            BatchSize::SmallInput,
        )
    });
}

fn bench_division(c: &mut Criterion) {
    let mut rng = make_rng();
    let mut group = c.benchmark_group("wrapping ops");

    group.bench_function("div/rem, U256/U128", |b| {
        b.iter_batched(
            || (U256::random(&mut rng), NonZero::<U128>::random(&mut rng)),
            |(x, y)| x.div_rem(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("div/rem, U256/U128 (in U256)", |b| {
        b.iter_batched(
            || {
                let x = U256::random(&mut rng);
                let y_half = U128::random(&mut rng);
                let y: U256 = (y_half, U128::ZERO).into();
                (x, NonZero::new(y).unwrap())
            },
            |(x, y)| x.div_rem(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("div/rem, U256/U128 (in U512)", |b| {
        b.iter_batched(
            || {
                let x = U256::random(&mut rng);
                let y: U512 = U128::random(&mut rng).resize();
                (x, NonZero::new(y).unwrap())
            },
            |(x, y)| x.div_rem(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("div/rem_vartime, U256/U128, full size", |b| {
        b.iter_batched(
            || {
                let x = U256::random(&mut rng);
                let y: U256 = (U128::MAX, U128::ZERO).into();
                (x, NonZero::new(y).unwrap())
            },
            |(x, y)| x.div_rem_vartime(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("rem, U256/U128", |b| {
        b.iter_batched(
            || (U256::random(&mut rng), NonZero::<U128>::random(&mut rng)),
            |(x, y)| x.rem(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("rem, U256/U128 (in U256)", |b| {
        b.iter_batched(
            || {
                let x = U256::random(&mut rng);
                let y: U256 = U128::random(&mut rng).resize();
                (x, NonZero::new(y).unwrap())
            },
            |(x, y)| x.rem(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("rem, U256/U128 (in U512)", |b| {
        b.iter_batched(
            || {
                let x = U256::random(&mut rng);
                let y: U512 = U128::random(&mut rng).resize();
                (x, NonZero::new(y).unwrap())
            },
            |(x, y)| x.rem(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("rem_vartime, U256/U128, full size", |b| {
        b.iter_batched(
            || {
                let x = U256::random(&mut rng);
                let y: U256 = (U128::MAX, U128::ZERO).into();
                (x, NonZero::new(y).unwrap())
            },
            |(x, y)| x.rem_vartime(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("rem_wide, U256", |b| {
        b.iter_batched(
            || {
                let (x_lo, x_hi) = (U256::random(&mut rng), U256::random(&mut rng));
                let y = U256::random(&mut rng);
                (x_lo, x_hi, NonZero::new(y).unwrap())
            },
            |(x_lo, x_hi, y)| Uint::rem_wide((x_lo, x_hi), &y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("rem_wide_vartime, U256", |b| {
        b.iter_batched(
            || {
                let (x_lo, x_hi) = (U256::random(&mut rng), U256::random(&mut rng));
                let y: U256 = (U128::MAX, U128::ZERO).into();
                (x_lo, x_hi, NonZero::new(y).unwrap())
            },
            |(x_lo, x_hi, y)| Uint::rem_wide_vartime((x_lo, x_hi), &y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("div/rem, U256/Limb, full size", |b| {
        b.iter_batched(
            || {
                let x = U256::random(&mut rng);
                let y_small = Limb::random(&mut rng);
                let y = U256::from_word(y_small.0);
                (x, NonZero::new(y).unwrap())
            },
            |(x, y)| x.div_rem(&y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("div/rem, U256/Limb, single limb", |b| {
        b.iter_batched(
            || (U256::random(&mut rng), NonZero::<Limb>::random(&mut rng)),
            |(x, y)| x.div_rem_limb(y),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("div/rem, U256/Limb, single limb with reciprocal", |b| {
        b.iter_batched(
            || {
                (
                    U256::random(&mut rng),
                    Reciprocal::new(NonZero::<Limb>::random(&mut rng)),
                )
            },
            |(x, r)| x.div_rem_limb_with_reciprocal(&r),
            BatchSize::SmallInput,
        )
    });

    group.finish();
}

fn gcd_bench<const LIMBS: usize>(g: &mut BenchmarkGroup<WallTime>, _x: Uint<LIMBS>) {
    let mut rng = make_rng();

    g.bench_function(BenchmarkId::new("gcd", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    Uint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(Uint::gcd(&f, &g)),
            BatchSize::SmallInput,
        )
    });

    g.bench_function(BenchmarkId::new("gcd_vartime", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    Uint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(Uint::gcd_vartime(&f, &g)),
            BatchSize::SmallInput,
        )
    });

    g.bench_function(BenchmarkId::new("bingcd", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    OddUint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(f.bingcd(&g)),
            BatchSize::SmallInput,
        )
    });

    g.bench_function(BenchmarkId::new("bingcd_vartime", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    OddUint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(f.bingcd_vartime(&g)),
            BatchSize::SmallInput,
        )
    });

    g.bench_function(BenchmarkId::new("safegcd", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    OddUint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(f.safegcd(&g)),
            BatchSize::SmallInput,
        )
    });

    g.bench_function(BenchmarkId::new("safegcd_vartime", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    OddUint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(f.safegcd_vartime(&g)),
            BatchSize::SmallInput,
        )
    });
}

fn bench_gcd(c: &mut Criterion) {
    let mut group = c.benchmark_group("greatest common divisor");

    gcd_bench(&mut group, Uint::<1>::ZERO);
    gcd_bench(&mut group, Uint::<2>::ZERO);
    gcd_bench(&mut group, Uint::<4>::ZERO);
    gcd_bench(&mut group, Uint::<8>::ZERO);
    gcd_bench(&mut group, Uint::<64>::ZERO);
    gcd_bench(&mut group, Uint::<256>::ZERO);

    group.finish();
}

fn xgcd_bench<const LIMBS: usize>(g: &mut BenchmarkGroup<WallTime>, _x: Uint<LIMBS>) {
    let mut rng = make_rng();

    g.bench_function(BenchmarkId::new("xgcd", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    Uint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(Uint::xgcd(&f, &g)),
            BatchSize::SmallInput,
        )
    });
}

fn bench_xgcd(c: &mut Criterion) {
    let mut group = c.benchmark_group("extended greatest common divisor");

    xgcd_bench(&mut group, Uint::<1>::ZERO);
    xgcd_bench(&mut group, Uint::<2>::ZERO);
    xgcd_bench(&mut group, Uint::<3>::ZERO);
    xgcd_bench(&mut group, Uint::<4>::ZERO);
    xgcd_bench(&mut group, Uint::<5>::ZERO);
    xgcd_bench(&mut group, Uint::<6>::ZERO);
    xgcd_bench(&mut group, Uint::<7>::ZERO);
    xgcd_bench(&mut group, Uint::<8>::ZERO);
    xgcd_bench(&mut group, Uint::<16>::ZERO);
    xgcd_bench(&mut group, Uint::<32>::ZERO);
    xgcd_bench(&mut group, Uint::<64>::ZERO);
    xgcd_bench(&mut group, Uint::<128>::ZERO);
    xgcd_bench(&mut group, Uint::<256>::ZERO);

    group.finish();
}

fn mod_symbols_bench<const LIMBS: usize>(g: &mut BenchmarkGroup<WallTime>, _x: Uint<LIMBS>) {
    let mut rng = make_rng();

    g.bench_function(BenchmarkId::new("jacobi_symbol", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    OddUint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(g.jacobi_symbol(&f)),
            BatchSize::SmallInput,
        )
    });

    g.bench_function(BenchmarkId::new("jacobi_symbol_vartime", LIMBS), |b| {
        b.iter_batched(
            || {
                (
                    OddUint::<LIMBS>::random(&mut rng),
                    Uint::<LIMBS>::random(&mut rng),
                )
            },
            |(f, g)| black_box(g.jacobi_symbol_vartime(&f)),
            BatchSize::SmallInput,
        )
    });
}

fn bench_mod_symbols(c: &mut Criterion) {
    let mut group = c.benchmark_group("modular symbols");

    mod_symbols_bench(&mut group, Uint::<1>::ZERO);
    mod_symbols_bench(&mut group, Uint::<4>::ZERO);
    mod_symbols_bench(&mut group, Uint::<64>::ZERO);

    group.finish();
}

fn bench_shl(c: &mut Criterion) {
    let mut group = c.benchmark_group("left shift");

    group.bench_function("shl_vartime, small, U2048", |b| {
        b.iter_batched(|| U2048::ONE, |x| x.shl_vartime(10), BatchSize::SmallInput)
    });

    group.bench_function("shl_vartime, large, U2048", |b| {
        b.iter_batched(
            || U2048::ONE,
            |x| x.shl_vartime(1024 + 10),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("shl_vartime_wide, large, U2048", |b| {
        b.iter_batched(
            || (U2048::ONE, U2048::ONE),
            |x| Uint::overflowing_shl_vartime_wide(x, 1024 + 10),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("shl, U2048", |b| {
        b.iter_batched(|| U2048::ONE, |x| x.shl(1024 + 10), BatchSize::SmallInput)
    });

    group.finish();
}

fn bench_shr(c: &mut Criterion) {
    let mut group = c.benchmark_group("right shift");

    group.bench_function("shr_vartime, small, U2048", |b| {
        b.iter_batched(|| U2048::ONE, |x| x.shr_vartime(10), BatchSize::SmallInput)
    });

    group.bench_function("shr_vartime, large, U2048", |b| {
        b.iter_batched(
            || U2048::ONE,
            |x| x.shr_vartime(1024 + 10),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("shr_vartime_wide, large, U2048", |b| {
        b.iter_batched(
            || (U2048::ONE, U2048::ONE),
            |x| Uint::overflowing_shr_vartime_wide(x, 1024 + 10),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("shr, U2048", |b| {
        b.iter_batched(|| U2048::ONE, |x| x.shr(1024 + 10), BatchSize::SmallInput)
    });

    group.finish();
}

fn bench_invert_mod(c: &mut Criterion) {
    let mut rng = make_rng();
    let mut group = c.benchmark_group("modular ops");

    group.bench_function("invert_odd_mod, U256", |b| {
        b.iter_batched(
            || {
                let m = Odd::<U256>::random(&mut rng);
                loop {
                    let x = U256::random(&mut rng);
                    let inv_x = x.invert_odd_mod(&m);
                    if inv_x.is_some().into() {
                        break (x, m);
                    }
                }
            },
            |(x, m)| black_box(x.invert_odd_mod(&m)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("invert_odd_mod_vartime, U256", |b| {
        b.iter_batched(
            || {
                let m = Odd::<U256>::random(&mut rng);
                loop {
                    let x = U256::random(&mut rng);
                    let inv_x = x.invert_odd_mod_vartime(&m);
                    if inv_x.is_some().into() {
                        break (x, m);
                    }
                }
            },
            |(x, m)| black_box(x.invert_odd_mod_vartime(&m)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("invert_mod, U256, odd modulus", |b| {
        b.iter_batched(
            || {
                let m = Odd::<U256>::random(&mut rng);
                loop {
                    let x = U256::random(&mut rng);
                    let inv_x = x.invert_odd_mod(&m);
                    if inv_x.is_some().into() {
                        break (x, m);
                    }
                }
            },
            |(x, m)| black_box(x.invert_mod(m.as_nz_ref())),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("invert_mod, U256", |b| {
        b.iter_batched(
            || {
                let m = NonZero::<U256>::random(&mut rng);
                loop {
                    let x = U256::random(&mut rng);
                    let inv_x = x.invert_mod(&m);
                    if inv_x.is_some().into() {
                        break (x, m);
                    }
                }
            },
            |(x, m)| black_box(x.invert_mod(&m)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("invert_mod2k, U256", |b| {
        b.iter_batched(
            || U256::random(&mut rng),
            |x| x.invert_mod2k(black_box(1)),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("invert_mod2k_vartime, U256", |b| {
        b.iter_batched(
            || U256::random(&mut rng),
            |x| x.invert_mod2k_vartime(black_box(1)),
            BatchSize::SmallInput,
        )
    });

    group.finish();
}

fn bench_sqrt(c: &mut Criterion) {
    let mut rng = make_rng();
    let mut group = c.benchmark_group("sqrt");

    group.bench_function("sqrt, U256", |b| {
        b.iter_batched(
            || U256::random(&mut rng),
            |x| x.sqrt(),
            BatchSize::SmallInput,
        )
    });

    group.bench_function("sqrt_vartime, U256", |b| {
        b.iter_batched(
            || U256::random(&mut rng),
            |x| x.sqrt_vartime(),
            BatchSize::SmallInput,
        )
    });
}

criterion_group!(
    benches,
    bench_random,
    bench_random_bits,
    bench_mul,
    bench_division,
    bench_gcd,
    bench_xgcd,
    bench_mod_symbols,
    bench_shl,
    bench_shr,
    bench_invert_mod,
    bench_sqrt
);

criterion_main!(benches);
