// This module contains the actual eBPF profiling logic using the new Aya approach

use anyhow::Result;
use aya::{
    include_bytes_aligned,
    maps::{MapData, RingBuf},
    programs::{perf_event, PerfEvent},
    Ebpf, EbpfLoader,
};
use aya_log::EbpfLogger;
use log::{debug, info, warn};
use profiler_common::Sample;
use tokio::io::unix::AsyncFd;

pub struct EbpfProfiler {
    bpf: Option<Ebpf>,
    ring_buf: Option<AsyncFd<RingBuf<MapData>>>,
}

const EBPF_PROGRAM: &[u8] = include_bytes_aligned!(concat!(env!("SERVICERADAR_PROFILER_EBPF")));

impl EbpfProfiler {
    pub fn new() -> Result<Self> {
        debug!("Creating eBPF profiler");
        Ok(Self {
            bpf: None,
            ring_buf: None,
        })
    }

    pub async fn start_profiling(&mut self, pid: i32, frequency: i32, _duration_seconds: i32) -> Result<()> {
        info!("Starting eBPF profiling for PID {} at {}Hz", pid, frequency);
        
        let target_pid = pid as u32;

        // Load the eBPF program bytes
        let prog_bytes = EBPF_PROGRAM;

        // Use EbpfLoader to set the global PID before loading
        let mut bpf = EbpfLoader::new()
            .set_global("PID", &target_pid, true)
            .load(prog_bytes)?;
        
        // Initialize the eBPF logger. This is critical for preventing faults.
        if let Err(e) = EbpfLogger::init(&mut bpf) {
            // This warning is normal if the eBPF code has no log statements.
            warn!("Failed to initialize eBPF logger: {}", e);
        }

        // Get a handle to the perf event program
        let program: &mut PerfEvent = bpf
            .program_mut("perf_profiler")
            .unwrap()
            .try_into()?;

        // Load the program into the kernel
        program.load()?;

        // Attach to the perf event
        info!("Attaching perf event to PID {} with frequency {}Hz", target_pid, frequency);
        
        // Attach directly to the single process. The kernel will handle filtering.
        program.attach(
            perf_event::PerfTypeId::Software,
            perf_event::perf_sw_ids::PERF_COUNT_SW_CPU_CLOCK as u64,
            perf_event::PerfEventScope::OneProcessAnyCpu { pid: target_pid },
            perf_event::SamplePolicy::Frequency(frequency as u64),
            true, // inherit child processes
        )?;
        info!("Perf event attached successfully");

        // Set up the ring buffer for receiving samples
        info!("Setting up ring buffer for samples");
        let map = bpf.take_map("SAMPLES").ok_or_else(|| anyhow::anyhow!("SAMPLES map not found"))?;
        info!("Found SAMPLES map");
        let samples = RingBuf::try_from(map)?;
        let ring_buf = AsyncFd::new(samples)?;
        info!("Ring buffer initialized successfully");
        
        self.ring_buf = Some(ring_buf);
        // Store the bpf object to keep the program and its link alive
        self.bpf = Some(bpf);

        // Give the program a moment to start
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        info!("eBPF profiling started successfully for PID {}", pid);
        Ok(())
    }

    pub fn stop_profiling(&mut self) -> Result<()> {
        debug!("Stopping eBPF profiling");
        
        if self.bpf.is_some() {
            // Don't clear the state here - we need it for collect_results
            info!("eBPF profiling stopped successfully");
        } else {
            debug!("No eBPF program was loaded, nothing to stop");
        }
        
        Ok(())
    }

    pub async fn collect_results(&mut self) -> Result<Vec<ProfileStackTrace>> {
        info!("Starting to collect eBPF profiling results");
        
        let mut traces = Vec::new();
        
        if let Some(ring_buf) = &mut self.ring_buf {
            info!("Ring buffer found, attempting to read samples");
            
            // Use tokio::time::timeout to avoid indefinite waiting
            match tokio::time::timeout(
                std::time::Duration::from_secs(5),
                ring_buf.readable_mut()
            ).await {
                Ok(Ok(mut guard)) => {
                    info!("Ring buffer is readable");
                    let ring_buf_inner = guard.get_inner_mut();
                    
                    let mut sample_count = 0;
                    while let Some(sample_data) = ring_buf_inner.next() {
                        sample_count += 1;
                        let parsed_sample = Self::parse_sample_static(&sample_data);
                        if let Ok(trace) = parsed_sample {
                            traces.push(trace);
                        }
                    }
                    info!("Processed {} samples from ring buffer", sample_count);
                    guard.clear_ready();
                }
                Ok(Err(e)) => {
                    warn!("Error waiting for ring buffer: {}", e);
                }
                Err(_) => {
                    warn!("Timeout waiting for ring buffer data (5s)");
                }
            }
        } else {
            return Err(anyhow::anyhow!("eBPF program not loaded"));
        }
        
        info!("Collected {} unique stack traces", traces.len());
        Ok(traces)
    }

    pub fn cleanup(&mut self) {
        debug!("Cleaning up eBPF profiler resources");
        self.bpf = None;
        self.ring_buf = None;
    }

    fn parse_sample_static(sample_data: &[u8]) -> Result<ProfileStackTrace> {
        let sample = unsafe { &*(sample_data.as_ptr() as *const Sample) };
        
        let mut frames = Vec::new();
        // Each address is a u64, so 8 bytes.
        let stack_depth = (sample.header.stack_len / 8) as usize;
        
        for i in 0..stack_depth {
            let offset = i * 8;
            if offset + 8 <= sample.stack.len() {
                let addr_bytes = &sample.stack[offset..offset + 8];
                let addr = u64::from_ne_bytes(addr_bytes.try_into().unwrap());
                if addr != 0 {
                    // In a real application, you would resolve these symbols.
                    frames.push(format!("0x{:x}", addr));
                }
            }
        }
        
        Ok(ProfileStackTrace {
            frames,
            count: 1, // Each sample from the ring buffer is unique initially
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
