use bgpkit_parser::BgpkitParser;
use bzip2::bufread::BzDecoder;
use criterion::{criterion_group, criterion_main, Criterion};
use flate2::bufread::GzDecoder;
use std::fs::File;
use std::hint::black_box;
use std::io::{BufReader, Read};
use std::time::Duration;

mod data_source;

fn preload_min_for_n_entries<R: Read>(input_reader: R, n: usize) -> Vec<u8> {
    struct CopyReader<'a, R> {
        input: R,
        copy: &'a mut Vec<u8>,
    }

    impl<R: Read> Read for CopyReader<'_, R> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let bytes_read = self.input.read(buf)?;
            self.copy.extend_from_slice(&buf[..bytes_read]);
            Ok(bytes_read)
        }
    }

    let mut buffer = Vec::new();
    let parser = BgpkitParser::from_reader(CopyReader {
        input: input_reader,
        copy: &mut buffer,
    });

    parser.into_record_iter().take(n).for_each(drop);

    buffer
}

/// Since we uncompress the input data first, put a hard limit on the number of records so we don't
/// use up too much memory.
const RECORD_LIMIT: usize = 100_000;

pub fn criterion_benchmark(c: &mut Criterion) {
    let update_data = data_source::test_data_file("update-example.gz");
    let rib_data = data_source::test_data_file("rib-example-small.bz2");

    let updates_reader = BufReader::new(File::open(update_data).unwrap());
    let rib_reader = BufReader::new(File::open(rib_data).unwrap());

    println!("Decompressing input data and loading into memory...");
    let updates = preload_min_for_n_entries(GzDecoder::new(updates_reader), RECORD_LIMIT);
    let rib_dump = preload_min_for_n_entries(BzDecoder::new(rib_reader), RECORD_LIMIT);

    println!("Required {} bytes to store updates", updates.len());
    println!("Required {} bytes to store rib table dump", rib_dump.len());

    c.bench_function("updates into_record_iter", |b| {
        b.iter(|| {
            let mut reader = black_box(&updates[..]);

            BgpkitParser::from_reader(&mut reader)
                .into_record_iter()
                .take(RECORD_LIMIT)
                .for_each(|x| {
                    black_box(x);
                });
        })
    });

    c.bench_function("updates into_elem_iter", |b| {
        b.iter(|| {
            let mut reader = black_box(&updates[..]);

            BgpkitParser::from_reader(&mut reader)
                .into_elem_iter()
                .take(RECORD_LIMIT)
                .for_each(|x| {
                    black_box(x);
                });
        })
    });

    c.bench_function("updates into_update_iter", |b| {
        b.iter(|| {
            let mut reader = black_box(&updates[..]);

            BgpkitParser::from_reader(&mut reader)
                .into_update_iter()
                .take(RECORD_LIMIT)
                .for_each(|x| {
                    black_box(x);
                });
        })
    });

    c.bench_function("rib into_record_iter", |b| {
        b.iter(|| {
            let mut reader = black_box(&rib_dump[..]);

            BgpkitParser::from_reader(&mut reader)
                .into_record_iter()
                .take(RECORD_LIMIT)
                .for_each(|x| {
                    black_box(x);
                });
        })
    });

    c.bench_function("rib into_elem_iter", |b| {
        b.iter(|| {
            let mut reader = black_box(&rib_dump[..]);

            BgpkitParser::from_reader(&mut reader)
                .into_elem_iter()
                .take(RECORD_LIMIT)
                .for_each(|x| {
                    black_box(x);
                });
        })
    });

    c.bench_function("rib into_update_iter", |b| {
        b.iter(|| {
            let mut reader = black_box(&rib_dump[..]);

            BgpkitParser::from_reader(&mut reader)
                .into_update_iter()
                .take(RECORD_LIMIT)
                .for_each(|x| {
                    black_box(x);
                });
        })
    });
}

criterion_group! {
    name = benches;
    config = Criterion::default().measurement_time(Duration::from_secs(30));
    targets = criterion_benchmark
}
criterion_main!(benches);
