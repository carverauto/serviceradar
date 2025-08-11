// This module contains the actual eBPF profiling logic using the new Aya approach

use anyhow::Result;
use aya::{
    include_bytes_aligned,
    maps::{MapData, RingBuf, Array},
    programs::{perf_event, PerfEvent},
    util::online_cpus,
    Bpf, BpfLoader,
};
use aya_log::BpfLogger;
use log::{debug, info, warn};
use profiler_common::Sample;
use tokio::io::unix::AsyncFd;
use std::time::Duration;


pub struct SymbolResolver {
    exe_path: Option<String>,
    addr2line_available: bool,
    symbol_cache: std::collections::HashMap<u64, String>,
}

impl SymbolResolver {
    pub fn new() -> Self {
        Self {
            exe_path: None,
            addr2line_available: false,
            symbol_cache: std::collections::HashMap::new(),
        }
    }

    pub fn initialize_for_pid(&mut self, pid: u32) {
        // Try to get the executable path for this PID
        let proc_exe_path = format!("/proc/{}/exe", pid);
        match std::fs::read_link(&proc_exe_path) {
            Ok(path) => {
                let exe_path = path.to_string_lossy().to_string();
                info!("Symbol resolution: Found executable path: {}", exe_path);
                self.exe_path = Some(exe_path);
                
                // Check if addr2line is available
                self.addr2line_available = self.check_addr2line_available();
                if self.addr2line_available {
                    info!("Symbol resolution: addr2line is available");
                } else {
                    warn!("Symbol resolution: addr2line not available, will show addresses only");
                }
            }
            Err(e) => {
                warn!("Failed to get executable path for PID {}: {}", pid, e);
            }
        }
    }

    fn check_addr2line_available(&self) -> bool {
        std::process::Command::new("addr2line")
            .arg("--help")
            .output()
            .is_ok()
    }

    pub fn resolve_symbol(&mut self, _pid: u32, addr: u64) -> String {
        // Check cache first
        if let Some(cached) = self.symbol_cache.get(&addr) {
            return cached.clone();
        }

        let symbol = self.resolve_symbol_internal(addr);
        
        // Cache the result (limit cache size to prevent memory issues)
        if self.symbol_cache.len() < 10000 {
            self.symbol_cache.insert(addr, symbol.clone());
        }
        
        symbol
    }

    fn resolve_symbol_internal(&mut self, addr: u64) -> String {
        // If we don't have the executable path or addr2line, just return the address
        if !self.addr2line_available {
            return format!("0x{:x}", addr);
        }

        let exe_path = match &self.exe_path {
            Some(path) => path,
            None => return format!("0x{:x}", addr),
        };

        // Try to resolve with addr2line
        match std::process::Command::new("addr2line")
            .args(&["-f", "-C", "-e", exe_path])
            .arg(format!("0x{:x}", addr))
            .output()
        {
            Ok(output) if output.status.success() => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let lines: Vec<&str> = stdout.trim().split('\n').collect();
                
                // addr2line output format:
                // Line 1: function name (or ?? if unknown)  
                // Line 2: file:line (or ??:0 if unknown)
                if lines.len() >= 1 {
                    let function_name = lines[0];
                    if function_name != "??" && !function_name.is_empty() {
                        // Clean up the function name
                        let clean_name = function_name
                            .split_whitespace()
                            .next()
                            .unwrap_or(function_name)
                            .to_string();
                        
                        // If we have file info too, add it
                        if lines.len() >= 2 && lines[1] != "??:0" {
                            let file_info = lines[1].split('/').last().unwrap_or(lines[1]);
                            return format!("{}+0x{:x} ({})", clean_name, addr, file_info);
                        } else {
                            return format!("{}+0x{:x}", clean_name, addr);
                        }
                    }
                }
                
                // If addr2line didn't find anything useful, fall back to address
                format!("0x{:x}", addr)
            }
            Ok(_) => {
                // addr2line failed, try nm as fallback
                self.resolve_with_nm(exe_path, addr).unwrap_or_else(|| format!("0x{:x}", addr))
            }
            Err(_) => format!("0x{:x}", addr),
        }
    }

    fn resolve_with_nm(&self, exe_path: &str, addr: u64) -> Option<String> {
        // Try to use nm to get symbols and find the closest one
        match std::process::Command::new("nm")
            .args(&["-C", "-n", exe_path])
            .output()
        {
            Ok(output) if output.status.success() => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let mut best_match: Option<(u64, String)> = None;
                
                for line in stdout.lines() {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 3 {
                        if let Ok(symbol_addr) = u64::from_str_radix(parts[0], 16) {
                            if symbol_addr <= addr {
                                let symbol_name = parts[2..].join(" ");
                                best_match = Some((symbol_addr, symbol_name));
                            } else {
                                break; // nm output is sorted, so we can stop here
                            }
                        }
                    }
                }
                
                if let Some((symbol_addr, symbol_name)) = best_match {
                    let offset = addr - symbol_addr;
                    Some(format!("{}+0x{:x}", symbol_name, offset))
                } else {
                    None
                }
            }
            _ => None,
        }
    }
}

