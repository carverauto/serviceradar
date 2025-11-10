// Output formatters for different profiling result formats

use anyhow::Result;
use log::{debug, info};
use serde_json;
use std::fs::File;
use std::io::Write;

use crate::cli::OutputFormat;
use crate::ebpf_profiler::ProfileStackTrace;
use crate::flame_graph::FlameGraphFormatter;

pub struct OutputWriter {
    format: OutputFormat,
    output_path: String,
}

impl OutputWriter {
    pub fn new(format: OutputFormat, output_path: String) -> Self {
        Self {
            format,
            output_path,
        }
    }

    pub fn format(&self) -> &OutputFormat {
        &self.format
    }

    pub fn write_profile(
        &self,
        stack_traces: Vec<ProfileStackTrace>,
        pid: i32,
        duration: i32,
    ) -> Result<()> {
        info!(
            "Writing profile data to {} in {:?} format",
            self.output_path, self.format
        );

        match self.format {
            OutputFormat::Pprof => self.write_pprof(stack_traces, pid, duration),
            OutputFormat::FlameGraph => self.write_flamegraph(stack_traces, pid, duration),
            OutputFormat::Json => self.write_json(stack_traces, pid, duration),
        }
    }

    fn write_pprof(
        &self,
        stack_traces: Vec<ProfileStackTrace>,
        pid: i32,
        duration: i32,
    ) -> Result<()> {
        debug!(
            "Generating pprof-compatible format with {} stack traces",
            stack_traces.len()
        );

        // For now, create a simple text-based pprof format that Go tools can read
        // This is a simplified implementation - a full pprof implementation would use protobuf
        let mut output = String::new();

        // Write pprof header
        output.push_str(&format!(
            "heap profile: {} {}: {} {} heap\n",
            stack_traces.len(),
            stack_traces.iter().map(|t| t.count).sum::<u64>(),
            stack_traces.len(),
            stack_traces.iter().map(|t| t.count).sum::<u64>()
        ));

        // Calculate totals first
        let total_samples: u64 = stack_traces.iter().map(|t| t.count).sum();
        let unique_stacks = stack_traces.len();

        // Write stack traces in pprof text format
        for stack_trace in &stack_traces {
            // Write sample line: count [count2] @hex_addresses
            output.push_str(&format!("{} {} @ ", stack_trace.count, stack_trace.count));

            // Add fake hex addresses for each frame (pprof format requirement)
            for (i, _frame) in stack_trace.frames.iter().enumerate() {
                output.push_str(&format!("0x{:x} ", 0x400000 + (i * 0x10)));
            }
            output.push('\n');

            // Write frame information
            for (i, frame) in stack_trace.frames.iter().enumerate() {
                output.push_str(&format!("#   0x{:x} {}\n", 0x400000 + (i * 0x10), frame));
            }
            output.push('\n');
        }

        // Write profile metadata
        output.push_str("\n# Profile metadata\n");
        output.push_str(&format!("# PID: {}\n", pid));
        output.push_str(&format!("# Duration: {}s\n", duration));
        output.push_str(&format!("# Total samples: {}\n", total_samples));
        output.push_str(&format!("# Unique stacks: {}\n", unique_stacks));

        let mut file = File::create(&self.output_path)?;
        file.write_all(output.as_bytes())?;

        info!(
            "Successfully wrote pprof-compatible profile to {}",
            self.output_path
        );
        info!("View with: go tool pprof -text {}", self.output_path);

        Ok(())
    }

    fn write_flamegraph(
        &self,
        stack_traces: Vec<ProfileStackTrace>,
        pid: i32,
        duration: i32,
    ) -> Result<()> {
        debug!(
            "Generating flame graph format with {} stack traces",
            stack_traces.len()
        );

        let formatter = FlameGraphFormatter::new(stack_traces);
        let flame_graph_data = formatter.generate_complete_output(pid, duration);

        let mut file = File::create(&self.output_path)?;
        file.write_all(&flame_graph_data)?;

        info!(
            "Successfully wrote flame graph data to {}",
            self.output_path
        );
        info!(
            "Generate SVG with: flamegraph.pl {} > output.svg",
            self.output_path
        );

        Ok(())
    }

