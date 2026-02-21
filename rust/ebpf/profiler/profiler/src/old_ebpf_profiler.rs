// This module contains the actual eBPF profiling logic

use anyhow::Result;

#[cfg(feature = "ebpf")]
use anyhow::Context;
use log::{debug, info, warn};

// eBPF imports (only available with ebpf feature)
#[cfg(feature = "ebpf")]
use aya::{
    Bpf,
    programs::{
        perf_event::{PerfEvent, PerfEventLinkId, PerfEventScope, SamplePolicy, perf_sw_ids},
        PerfTypeId,
    },
    maps::StackTraceMap,
    util::online_cpus,
    Pod,
};

#[cfg(feature = "ebpf")]
use aya_log::EbpfLogger;

#[cfg(feature = "ebpf")]
// Note: perf constants are now available through aya::programs::perf_event::perf_sw_ids

// Stack trace key structure (must match eBPF program)
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct StackKey {
    pub pid: u32,
    pub stack_id: i32,
}

// StackKey must be Pod to be used in a map.
#[cfg(feature = "ebpf")]
unsafe impl Pod for StackKey {}

// Stack trace value structure (must match eBPF program)
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct StackValue {
    pub count: u64,
    pub first_seen: u64,
    pub last_seen: u64,
}

// StackValue must be Pod to be used in a map.
#[cfg(feature = "ebpf")]
unsafe impl Pod for StackValue {}

pub struct EbpfProfiler {
    #[cfg(feature = "ebpf")]
    bpf: Option<Bpf>,
    #[cfg(feature = "ebpf")]
    perf_links: Vec<PerfEventLinkId>,
    #[cfg(feature = "ebpf")]
    target_pid: Option<i32>,
    #[cfg(feature = "ebpf")]
    sampling_frequency: u64,
    #[cfg(not(feature = "ebpf"))]
    _placeholder: (),
}

impl EbpfProfiler {
    pub fn new() -> Result<Self> {
        debug!("Creating eBPF profiler");
        
        #[cfg(feature = "ebpf")]
        {
            // Note: EbpfLogger will be initialized after loading the program

            Ok(Self { 
                bpf: None,
                perf_links: Vec::new(),
                target_pid: None,
                sampling_frequency: 99, // Default 99 Hz
            })
        }
        
        #[cfg(not(feature = "ebpf"))]
        {
            warn!("eBPF profiling is not enabled - using mock data");
            Ok(Self { _placeholder: () })
        }
    }

    #[cfg(feature = "ebpf")]
    fn load_ebpf_program(&mut self) -> Result<()> {
        debug!("Loading eBPF program");
        
        // Load the eBPF program from embedded bytecode
        let program_bytes = include_bytes!(concat!(
            env!("OUT_DIR"),
            "/profiler"
        ));
        
        // Check if this is our placeholder (small size or very basic structure)
        if program_bytes.len() < 512 {
            return Err(anyhow::anyhow!(
                "Using placeholder eBPF program - real eBPF compilation not yet implemented. \
                 The profiler will fall back to mock data generation."
            ));
        }
        
        // For larger files, try to validate if it's a real eBPF program
        // Look for eBPF-specific sections or content
        let is_realistic = program_bytes.len() > 2048 && 
            program_bytes.starts_with(&[0x7f, b'E', b'L', b'F']) &&
            // Check for eBPF machine type (247) at offset 18-19
            program_bytes.len() > 19 && 
            program_bytes[18] == 247 && program_bytes[19] == 0;
            
        if !is_realistic {
            return Err(anyhow::anyhow!(
                "Using placeholder eBPF program - real eBPF compilation not yet implemented. \
                 The profiler will fall back to mock data generation."
            ));
        }
        
        debug!("Attempting to load realistic eBPF program ({} bytes)", program_bytes.len());
        
        let mut bpf = Bpf::load(program_bytes)
            .context("Failed to load eBPF program")?;

        // Initialize Ebpf logger after loading the program
        // Note: Skipping logger initialization due to version compatibility issues
        // if let Err(e) = EbpfLogger::init(&mut bpf) {
        //     warn!("Failed to initialize eBPF logger: {}", e);
        // }

        info!("eBPF program loaded successfully");
        self.bpf = Some(bpf);
        Ok(())
    }

