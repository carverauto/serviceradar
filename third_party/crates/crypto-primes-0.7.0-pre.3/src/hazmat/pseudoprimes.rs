//! This module contains various types pseudoprimes
//! (composites that are classified as primes by various tests) for testing purposes.
use crypto_bigint::{U64, U1536};

/// The limit up to which we have exceptions to implemented tests listed (see below),
/// so we can run an exhaustive test on every number knowing when it is expected to fail.
#[cfg(feature = "tests-exhaustive")]
pub(crate) const EXHAUSTIVE_TEST_LIMIT: u32 = 500000;

/// Extra strong Lucas pseudoprimes (OEIS:A217719) under `EXHAUSTIVE_TEST_LIMIT`.
/// Should pass the extra strong Lucas test with brute force base (Baillie method C).
pub(crate) const EXTRA_STRONG_LUCAS: &[u32] = &[
    989, 3239, 5777, 10877, 27971, 29681, 30739, 31631, 39059, 72389, 73919, 75077, 100127, 113573, 125249, 137549,
    137801, 153931, 155819, 161027, 162133, 189419, 218321, 231703, 249331, 370229, 429479, 430127, 459191, 473891,
    480689,
];

/// Strong Lucas pseudoprimes (OEIS:A217255) under `EXHAUSTIVE_TEST_LIMIT`.
/// Should pass the strong Lucas test with Selfridge base (Baillie method A).
pub(crate) const STRONG_LUCAS: &[u32] = &[
    5459, 5777, 10877, 16109, 18971, 22499, 24569, 25199, 40309, 58519, 75077, 97439, 100127, 113573, 115639, 130139,
    155819, 158399, 161027, 162133, 176399, 176471, 189419, 192509, 197801, 224369, 230691, 231703, 243629, 253259,
    268349, 288919, 313499, 324899, 353219, 366799, 391169, 430127, 436409, 455519, 487199,
];

/// Almost extra strong Lucas pseudoprimes under `EXHAUSTIVE_TEST_LIMIT`.
/// Should pass the almost extra strong Lucas test with brute force base (Baillie method C).
/// Taken from D. Jacobsen, "Pseudoprime Statistics, Tables, and Data",
/// <http://ntheory.org/pseudoprimes.html>
pub(crate) const ALMOST_EXTRA_STRONG_LUCAS: &[u32] = &[
    989, 3239, 5777, 10469, 10877, 27971, 29681, 30739, 31631, 39059, 72389, 73919, 75077, 100127, 113573, 125249,
    137549, 137801, 153931, 154697, 155819, 161027, 162133, 189419, 218321, 231703, 233659, 249331, 370229, 429479,
    430127, 459191, 472453, 473891, 480689,
];

/// Pseudoprimes for Lucas-V test, also known as Dickson pseudoprimes of the second kind,
/// under `EXHAUSTIVE_TEST_LIMIT`.
pub(crate) const LUCAS_V: &[u32] = &[913];

/// Lucas pseudoprimes (OEIS:A217120) under `EXHAUSTIVE_TEST_LIMIT`.
/// Should pass the regular Lucas test with Selfridge base (Baillie method A).
/// Taken from D. Jacobsen, "Pseudoprime Statistics, Tables, and Data",
/// <http://ntheory.org/pseudoprimes.html>
pub(crate) const LUCAS: &[u32] = &[
    323, 377, 1159, 1829, 3827, 5459, 5777, 9071, 9179, 10877, 11419, 11663, 13919, 14839, 16109, 16211, 18407, 18971,
    19043, 22499, 23407, 24569, 25199, 25877, 26069, 27323, 32759, 34943, 35207, 39059, 39203, 39689, 40309, 44099,
    46979, 47879, 50183, 51983, 53663, 56279, 58519, 60377, 63881, 69509, 72389, 73919, 75077, 77219, 79547, 79799,
    82983, 84419, 86063, 90287, 94667, 97019, 97439, 100127, 101919, 103739, 104663, 113573, 113849, 115439, 115639,
    120581, 121103, 121393, 130139, 142883, 150079, 155819, 157079, 158399, 158717, 161027, 162133, 162719, 164699,
    167969, 176399, 176471, 178949, 182513, 184781, 189419, 192509, 195227, 197801, 200147, 201871, 203699, 216659,
    218129, 223901, 224369, 226529, 230159, 230691, 231703, 238999, 242079, 243629, 250277, 253259, 256409, 265481,
    268349, 271991, 275099, 277399, 283373, 284171, 288919, 294527, 306287, 308699, 309959, 313499, 317249, 324899,
    324911, 327359, 345913, 353219, 364229, 366799, 368351, 380393, 381923, 383921, 385307, 391169, 391859, 396899,
    427349, 429263, 430127, 436409, 436589, 441599, 454607, 455519, 475799, 480689, 487199,
];

