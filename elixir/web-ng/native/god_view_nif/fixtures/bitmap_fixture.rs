//! Shared, entirely invented membership workload for the declared native benchmarks.
use crate::bitmap_index::{Instruction, Row};

pub const INFRASTRUCTURE: u32 = 100_000;
pub const ENDPOINTS: u32 = 1_000_000;
pub const POPULATION: u32 = INFRASTRUCTURE + ENDPOINTS;
pub const SAMPLES: usize = 100;
pub const WARMUP: usize = 10;
pub fn ordinal(n: u32, sparse: bool) -> u32 {
    if sparse {
        2_147_483_648 + n * 7
    } else {
        n + 1
    }
}
pub fn values(n: u32) -> (u8, u8, u8, u8) {
    (
        (n % 8) as u8,
        ((n / 8) % 10) as u8,
        if n < INFRASTRUCTURE { 0 } else { 1 },
        if n % 100 < 97 {
            0
        } else if n % 100 < 99 {
            1
        } else {
            2
        },
    )
}
pub fn row(n: u32, sparse: bool) -> Row {
    let (vendor, region, class, state) = values(n);
    (
        ordinal(n, sparse),
        true,
        vec![
            ("vendor".into(), format!("vendor-{vendor}").into()),
            ("region".into(), format!("region-{region}").into()),
            ("device_class".into(), class.to_string().into()),
            (
                "availability".into(),
                ["healthy", "unavailable", "unknown"][state as usize].into(),
            ),
            ("tag:cohort".into(), format!("cohort-{}", n % 50).into()),
        ],
    )
}
fn pred(facet: &str, value: impl Into<String>) -> Instruction {
    (0, facet.into(), value.into(), 0)
}
pub fn program(sample: usize) -> Vec<Instruction> {
    vec![
        pred("vendor", format!("vendor-{}", sample % 8)),
        pred("region", format!("region-{}", sample % 10)),
        pred("device_class", "0"),
        (3, String::new(), String::new(), 1),
        pred("availability", "healthy"),
        (1, String::new(), String::new(), 4),
    ]
}
pub fn percentiles(mut samples: Vec<u128>) -> [u128; 3] {
    samples.sort_unstable();
    [
        samples[samples.len() / 2],
        samples[samples.len() * 95 / 100],
        samples[samples.len() * 99 / 100],
    ]
}
pub fn proc_field(path: &str, prefix: &str) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .find(|line| line.starts_with(prefix))
        .unwrap_or("unavailable")
        .to_string()
}
