use crate::DEFAULT_N_SIGMA;
use rustler::NifMap;

#[derive(Clone, Copy, Debug)]
pub(crate) struct BaselineStats {
    pub(crate) mean: f64,
    pub(crate) stddev: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, NifMap)]
pub(crate) struct WelfordAcc {
    pub(crate) count: usize,
    pub(crate) mean: f64,
    pub(crate) m2: f64,
}

impl WelfordAcc {
    pub(crate) fn from_values(values: &[f64]) -> Self {
        values
            .iter()
            .copied()
            .fold(Self::default(), |mut acc, value| {
                acc.add(value);
                acc
            })
    }

    pub(crate) fn add(&mut self, value: f64) {
        if !value.is_finite() {
            return;
        }

        let next_count = self.count.saturating_add(1);
        let delta = value - self.mean;

        self.count = next_count;
        self.mean += delta / next_count as f64;
        let delta_after = value - self.mean;
        self.m2 += delta * delta_after;

        if self.m2 < 0.0 {
            self.m2 = 0.0;
        }
    }

    pub(crate) fn remove(&mut self, value: f64) {
        if !value.is_finite() || self.count == 0 {
            return;
        }

        if self.count == 1 {
            *self = Self::default();
            return;
        }

        let old_count = self.count as f64;
        let next_count = self.count - 1;
        let next_count_f64 = next_count as f64;
        let old_mean = self.mean;
        let next_mean = (old_count * old_mean - value) / next_count_f64;

        self.count = next_count;
        self.mean = next_mean;
        self.m2 -= (value - old_mean) * (value - next_mean);

        if self.m2 < 0.0 {
            self.m2 = 0.0;
        }
    }

    pub(crate) fn valid_for_count(self, count: usize) -> bool {
        self.count == count
            && self.mean.is_finite()
            && self.m2.is_finite()
            && self.m2 >= 0.0
            && (count != 0 || (self.mean == 0.0 && self.m2 == 0.0))
    }

    pub(crate) fn stats(self) -> Option<BaselineStats> {
        if self.count < 2 || !self.mean.is_finite() || !self.m2.is_finite() {
            return None;
        }

        let variance = self.m2.max(0.0) / (self.count as f64 - 1.0);

        Some(BaselineStats {
            mean: self.mean,
            stddev: variance.sqrt(),
        })
    }
}

pub(crate) fn sample_stats(values: &[f64]) -> BaselineStats {
    let count = values.len() as f64;
    let mean = values.iter().sum::<f64>() / count;
    let variance = values
        .iter()
        .map(|value| {
            let delta = value - mean;
            delta * delta
        })
        .sum::<f64>()
        / (count - 1.0);

    BaselineStats {
        mean,
        stddev: variance.max(0.0).sqrt(),
    }
}

pub(crate) fn z_score(sample_value: f64, stats: BaselineStats, threshold: f64) -> f64 {
    if stats.stddev <= f64::EPSILON {
        if (sample_value - stats.mean).abs() <= f64::EPSILON {
            0.0
        } else {
            threshold + 1.0
        }
    } else {
        ((sample_value - stats.mean) / stats.stddev).abs()
    }
}

pub(crate) fn clean_threshold(threshold: f64) -> f64 {
    if threshold.is_finite() && threshold > 0.0 {
        threshold
    } else {
        DEFAULT_N_SIGMA
    }
}