    fn write_json(
        &self,
        stack_traces: Vec<ProfileStackTrace>,
        pid: i32,
        duration: i32,
    ) -> Result<()> {
        debug!(
            "Generating JSON format with {} stack traces",
            stack_traces.len()
        );

        let json_output = JsonProfileOutput {
            metadata: JsonMetadata {
                pid,
                duration_seconds: duration,
                total_samples: stack_traces.iter().map(|t| t.count).sum(),
                unique_stacks: stack_traces.len(),
                timestamp: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs(),
            },
            stack_traces: stack_traces
                .into_iter()
                .map(|trace| JsonStackTrace {
                    frames: trace.frames,
                    count: trace.count,
                    percentage: 0.0, // Will be calculated below
                })
                .collect(),
        };

        // Calculate percentages
        let total_samples = json_output.metadata.total_samples as f64;
        let mut json_output = json_output;
        for trace in &mut json_output.stack_traces {
            trace.percentage = (trace.count as f64 / total_samples) * 100.0;
        }

        let json_string = serde_json::to_string_pretty(&json_output)?;
        let mut file = File::create(&self.output_path)?;
        file.write_all(json_string.as_bytes())?;

        info!("Successfully wrote JSON profile to {}", self.output_path);

        Ok(())
    }
}

#[derive(serde::Serialize)]
struct JsonProfileOutput {
    metadata: JsonMetadata,
    stack_traces: Vec<JsonStackTrace>,
}

#[derive(serde::Serialize)]
struct JsonMetadata {
    pid: i32,
    duration_seconds: i32,
    total_samples: u64,
    unique_stacks: usize,
    timestamp: u64,
}

#[derive(serde::Serialize)]
struct JsonStackTrace {
    frames: Vec<String>,
    count: u64,
    percentage: f64,
}

// Helper function to suggest output filename if not provided
pub fn suggest_output_filename(pid: i32, format: &OutputFormat) -> String {
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    match format {
        OutputFormat::Pprof => format!("profile_pid_{}__{}.pb.gz", pid, timestamp),
        OutputFormat::FlameGraph => format!("profile_pid_{}__{}.folded", pid, timestamp),
        OutputFormat::Json => format!("profile_pid_{}__{}.json", pid, timestamp),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    fn create_test_stack_traces() -> Vec<StackTrace> {
        vec![
            StackTrace {
                frames: vec!["main".to_string(), "foo".to_string(), "bar".to_string()],
                count: 10,
            },
            StackTrace {
                frames: vec!["main".to_string(), "foo".to_string(), "baz".to_string()],
                count: 20,
            },
        ]
    }

    #[test]
    fn test_suggest_output_filename() {
        let pprof_name = suggest_output_filename(123, &OutputFormat::Pprof);
        assert!(pprof_name.contains("profile_pid_123"));
        assert!(pprof_name.ends_with(".pb.gz"));

        let flame_name = suggest_output_filename(456, &OutputFormat::FlameGraph);
        assert!(flame_name.contains("profile_pid_456"));
        assert!(flame_name.ends_with(".folded"));

        let json_name = suggest_output_filename(789, &OutputFormat::Json);
        assert!(json_name.contains("profile_pid_789"));
        assert!(json_name.ends_with(".json"));
    }

    #[test]
    fn test_write_json() -> Result<()> {
        let temp_file = NamedTempFile::new()?;
        let writer = OutputWriter::new(
            OutputFormat::Json,
            temp_file.path().to_string_lossy().to_string(),
        );

        let stack_traces = create_test_stack_traces();
        writer.write_json(stack_traces, 123, 30)?;

        let content = std::fs::read_to_string(temp_file.path())?;
        assert!(content.contains("\"pid\": 123"));
        assert!(content.contains("\"duration_seconds\": 30"));
        assert!(content.contains("\"total_samples\": 30"));
        assert!(content.contains("main"));
        assert!(content.contains("foo"));

        Ok(())
    }

    #[test]
    fn test_write_flamegraph() -> Result<()> {
        let temp_file = NamedTempFile::new()?;
        let writer = OutputWriter::new(
            OutputFormat::FlameGraph,
            temp_file.path().to_string_lossy().to_string(),
        );

        let stack_traces = create_test_stack_traces();
        writer.write_flamegraph(stack_traces, 123, 30)?;

        let content = std::fs::read_to_string(temp_file.path())?;
        assert!(content.contains("main;foo;bar 10"));
        assert!(content.contains("main;foo;baz 20"));
        assert!(content.contains("# PID: 123"));

        Ok(())
    }
}
