use criterion::{criterion_group, criterion_main};
use criterion::{BatchSize, Criterion};

fn vector(c: &mut Criterion) {
    use tls_codec::*;
    c.bench_function("TLS Serialize Vector", |b| {
        b.iter_batched(
            || TlsVecU32::from(vec![77u8; 65535]),
            |long_vector| {
                let _serialized_long_vec = long_vector.tls_serialize_detached().unwrap();
            },
            BatchSize::SmallInput,
        )
    });
    c.bench_function("TLS Deserialize Vector", |b| {
        b.iter_batched(
            || {
                let long_vector = vec![77u8; 65535];
                TlsSliceU32(&long_vector).tls_serialize_detached().unwrap()
            },
            |serialized_long_vec| {
                let _deserialized_long_vec =
                    TlsVecU32::<u8>::tls_deserialize(&mut serialized_long_vec.as_slice()).unwrap();
            },
            BatchSize::SmallInput,
        )
    });
}

fn byte_vector(c: &mut Criterion) {
    use tls_codec::*;
    c.bench_function("TLS Serialize Byte Vector", |b| {
        b.iter_batched(
            || TlsByteVecU32::from(vec![77u8; 65535]),
            |long_vector| {
                let _serialized_long_vec = long_vector.tls_serialize_detached().unwrap();
            },
            BatchSize::SmallInput,
        )
    });
    c.bench_function("TLS Deserialize Byte Vector", |b| {
        b.iter_batched(
            || {
                let long_vector = vec![77u8; 65535];
                TlsByteSliceU32(&long_vector)
                    .tls_serialize_detached()
                    .unwrap()
            },
            |serialized_long_vec| {
                let _deserialized_long_vec =
                    TlsVecU32::<u8>::tls_deserialize(&mut serialized_long_vec.as_slice()).unwrap();
            },
            BatchSize::SmallInput,
        )
    });
}

fn byte_slice(c: &mut Criterion) {
    use tls_codec::*;
    c.bench_function("TLS Serialize Byte Slice", |b| {
        b.iter_batched(
            || vec![77u8; 65535],
            |long_vector| {
                let _serialized_long_vec = TlsByteSliceU32(&long_vector)
                    .tls_serialize_detached()
                    .unwrap();
            },
            BatchSize::SmallInput,
        )
    });
}

fn slice(c: &mut Criterion) {
    use tls_codec::*;
    c.bench_function("TLS Serialize Slice", |b| {
        b.iter_batched(
            || vec![77u8; 65535],
            |long_vector| {
                let _serialized_long_vec =
                    TlsSliceU32(&long_vector).tls_serialize_detached().unwrap();
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
