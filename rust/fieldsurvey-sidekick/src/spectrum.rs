use serde::Serialize;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use tokio::sync::mpsc;

#[derive(Debug, Clone, PartialEq)]
pub struct SpectrumSweep {
    pub sidekick_id: String,
    pub sdr_id: String,
    pub device_kind: String,
    pub serial_number: Option<String>,
    pub sweep_id: u64,
    pub started_at_unix_nanos: i64,
    pub captured_at_unix_nanos: i64,
    pub start_frequency_hz: u64,
    pub stop_frequency_hz: u64,
    pub bin_width_hz: f32,
    pub sample_count: u32,
    pub power_bins_dbm: Vec<f32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpectrumSweepRequest {
    pub sidekick_id: String,
    pub sdr_id: String,
    pub serial_number: Option<String>,
    pub frequency_min_mhz: u32,
    pub frequency_max_mhz: u32,
    pub bin_width_hz: u32,
    pub lna_gain_db: u8,
    pub vga_gain_db: u8,
    pub sweep_count: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SpectrumSummary {
    pub sidekick_id: String,
    pub sdr_id: String,
    pub device_kind: String,
    pub serial_number: Option<String>,
    pub sweep_id: u64,
    pub captured_at_unix_nanos: i64,
    pub start_frequency_hz: u64,
    pub stop_frequency_hz: u64,
    pub bin_width_hz: f32,
    pub sample_count: u32,
    pub average_power_dbm: f32,
    pub peak_power_dbm: f32,
    pub peak_frequency_hz: u64,
    pub sweep_rate_hz: Option<f32>,
    pub channel_scores: Vec<SpectrumChannelScore>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SpectrumChannelScore {
    pub band: String,
    pub channel: u16,
    pub center_frequency_mhz: u16,
    pub average_power_dbm: f32,
    pub peak_power_dbm: f32,
    pub interference_score: u8,
    pub sample_count: u32,
}

pub fn spawn_hackrf_sweep(
    request: SpectrumSweepRequest,
) -> mpsc::Receiver<Result<SpectrumSweep, String>> {
    let (tx, rx) = mpsc::channel(256);

    std::thread::spawn(move || run_hackrf_sweep(request, tx));

    rx
}

fn run_hackrf_sweep(
    request: SpectrumSweepRequest,
    tx: mpsc::Sender<Result<SpectrumSweep, String>>,
) {
    let mut command = Command::new("hackrf_sweep");
    command
        .arg("-a")
        .arg("0")
        .arg("-p")
        .arg("0")
        .arg("-l")
        .arg(request.lna_gain_db.to_string())
        .arg("-g")
        .arg(request.vga_gain_db.to_string())
        .arg("-f")
        .arg(format!(
            "{}:{}",
            request.frequency_min_mhz, request.frequency_max_mhz
        ))
        .arg("-w")
        .arg(request.bin_width_hz.to_string())
        .arg("-N")
        .arg(request.sweep_count.to_string())
        .arg("-n")
        .stdout(Stdio::piped())
        .stderr(Stdio::null());

    if let Some(serial_number) = request.serial_number.as_deref() {
        command.arg("-d").arg(serial_number);
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            let _ = tx.blocking_send(Err(format!("failed to start hackrf_sweep: {error}")));
            return;
        }
    };

    let Some(stdout) = child.stdout.take() else {
        let _ = tx.blocking_send(Err("hackrf_sweep stdout was unavailable".to_string()));
        let _ = child.kill();
        return;
    };

    let reader = BufReader::new(stdout);
    let mut sweep_id = 0_u64;

    for line in reader.lines() {
        let line = match line {
            Ok(line) => line,
            Err(error) => {
                let _ =
                    tx.blocking_send(Err(format!("failed reading hackrf_sweep output: {error}")));
                break;
            }
        };

        if line.trim().is_empty() || line.starts_with("date,") {
            continue;
        }

        match parse_hackrf_sweep_line(&request, sweep_id, &line) {
            Ok(sweep) => {
                sweep_id = sweep_id.saturating_add(1);
                if tx.blocking_send(Ok(sweep)).is_err() {
                    break;
                }
            }
            Err(error) => {
                let _ = tx.blocking_send(Err(error));
                break;
            }
        }
    }

    let _ = child.kill();
    let _ = child.wait();
}

pub fn parse_hackrf_sweep_line(
    request: &SpectrumSweepRequest,
    sweep_id: u64,
    line: &str,
) -> Result<SpectrumSweep, String> {
    let fields = line.split(',').map(str::trim).collect::<Vec<_>>();
    if fields.len() < 7 {
        return Err(format!("hackrf_sweep row has too few fields: {line}"));
    }

    let captured_at_unix_nanos = parse_hackrf_timestamp(fields[0], fields[1])?;
    let start_frequency_hz = fields[2]
        .parse::<u64>()
        .map_err(|error| format!("invalid sweep hz_low: {error}"))?;
    let stop_frequency_hz = fields[3]
        .parse::<u64>()
        .map_err(|error| format!("invalid sweep hz_high: {error}"))?;
    let bin_width_hz = fields[4]
        .parse::<f32>()
        .map_err(|error| format!("invalid sweep bin width: {error}"))?;
    let sample_count = fields[5]
        .parse::<u32>()
        .map_err(|error| format!("invalid sweep sample count: {error}"))?;
    let mut power_bins_dbm = Vec::with_capacity(fields.len().saturating_sub(6));

    for value in fields.iter().skip(6) {
        power_bins_dbm.push(
            value
                .parse::<f32>()
                .map_err(|error| format!("invalid sweep power bin: {error}"))?,
        );
    }

    Ok(SpectrumSweep {
        sidekick_id: request.sidekick_id.clone(),
        sdr_id: request.sdr_id.clone(),
        device_kind: "hackrf".to_string(),
        serial_number: request.serial_number.clone(),
        sweep_id,
        started_at_unix_nanos: captured_at_unix_nanos,
        captured_at_unix_nanos,
        start_frequency_hz,
        stop_frequency_hz,
        bin_width_hz,
        sample_count,
        power_bins_dbm,
    })
}

pub fn summarize_sweep(sweep: &SpectrumSweep, sweep_rate_hz: Option<f32>) -> SpectrumSummary {
    let (average_power_dbm, peak_power_dbm, peak_frequency_hz) = summarize_bins(sweep);

    SpectrumSummary {
        sidekick_id: sweep.sidekick_id.clone(),
        sdr_id: sweep.sdr_id.clone(),
        device_kind: sweep.device_kind.clone(),
        serial_number: sweep.serial_number.clone(),
        sweep_id: sweep.sweep_id,
        captured_at_unix_nanos: sweep.captured_at_unix_nanos,
        start_frequency_hz: sweep.start_frequency_hz,
        stop_frequency_hz: sweep.stop_frequency_hz,
        bin_width_hz: sweep.bin_width_hz,
        sample_count: sweep.sample_count,
        average_power_dbm,
        peak_power_dbm,
        peak_frequency_hz,
        sweep_rate_hz,
        channel_scores: summarize_channels(sweep),
    }
}

fn summarize_bins(sweep: &SpectrumSweep) -> (f32, f32, u64) {
    if sweep.power_bins_dbm.is_empty() {
        return (f32::NAN, f32::NAN, sweep.start_frequency_hz);
    }

    let mut sum = 0.0_f32;
    let mut peak = f32::NEG_INFINITY;
    let mut peak_index = 0_usize;

    for (index, value) in sweep.power_bins_dbm.iter().enumerate() {
        sum += *value;
        if *value > peak {
            peak = *value;
            peak_index = index;
        }
    }

    let average = sum / sweep.power_bins_dbm.len() as f32;
    let peak_frequency_hz = bin_center_hz(sweep, peak_index);
    (average, peak, peak_frequency_hz)
}

fn summarize_channels(sweep: &SpectrumSweep) -> Vec<SpectrumChannelScore> {
    let mut scores = Vec::new();

    for channel in 1_u16..=11 {
        let center = 2_407_u16 + channel * 5;
        if let Some(score) = summarize_channel(sweep, "2.4GHz", channel, center, 10) {
            scores.push(score);
        }
    }

    for (channel, center) in five_ghz_channels() {
        if let Some(score) = summarize_channel(sweep, "5GHz", channel, center, 10) {
            scores.push(score);
        }
    }

    scores
}

fn summarize_channel(
    sweep: &SpectrumSweep,
    band: &str,
    channel: u16,
    center_frequency_mhz: u16,
    half_width_mhz: u64,
) -> Option<SpectrumChannelScore> {
    let center_hz = u64::from(center_frequency_mhz) * 1_000_000;
    let half_width_hz = half_width_mhz * 1_000_000;
    if center_hz.saturating_add(half_width_hz) < sweep.start_frequency_hz
        || center_hz.saturating_sub(half_width_hz) > sweep.stop_frequency_hz
    {
        return None;
    }

    let low_hz = center_hz.saturating_sub(half_width_hz);
    let high_hz = center_hz.saturating_add(half_width_hz);
    let mut sum = 0.0_f32;
    let mut peak = f32::NEG_INFINITY;
    let mut count = 0_u32;

    for (index, power) in sweep.power_bins_dbm.iter().enumerate() {
        let frequency = bin_center_hz(sweep, index);
        if frequency >= low_hz && frequency <= high_hz {
            sum += *power;
            peak = peak.max(*power);
            count = count.saturating_add(1);
        }
    }

    if count == 0 {
        return None;
    }

    let average = sum / count as f32;
    Some(SpectrumChannelScore {
        band: band.to_string(),
        channel,
        center_frequency_mhz,
        average_power_dbm: average,
        peak_power_dbm: peak,
        interference_score: interference_score(average, peak),
        sample_count: count,
    })
}

fn bin_center_hz(sweep: &SpectrumSweep, index: usize) -> u64 {
    let offset = (index as f64 + 0.5) * f64::from(sweep.bin_width_hz);
    sweep
        .start_frequency_hz
        .saturating_add(offset.max(0.0).round() as u64)
}

fn interference_score(average_power_dbm: f32, peak_power_dbm: f32) -> u8 {
    let average_score = normalized_power_score(average_power_dbm);
    let peak_score = normalized_power_score(peak_power_dbm).saturating_sub(10);
    average_score.max(peak_score)
}

fn normalized_power_score(power_dbm: f32) -> u8 {
    if !power_dbm.is_finite() {
        return 0;
    }

    let normalized = ((power_dbm + 95.0) / 45.0 * 100.0).clamp(0.0, 100.0);
    normalized.round() as u8
}

fn five_ghz_channels() -> Vec<(u16, u16)> {
    vec![
        (36, 5180),
        (40, 5200),
        (44, 5220),
        (48, 5240),
        (52, 5260),
        (56, 5280),
        (60, 5300),
        (64, 5320),
        (100, 5500),
        (104, 5520),
        (108, 5540),
        (112, 5560),
        (116, 5580),
        (120, 5600),
        (124, 5620),
        (128, 5640),
        (132, 5660),
        (136, 5680),
        (140, 5700),
        (144, 5720),
        (149, 5745),
        (153, 5765),
        (157, 5785),
        (161, 5805),
        (165, 5825),
    ]
}

fn parse_hackrf_timestamp(date: &str, time: &str) -> Result<i64, String> {
    let date_parts = date
        .split('-')
        .map(|part| part.parse::<i32>())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("invalid sweep date: {error}"))?;
    if date_parts.len() != 3 {
        return Err(format!("invalid sweep date: {date}"));
    }

    let (time_part, fractional_part) = time.split_once('.').unwrap_or((time, "0"));
    let time_parts = time_part
        .split(':')
        .map(|part| part.parse::<i32>())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("invalid sweep time: {error}"))?;
    if time_parts.len() != 3 {
        return Err(format!("invalid sweep time: {time}"));
    }

