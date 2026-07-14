#![feature(test)]
extern crate test;

cipher::stream_cipher_bench!(
    salsa20::Salsa8;
    salsa8_bench1_16b 16;
    salsa8_bench2_256b 256;
    salsa8_bench3_1kib 1024;
    salsa8_bench4_16kib 16384;
);

cipher::stream_cipher_bench!(
    salsa20::Salsa12;
    salsa12_bench1_16b 16;
    salsa12_bench2_256b 256;
    salsa12_bench3_1kib 1024;
    salsa12_bench4_16kib 16384;
);

cipher::stream_cipher_bench!(
    salsa20::Salsa20;
    salsa20_bench1_16b 16;
    salsa20_bench2_256b 256;
    salsa20_bench3_1kib 1024;
    salsa20_bench4_16kib 16384;
);