pub struct EbpfProfiler {
    bpf: Option<Bpf>,
    ring_buf: Option<AsyncFd<RingBuf<MapData>>>,
    perf_links: Vec<perf_event::PerfEventLinkId>,
    symbol_resolver: SymbolResolver,
}

impl EbpfProfiler {
    pub fn new() -> Result<Self> {
        debug!("Creating eBPF profiler");
        Ok(Self {
            bpf: None,
            ring_buf: None,
            perf_links: Vec::new(),
            symbol_resolver: SymbolResolver::new(),
        })
    }
    
    fn verify_process_exists(pid: i32) -> Result<()> {
        let proc_path = format!("/proc/{}", pid);
        if !std::path::Path::new(&proc_path).exists() {
            return Err(anyhow::anyhow!("Process {} does not exist", pid));
        }
        
        // Check if process is actually running (not zombie)
        let status_path = format!("/proc/{}/status", pid);
        if let Ok(status_content) = std::fs::read_to_string(&status_path) {
            for line in status_content.lines() {
                if line.starts_with("State:") {
                    if line.contains("Z (zombie)") {
                        return Err(anyhow::anyhow!("Process {} is a zombie", pid));
                    }
                    break;
                }
            }
        }
        
        info!("✅ Process {} verified as accessible and running", pid);
        Ok(())
    }

    pub async fn start_profiling(&mut self, pid: i32, frequency: i32, _duration_seconds: i32) -> Result<()> {
        info!("Starting eBPF profiling for PID {} at {}Hz", pid, frequency);

        let target_pid = pid as u32;
        
        // Check if process exists and is accessible
        Self::verify_process_exists(pid)?;
        
        // Initialize symbol resolution for this PID
        self.symbol_resolver.initialize_for_pid(target_pid);

        // Load the eBPF program bytes
        #[cfg(debug_assertions)]
        let prog_bytes = include_bytes_aligned!("../../target/bpfel-unknown-none/debug/profiler");
        #[cfg(not(debug_assertions))]
        let prog_bytes = include_bytes_aligned!("../../target/bpfel-unknown-none/release/profiler");

        // Use BpfLoader to set the global TARGET_PID before loading
        let mut bpf = BpfLoader::new()
            .set_global("TARGET_PID", &target_pid, true)
            .load(prog_bytes)?;

        // Initialize the eBPF logger
        if let Err(e) = BpfLogger::init(&mut bpf) {
            warn!("Failed to initialize eBPF logger: {}", e);
        }

        // Get a handle to the perf event program
        let program: &mut PerfEvent = bpf
            .program_mut("perf_profiler")
            .unwrap()
            .try_into()?;

        // Load the program into the kernel
        program.load()?;

        // Use system-wide profiling with eBPF-based PID filtering
        // This approach works for all processes, including low-activity I/O-bound ones
        info!("Setting up system-wide profiling with eBPF PID filtering for PID {}", target_pid);
        
        let cpus = online_cpus()?;
        let mut attached_count = 0;

        for cpu in cpus {
            // Use CPU_CLOCK for consistent timer-based sampling regardless of process activity
            let attach_result = program.attach(
                perf_event::PerfTypeId::Software,
                perf_event::perf_sw_ids::PERF_COUNT_SW_CPU_CLOCK as u64,
                perf_event::PerfEventScope::AllProcessesOneCpu { cpu },
                perf_event::SamplePolicy::Frequency(frequency as u64),
                false, // Don't inherit for system-wide profiling
            );
            
            match attach_result {
                Ok(link) => {
                    self.perf_links.push(link);
                    attached_count += 1;
                    debug!("✅ Attached system-wide perf event to CPU {}", cpu);
                }
                Err(e) => {
                    warn!("Failed to attach to CPU {}: {}", cpu, e);
                }
            }
        }

        if attached_count == 0 {
            return Err(anyhow::anyhow!("Failed to attach perf events to any CPU"));
        } else {
            info!("✅ Successfully attached to {} CPUs for system-wide profiling", attached_count);
            info!("eBPF program will filter events to only capture PID {}", target_pid);
        }

        // Set up the ring buffer for receiving samples
        info!("Setting up ring buffer for samples");
        let map = bpf.take_map("SAMPLES").ok_or_else(|| anyhow::anyhow!("SAMPLES map not found"))?;
        let samples = RingBuf::try_from(map)?;
        let ring_buf = AsyncFd::new(samples)?;
        info!("Ring buffer initialized successfully");

        self.ring_buf = Some(ring_buf);
        self.bpf = Some(bpf);

        // Give the program a moment to start
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Log initial stats
        self.log_stats("After startup").await;

        info!("eBPF profiling started successfully for PID {}", pid);
        Ok(())
    }