    let seconds = unix_seconds_from_ymdhms(
        date_parts[0],
        date_parts[1],
        date_parts[2],
        time_parts[0],
        time_parts[1],
        time_parts[2],
    )?;
    let fractional_nanos = fractional_part
        .chars()
        .take(9)
        .collect::<String>()
        .parse::<u32>()
        .unwrap_or(0)
        * 10_u32.saturating_pow(9_u32.saturating_sub(fractional_part.len().min(9) as u32));

    Ok(seconds
        .saturating_mul(1_000_000_000)
        .saturating_add(i64::from(fractional_nanos)))
}

fn unix_seconds_from_ymdhms(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
) -> Result<i64, String> {
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || !(0..=23).contains(&hour)
        || !(0..=59).contains(&minute)
        || !(0..=60).contains(&second)
    {
        return Err("timestamp component out of range".to_string());
    }

    let days = days_from_civil(year, month, day);
    Ok(days
        .saturating_mul(86_400)
        .saturating_add(i64::from(hour * 3_600 + minute * 60 + second)))
}

fn days_from_civil(year: i32, month: i32, day: i32) -> i64 {
    let year = year - i32::from(month <= 2);
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;

    i64::from(era * 146_097 + day_of_era - 719_468)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hackrf_sweep_row() {
        let request = SpectrumSweepRequest {
            sidekick_id: "sidekick-1".to_string(),
            sdr_id: "hackrf-0".to_string(),
            serial_number: Some("abc".to_string()),
            frequency_min_mhz: 2400,
            frequency_max_mhz: 2484,
            bin_width_hz: 1_000_000,
            lna_gain_db: 8,
            vga_gain_db: 8,
            sweep_count: 1024,
        };
        let sweep = parse_hackrf_sweep_line(
            &request,
            7,
            "2026-04-25, 17:16:20.785750, 2400000000, 2405000000, 1000000.00, 20, -74.66, -69.44",
        )
        .unwrap();

        assert_eq!(sweep.sidekick_id, "sidekick-1");
        assert_eq!(sweep.sdr_id, "hackrf-0");
        assert_eq!(sweep.sweep_id, 7);
        assert_eq!(sweep.captured_at_unix_nanos, 1_777_137_380_785_750_000);
        assert_eq!(sweep.start_frequency_hz, 2_400_000_000);
        assert_eq!(sweep.stop_frequency_hz, 2_405_000_000);
        assert_eq!(sweep.power_bins_dbm, vec![-74.66, -69.44]);
    }

    #[test]
    fn summarizes_2ghz_channels() {
        let sweep = SpectrumSweep {
            sidekick_id: "sidekick-1".to_string(),
            sdr_id: "hackrf-0".to_string(),
            device_kind: "hackrf".to_string(),
            serial_number: None,
            sweep_id: 7,
            started_at_unix_nanos: 1,
            captured_at_unix_nanos: 2,
            start_frequency_hz: 2_400_000_000,
            stop_frequency_hz: 2_500_000_000,
            bin_width_hz: 1_000_000.0,
            sample_count: 100,
            power_bins_dbm: (0..100)
                .map(|index| if index == 12 { -38.0 } else { -92.0 })
                .collect(),
        };

        let summary = summarize_sweep(&sweep, Some(20.0));
        let channel_one = summary
            .channel_scores
            .iter()
            .find(|score| score.band == "2.4GHz" && score.channel == 1)
            .unwrap();

        assert_eq!(summary.peak_frequency_hz, 2_412_500_000);
        assert_eq!(summary.sweep_rate_hz, Some(20.0));
        assert!(channel_one.interference_score > 0);
    }
}
