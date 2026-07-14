use std::fs::File;
use std::hint::black_box;
use std::io::Read;

use criterion::{criterion_group, criterion_main, BatchSize, Criterion, Throughput};
use flate2::read::GzDecoder;

// Benchmark gzip decompression using flate2 with the selected backend.
// To run with default (miniz_oxide) backend:
//   cargo bench --bench gzip_decompress --no-default-features --features gz-miniz
// To run with zlib-rs backend:
//   cargo bench --bench gzip_decompress --no-default-features --features gz-zlib-rs
// To compare, run both commands and compare Criterion reports.

fn load_gz_bytes() -> Vec<u8> {
    let mut f = File::open("tests/test_data.txt.gz").expect("missing tests/test_data.txt.gz");
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).unwrap();
    buf
}

fn bench_gzip_decompress(c: &mut Criterion) {
    let input = load_gz_bytes();

    let mut group = c.benchmark_group("gzip_decompress");
    group.throughput(Throughput::Bytes(input.len() as u64));

    group.bench_function("flate2_gz_decode", |b| {
        b.iter_batched(
            || input.clone(),
            |bytes| {
                let reader = GzDecoder::new(bytes.as_slice());
                let mut out = Vec::with_capacity(128 * 1024);
                let mut r = reader;
                r.read_to_end(&mut out).unwrap();
                black_box(out)
            },
            BatchSize::SmallInput,
        )
    });

    group.finish();
}

criterion_group!(benches, bench_gzip_decompress);
criterion_main!(benches);