    pub fn stop_profiling(&mut self) -> Result<()> {
        debug!("Stopping eBPF profiling");

        // Detach all perf events
        self.perf_links.clear();

        if self.bpf.is_some() {
            info!("eBPF profiling stopped successfully");
        } else {
            debug!("No eBPF program was loaded, nothing to stop");
        }

        Ok(())
    }

    pub async fn collect_results(&mut self) -> Result<Vec<ProfileStackTrace>> {
        info!("Starting to collect eBPF profiling results");

        // Log stats before collection
        self.log_stats("Before collection").await;

        let mut traces = Vec::new();
        let mut total_attempts = 0;
        const MAX_ATTEMPTS: u32 = 10;

        if let Some(ring_buf) = &mut self.ring_buf {
            info!("Ring buffer found, attempting to read samples");

            // Try multiple times with shorter timeouts
            while total_attempts < MAX_ATTEMPTS {
                total_attempts += 1;

                match tokio::time::timeout(
                    Duration::from_millis(500),
                    ring_buf.readable_mut()
                ).await {
                    Ok(Ok(mut guard)) => {
                        debug!("Ring buffer is readable (attempt {})", total_attempts);
                        
                        // Collect all sample data first, completely separate from parsing
                        let samples_to_process = {
                            let ring_buf_inner = guard.get_inner_mut();
                            let mut samples = Vec::new();
                            while let Some(sample_data) = ring_buf_inner.next() {
                                // Copy the sample data to process later
                                samples.push(sample_data.to_vec());
                            }
                            samples
                        };

                        let sample_count = samples_to_process.len();
                        if sample_count > 0 {
                            info!("Collected {} samples in attempt {}", sample_count, total_attempts);
                        }

                        guard.clear_ready();
                        
                        // Drop the guard explicitly to ensure the borrow is released
                        drop(guard);
                        
                        // Now parse the samples after completely releasing all borrows
                        for sample_data in samples_to_process {
                            match Self::parse_sample_static(&sample_data) {
                                Ok(mut trace) => {
                                    // Apply symbol resolution here if needed
                                    for frame in &mut trace.frames {
                                        if let Ok(addr) = u64::from_str_radix(frame.trim_start_matches("0x"), 16) {
                                            let symbol = self.symbol_resolver.resolve_symbol(0, addr);
                                            *frame = symbol;
                                        }
                                    }
                                    traces.push(trace);
                                }
                                Err(_) => continue,
                            }
                        }

                        // If we got samples, we can stop trying
                        if !traces.is_empty() {
                            break;
                        }
                    }
                    Ok(Err(e)) => {
                        warn!("Error waiting for ring buffer (attempt {}): {}", total_attempts, e);
                    }
                    Err(_) => {
                        debug!("Timeout waiting for ring buffer data (attempt {})", total_attempts);
                    }
                }

                // Small delay between attempts
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        } else {
            return Err(anyhow::anyhow!("eBPF program not loaded"));
        }

        // Log final stats
        self.log_stats("After collection").await;

        info!("Collected {} unique stack traces after {} attempts", traces.len(), total_attempts);
        Ok(traces)
    }

    async fn log_stats(&self, context: &str) {
        if let Some(bpf) = &self.bpf {
            if let Ok(stats_map) = Array::<_, u64>::try_from(bpf.map("STATS").unwrap()) {
                let total_events = stats_map.get(&0, 0).unwrap_or(0);
                let filtered_out = stats_map.get(&1, 0).unwrap_or(0);
                let samples_sent = stats_map.get(&2, 0).unwrap_or(0);
                let buffer_full = stats_map.get(&3, 0).unwrap_or(0);

                info!("eBPF Stats [{}]:", context);
                info!("  Total events: {}", total_events);
                info!("  Filtered out: {}", filtered_out);
                info!("  Samples sent: {}", samples_sent);
                info!("  Buffer full: {}", buffer_full);

                if total_events > 0 && samples_sent == 0 {
                    warn!("No samples collected despite {} events - all filtered out", total_events);
                }
            }
        }
    }

    pub fn cleanup(&mut self) {
        debug!("Cleaning up eBPF profiler resources");
        self.perf_links.clear();
        self.bpf = None;
        self.ring_buf = None;
    }

    fn parse_sample_static(sample_data: &[u8]) -> Result<ProfileStackTrace> {
        let sample = unsafe { &*(sample_data.as_ptr() as *const Sample) };

        let mut frames = Vec::new();
        // Each address is a u64, so 8 bytes
        let stack_depth = (sample.header.stack_len / 8) as usize;

        for i in 0..stack_depth {
            let offset = i * 8;
            if offset + 8 <= sample.stack.len() {
                let addr_bytes = &sample.stack[offset..offset + 8];
                let addr = u64::from_ne_bytes(addr_bytes.try_into().unwrap());
                if addr != 0 {
                    // Return raw addresses - symbol resolution will be applied later
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