/// First 5 pseudoprimes for Lucas-V test[^Baillie2021].
///
/// [^Baillie2021]: R. Baillie, A. Fiori, S. S. Wagstaff,
///   "Strengthening the Baillie-PSW primality test",
///   Math. Comp. 90 1931-1955 (2021),
///   DOI: [10.1090/mcom/3616](https://doi.org/10.1090/mcom/3616)
pub(crate) const LARGE_LUCAS_V: &[U64] = &[
    U64::from_be_hex("0000000000000391"),
    U64::from_be_hex("00000022fca192eb"),
    U64::from_be_hex("000000643f4f0ba5"),
    U64::from_be_hex("00000d6ca2385e03"),
    U64::from_be_hex("0003541efcafa4cd"),
];

/// Strong pseudoprimes to base 2 (OEIS:A001262) under `EXHAUSTIVE_TEST_LIMIT`.
pub(crate) const STRONG_BASE_2: &[u32] = &[
    2047, 3277, 4033, 4681, 8321, 15841, 29341, 42799, 49141, 52633, 65281, 74665, 80581, 85489, 88357, 90751, 104653,
    130561, 196093, 220729, 233017, 252601, 253241, 256999, 271951, 280601, 314821, 357761, 390937, 458989, 476971,
    486737, 489997,
];

/// Strong Fibonacci pseudoprimes, Type I[^Pinch].
///
/// [^Pinch]: R. G. E. Pinch "The Carmichael Numbers up to 10^15",
///   Mathematics of Computation 61, 381-391 (1993),
///   DOI: [10.2307/2152963](https://doi.org/10.2307/2152963).
pub(crate) const STRONG_FIBONACCI: &[U64] = &[U64::from_be_hex("0001933ecb87a0c1")];

/// Odd Fibonacci pseudoprimes (OEIS:A081264).
pub(crate) const FIBONACCI: &[u32] = &[
    323, 377, 1891, 3827, 4181, 5777, 6601, 6721, 8149, 10877, 11663, 13201, 13981, 15251, 17119, 17711, 18407, 19043,
    23407, 25877, 27323, 30889, 34561, 34943, 35207, 39203, 40501, 50183, 51841, 51983, 52701, 53663, 60377, 64079,
    64681,
];

/// Bruckman-Lucas pseudoprimes (OEIS:A005845).
pub(crate) const BRUCKMAN_LUCAS: &[u32] = &[
    705, 2465, 2737, 3745, 4181, 5777, 6721, 10877, 13201, 15251, 24465, 29281, 34561, 35785, 51841, 54705, 64079,
    64681, 67861, 68251, 75077, 80189, 90061, 96049, 97921, 100065, 100127, 105281, 113573, 118441, 146611, 161027,
];

/// A large Carmichael number.
/// Source: F. Arnault, "Constructing Carmichael Numbers Which Are Strong
/// Pseudoprimes to Several Bases". Journal of Symbolic Computation 20(2) 151–161 (1995),
/// DOI: 10.1006/jsco.1995.1042.
/// This is a composite that can pass Miller-Rabin test to all prime bases less than 307.
pub(crate) const LARGE_CARMICHAEL_NUMBER: U1536 = U1536::from_be_hex(concat![
    "00000000000000000000000000000000",
    "0000000000000000000000204b212272",
    "807927b357671aefdd4b4b7a0f127496",
    "25cd71b549d6b8b9895e97fcf9fadcaf",
    "26c618da83c9ec7f6b39020661ba422e",
    "6c820ac14d3b8329d6c71d16a1953afd",
    "60a0aa4c63019f9c29c08d05b0c4fcd0",
    "41febeaa5b0e8475e6e96cc49478ef6e",
    "9ae877b4d3be8107bd3c64b35ebc7f2b",
    "d719c6417207aaec2151812719b5b5ba",
    "e64562bcd2ed44177a2ac314a44f344d",
    "f4a12e0d4fb8ff99c4099bfc77924b2b"
]);