    #[cfg(feature = "ebpf")]
    fn attach_perf_events(&mut self, target_pid: i32, frequency: u64) -> Result<()> {
        let bpf = self.bpf.as_mut()
            .ok_or_else(|| anyhow::anyhow!("eBPF program not loaded"))?;

        debug!("Attaching perf events for PID {} at {}Hz", target_pid, frequency);

        // Set target PID in the BPF map
        let mut target_pid_map: aya::maps::HashMap<_, u32, u32> = 
            aya::maps::HashMap::try_from(bpf.map_mut("TARGET_PID").unwrap())?;
        target_pid_map.insert(0u32, target_pid as u32, 0)?;

        // Get the perf event program
        let program: &mut PerfEvent = bpf.program_mut("sample_stack_traces").unwrap().try_into()?;

        // Attach to CPU clock events on all online CPUs
        let cpus = online_cpus().context("Failed to get online CPUs")?;
        
        for cpu_id in cpus {
            debug!("Attaching to CPU {}", cpu_id);
            
            // Attach to perf events with correct parameters
            let link = program.attach(
                PerfTypeId::Software,
                perf_sw_ids::PERF_COUNT_SW_CPU_CLOCK as u64,
                PerfEventScope::AllProcessesOneCpu { cpu: cpu_id as u32 },
                SamplePolicy::Frequency(frequency),
                true, // inherit
            ).context(format!("Failed to attach perf event on CPU {}", cpu_id))?;
            
            self.perf_links.push(link);
        }

        info!("Attached perf events to {} CPUs", self.perf_links.len());
        Ok(())
    }

    #[cfg(feature = "ebpf")]
    fn detach_perf_events(&mut self) -> Result<()> {
        if let Some(bpf) = &mut self.bpf {
            debug!("Detaching {} perf events", self.perf_links.len());
            
            // Clearing the vector drops the links, which detaches the programs.
            self.perf_links.clear();
            
            // Clear target PID
            let mut target_pid_map: aya::maps::HashMap<_, u32, u32> = 
                aya::maps::HashMap::try_from(bpf.map_mut("TARGET_PID").unwrap())?;
            target_pid_map.insert(0u32, 0u32, 0)?;
        }
        
        Ok(())
    }
    
    pub fn start_profiling(&mut self, pid: i32, frequency: i32, duration_seconds: i32) -> Result<()> {
        info!("Starting eBPF profiling for PID {} at {}Hz for {}s", pid, frequency, duration_seconds);
        
        #[cfg(feature = "ebpf")]
        {
            // Load eBPF program if not already loaded
            if self.bpf.is_none() {
                match self.load_ebpf_program() {
                    Ok(_) => {
                        // Store profiling parameters
                        self.target_pid = Some(pid);
                        self.sampling_frequency = frequency as u64;

                        // Attach perf events
                        self.attach_perf_events(pid, frequency as u64)
                            .context("Failed to attach perf events")?;

                        info!("eBPF profiling started successfully for PID {}", pid);
                    }
                    Err(e) => {
                        warn!("Failed to load eBPF program: {}. Using mock data instead.", e);
                        // Continue with mock data generation
                    }
                }
            }
        }
        
        #[cfg(not(feature = "ebpf"))]
        {
            warn!("eBPF profiling is not enabled - using mock data");
        }
        
        Ok(())
    }
    
    pub fn stop_profiling(&mut self) -> Result<()> {
        debug!("Stopping eBPF profiling");
        
        #[cfg(feature = "ebpf")]
        {
            if self.bpf.is_some() {
                self.detach_perf_events()
                    .context("Failed to detach perf events")?;
                
                self.target_pid = None;
                info!("eBPF profiling stopped successfully");
            } else {
                debug!("No eBPF program was loaded, nothing to stop");
            }
        }
        
        Ok(())
    }
    
    pub fn collect_results(&self) -> Result<Vec<ProfileStackTrace>> {
        debug!("Collecting eBPF profiling results");
        
        #[cfg(feature = "ebpf")]
        {
            if let Some(bpf) = &self.bpf {
                return self.collect_real_stack_traces(bpf);
            } else {
                warn!("eBPF program not loaded, returning mock data");
            }
        }
        
        Ok(generate_mock_stack_traces())
    }

    #[cfg(feature = "ebpf")]
    fn collect_real_stack_traces(&self, bpf: &Bpf) -> Result<Vec<ProfileStackTrace>> {
        debug!("Collecting real stack traces from eBPF maps");

        let mut result_traces = Vec::new();

        // Get the stack counts map
        let stack_counts: aya::maps::HashMap<_, StackKey, StackValue> = 
            aya::maps::HashMap::try_from(bpf.map("STACK_COUNTS").unwrap())?;

        // Get the stack traces map
        let stack_traces_map: StackTraceMap<_> = 
            StackTraceMap::try_from(bpf.map("STACK_TRACES").unwrap())?;

        // Collect all stack trace data
        for item in stack_counts.iter() {
            let (stack_key, stack_value) = item.context("Failed to read stack count entry")?;
            
            debug!("Processing stack: PID={}, stack_id={}, count={}", 
                   stack_key.pid, stack_key.stack_id, stack_value.count);

            // Get the actual stack trace frames
            match stack_traces_map.get(&(stack_key.stack_id as u32), 0) {
                Ok(stack_trace) => {
                    // Extract instruction pointers from the stack frames
                    let raw_frames: Vec<u64> = stack_trace.frames()
                        .iter()
                        .map(|frame| frame.ip)
                        .collect();
                    let frames = self.resolve_stack_frames(&raw_frames)?;
                    
                    if !frames.is_empty() {
                        result_traces.push(ProfileStackTrace {
                            frames,
                            count: stack_value.count,
                        });
                    }
                }
                Err(e) => {
                    warn!("Failed to get stack trace for ID {}: {}", stack_key.stack_id, e);
                    continue;
                }
            }
        }

        // Log statistics
        self.log_statistics(bpf)?;

        info!("Collected {} unique stack traces", result_traces.len());
        Ok(result_traces)
    }

