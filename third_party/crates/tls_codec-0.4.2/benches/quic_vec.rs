use criterion::{criterion_group, criterion_main};
use criterion::{BatchSize, Criterion};

fn vector(c: &mut Criterion) {
    use tls_codec::*;
    c.bench_function("TLS Serialize VL Vector", |b| {
        b.iter_batched(
            || vec![77u8; 65535],
            |long_vector| {
                let _serialized_long_vec = long_vector.tls_serialize_detached().unwrap();
            },
            BatchSize::SmallInput,
        )
    });
    c.bench_function("TLS Deserialize VL Vector", |b| {
        b.iter_batched(
            || {
                let long_vector = vec![77u8; 65535];
                long_vector.tls_serialize_detached().unwrap()
            },
            |serialized_long_vec| {
                let _deserialized_long_vec =
                    Vec::<u8>::tls_deserialize(&mut serialized_long_vec.as_slice()).unwrap();
            },
            BatchSize::SmallInput,
        )
    });
}

fn byte_vector(c: &mut Criterion) {
    use tls_codec::*;
    c.bench_function("TLS Serialize VL Byte Vector", |b| {
        b.iter_batched(
            || VLBytes::new(vec![77u8; 65535]),
            |long_vector| {
                let _serialized_long_vec = long_vector.tls_serialize_detached().unwrap();
            },
            BatchSize::SmallInput,
        )
    });
    c.bench_function("TLS Deserialize VL Byte Vector", |b| {
        b.iter_batched(
            || {
                let long_vector = vec![77u8; 65535];
                VLByteSlice(&long_vector).tls_serialize_detached().unwrap()
            },
            |serialized_long_vec| {
                let _deserialized_long_vec =
                    VLBytes::tls_deserialize(&mut serialized_long_vec.as_slice()).unwrap();
            },
            BatchSize::SmallInput,
        )
    });
}

fn byte_slice(c: &mut Criterion) {
    use tls_codec::*;
    c.bench_function("TLS Serialize VL Byte Slice", |b| {
        b.iter_batched(
            || vec![77u8; 65535],
            |long_vector| {
                let _serialized_long_vec =
                    VLByteSlice(&long_vector).tls_serialize_detached().unwrap();
            },
            BatchSize::SmallInput,
        )
    });
}

fn slice(c: &mut Criterion) {
    use tls_codec::*;
    c.bench_function("TLS Serialize VL Slice", |b| {
        b.iter_batched(
            || vec![77u8; 65535],
            |long_vector| {
                let _serialized_long_vec = long_vector.tls_serialize_detached().unwrap();
            },
            BatchSize::SmallInput,
        )
    });
}
fn benchmark(c: &mut Criterion) {
    vector(c);
    slice(c);
    byte_vector(c);
    byte_slice(c);
}

criterion_group!(benches, benchmark);
criterion_main!(benches);
