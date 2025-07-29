// This module contains the actual eBPF profiling logic using the new Aya approach

use anyhow::Result;
use aya::{include_bytes_aligned, maps::MapData, programs::perf_event, Bpf};
use aya::maps::RingBuf;
use log::{debug, info};
use profiler_common::Sample;
use tokio::io::unix::AsyncFd;

pub struct EbpfProfiler {
    bpf: Option<Bpf>,
    ring_buf: Option<AsyncFd<RingBuf<MapData>>>,
    target_pid: Option<u32>,
}

impl EbpfProfiler {
    pub fn new() -> Result<Self> {
        debug!("Creating eBPF profiler");
        Ok(Self {
            bpf: None,
            ring_buf: None,
            target_pid: None,
        })
    }

    pub async fn start_profiling(&mut self, pid: i32, frequency: i32, _duration_seconds: i32) -> Result<()> {
        info!("Starting eBPF profiling for PID {} at {}Hz", pid, frequency);
        
        let target_pid = pid as u32;
        self.target_pid = Some(target_pid);

        // Load eBPF program
        #[cfg(debug_assertions)]
        let mut bpf = Bpf::load(include_bytes_aligned!(
            "../../target/bpfel-unknown-none/debug/profiler"
        ))?;
        
        #[cfg(not(debug_assertions))]
        let mut bpf = Bpf::load(include_bytes_aligned!(
            "../../target/bpfel-unknown-none/release/profiler"
        ))?;

        // Initialize eBPF logger - skip on compilation errors
        // if let Err(e) = aya_log::EbpfLogger::init(&mut bpf) {
        //     warn!("Failed to initialize eBPF logger: {}", e);
        // }

        // Get handle to perf event program
        let program: &mut perf_event::PerfEvent = bpf
            .program_mut("perf_profiler")
            .unwrap()
            .try_into()?;

        // Load program into kernel
        program.load()?;

        // Attach to perf events
        program.attach(
            perf_event::PerfTypeId::Software,
            perf_event::perf_sw_ids::PERF_COUNT_SW_CPU_CLOCK as u64,
            perf_event::PerfEventScope::OneProcessAnyCpu { pid: target_pid },
            perf_event::SamplePolicy::Frequency(frequency as u64),
            true, // inherit
        )?;

        // Set up ring buffer
        let samples = RingBuf::try_from(bpf.take_map("SAMPLES").unwrap())?;
        let ring_buf = AsyncFd::new(samples)?;
        self.ring_buf = Some(ring_buf);
        self.bpf = Some(bpf);

        info!("eBPF profiling started successfully for PID {}", pid);
        Ok(())
    }

    pub fn stop_profiling(&mut self) -> Result<()> {
        debug!("Stopping eBPF profiling");
        
        if self.bpf.is_some() {
            self.bpf = None;
            self.ring_buf = None;
            self.target_pid = None;
            info!("eBPF profiling stopped successfully");
        } else {
            debug!("No eBPF program was loaded, nothing to stop");
        }
        
        Ok(())
    }

    pub async fn collect_results(&mut self) -> Result<Vec<ProfileStackTrace>> {
        debug!("Collecting eBPF profiling results");
        
        let mut traces = Vec::new();
        
        if let Some(ring_buf) = &mut self.ring_buf {
            let mut guard = ring_buf.readable_mut().await?;
            let ring_buf_inner = guard.get_inner_mut();
            
            // Use next() instead of read() for RingBuf
            while let Some(sample_data) = ring_buf_inner.next() {
                // Parse sample outside of self to avoid borrowing issues
                let parsed_sample = Self::parse_sample_static(&sample_data);
                if let Ok(trace) = parsed_sample {
                    traces.push(trace);
                }
            }
            guard.clear_ready();
        } else {
            return Err(anyhow::anyhow!("eBPF program not loaded"));
        }
        
        info!("Collected {} unique stack traces", traces.len());
        Ok(traces)
    }

    fn parse_sample_static(sample_data: &[u8]) -> Result<ProfileStackTrace> {
        // Parse the sample data to extract stack trace
        let sample = unsafe { &*(sample_data.as_ptr() as *const Sample) };
        
        let mut frames = Vec::new();
        let stack_depth = (sample.header.stack_len / 8) as usize; // 8 bytes per address
        
        // Parse the stack trace from the byte array
        for i in 0..stack_depth {
            let offset = i * 8;
            if offset + 8 <= sample.stack.len() {
                let addr_bytes = &sample.stack[offset..offset + 8];
                let addr = u64::from_ne_bytes([
                    addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3],
                    addr_bytes[4], addr_bytes[5], addr_bytes[6], addr_bytes[7],
                ]);
                if addr != 0 {
                    frames.push(format!("0x{:x}", addr));
                }
            }
        }
        
        Ok(ProfileStackTrace {
            frames,
            count: 1, // Each sample represents one occurrence
        })
    }
}

#[derive(Debug, Clone)]
pub struct ProfileStackTrace {
    pub frames: Vec<String>,
    pub count: u64,
}

impl ProfileStackTrace {
    pub fn to_folded_format(&self) -> String {
        format!("{} {}", self.frames.join(";"), self.count)
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ebpf_profiler_creation() {
        let profiler = EbpfProfiler::new();
        assert!(profiler.is_ok());
    }

    #[test]
    fn test_stack_trace_folded_format() {
        let trace = ProfileStackTrace {
            frames: vec!["main".to_string(), "foo".to_string(), "bar".to_string()],
            count: 42,
        };
        
        assert_eq!(trace.to_folded_format(), "main;foo;bar 42");
    }

}