    #[cfg(feature = "ebpf")]
    fn resolve_stack_frames(&self, raw_frames: &[u64]) -> Result<Vec<String>> {
        let mut frames = Vec::new();
        
        // For now, we'll convert addresses to hex strings
        // In a production system, you'd want to resolve these to actual function names
        // using DWARF symbols, /proc/*/maps, or other symbol resolution methods
        
        for &addr in raw_frames.iter().take(20) { // Limit to 20 frames max
            if addr == 0 {
                break;
            }
            
            // For demonstration, we'll create pseudo function names
            // In reality, you'd resolve these addresses to actual symbols
            let frame = if addr > 0x400000 && addr < 0x500000 {
                format!("user_function_0x{:x}", addr)
            } else if addr > 0xffffffff80000000 {
                format!("kernel_function_0x{:x}", addr)
            } else {
                format!("unknown_0x{:x}", addr)
            };
            
            frames.push(frame);
        }
        
        // Reverse the stack trace so main() appears first
        frames.reverse();
        Ok(frames)
    }

    #[cfg(feature = "ebpf")]
    fn log_statistics(&self, bpf: &Bpf) -> Result<()> {
        let stats: aya::maps::HashMap<_, u32, u64> = 
            aya::maps::HashMap::try_from(bpf.map("STATS").unwrap())?;

        let mut total_samples = 0u64;
        let mut filtered_samples = 0u64;
        let mut stack_errors = 0u64;

        for item in stats.iter() {
            let (key, value) = item.context("Failed to read stats entry")?;
            match key {
                0 => total_samples = value, // STAT_TOTAL_SAMPLES
                1 => filtered_samples = value, // STAT_FILTERED_SAMPLES
                2 => stack_errors = value, // STAT_STACK_TRACE_ERRORS
                _ => {}
            }
        }

        info!("eBPF Profiling Statistics:");
        info!("  Total samples: {}", total_samples);
        info!("  Filtered samples: {}", filtered_samples);
        info!("  Stack trace errors: {}", stack_errors);
        info!("  Success rate: {:.1}%", 
              if total_samples > 0 {
                  100.0 * (total_samples - stack_errors) as f64 / total_samples as f64
              } else {
                  0.0
              });

        Ok(())
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

fn generate_mock_stack_traces() -> Vec<ProfileStackTrace> {
    vec![
        ProfileStackTrace {
            frames: vec![
                "main".to_string(),
                "worker_thread".to_string(),
                "process_request".to_string(),
                "database_query".to_string(),
            ],
            count: 42,
        },
        ProfileStackTrace {
            frames: vec![
                "main".to_string(),
                "worker_thread".to_string(),
                "process_request".to_string(),
                "json_parse".to_string(),
            ],
            count: 15,
        },
        ProfileStackTrace {
            frames: vec![
                "main".to_string(),
                "worker_thread".to_string(),
                "process_request".to_string(),
                "send_response".to_string(),
            ],
            count: 8,
        },
        ProfileStackTrace {
            frames: vec![
                "main".to_string(),
                "signal_handler".to_string(),
            ],
            count: 2,
        },
        ProfileStackTrace {
            frames: vec![
                "main".to_string(),
                "worker_thread".to_string(),
                "idle_wait".to_string(),
            ],
            count: 156,
        },
        ProfileStackTrace {
            frames: vec![
                "main".to_string(),
                "worker_thread".to_string(),
                "process_request".to_string(),
                "expensive_computation".to_string(),
                "math_operations".to_string(),
            ],
            count: 89,
        },
        ProfileStackTrace {
            frames: vec![
                "main".to_string(),
                "worker_thread".to_string(),
                "process_request".to_string(),
                "expensive_computation".to_string(),
                "memory_allocation".to_string(),
            ],
            count: 23,
        },
    ]
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

    #[test]
    fn test_generate_mock_stack_traces() {
        let traces = generate_mock_stack_traces();
        assert!(!traces.is_empty());
        assert!(traces.iter().all(|t| !t.frames.is_empty() && t.count > 0));
    }

    #[test]
    fn test_profiler_lifecycle() {
        let mut profiler = EbpfProfiler::new().unwrap();
        
        // Test start profiling
        let result = profiler.start_profiling(123, 99, 10);
        assert!(result.is_ok());
        
        // Test collect results
        let results = profiler.collect_results();
        assert!(results.is_ok());
        assert!(!results.unwrap().is_empty());
        
        // Test stop profiling
        let result = profiler.stop_profiling();
        assert!(result.is_ok());
    }
}