use tonic::{Request, Response, Status};
use log::{debug, info, error, warn};
use std::sync::Arc;
use tokio::sync::RwLock;
use dashmap::DashMap;
use uuid::Uuid;

pub mod cli;
pub mod config;
pub mod server;
pub mod setup;
pub mod ebpf_profiler;
pub mod flame_graph;

// Generated protobuf code
pub mod profiler {
    tonic::include_proto!("profiler");
}

use profiler::profiler_service_server::ProfilerService;
use profiler::{
    StartProfilingRequest, StartProfilingResponse,
    GetProfilingResultsRequest, ProfilingResultsChunk,
    GetStatusRequest, GetStatusResponse,
};

// Session management
#[derive(Debug, Clone)]
pub struct ProfilingSession {
    pub session_id: String,
    pub process_id: i32,
    pub duration_seconds: i32,
    pub frequency: i32,
    pub start_time: std::time::SystemTime,
    pub status: SessionStatus,
    pub results: Option<Vec<u8>>,
}

#[derive(Debug, Clone)]
pub enum SessionStatus {
    Starting,
    Running,
    Completed,
    Failed(String),
}

#[derive(Clone)]
pub struct ServiceRadarProfiler {
    sessions: Arc<DashMap<String, ProfilingSession>>,
    active_count: Arc<RwLock<i32>>,
}

impl ServiceRadarProfiler {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(DashMap::new()),
            active_count: Arc::new(RwLock::new(0)),
        }
    }

    async fn increment_active_sessions(&self) {
        let mut count = self.active_count.write().await;
        *count += 1;
    }

    async fn decrement_active_sessions(&self) {
        let mut count = self.active_count.write().await;
        if *count > 0 {
            *count -= 1;
        }
    }

    async fn get_active_sessions(&self) -> i32 {
        *self.active_count.read().await
    }
}

impl std::fmt::Debug for ServiceRadarProfiler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ServiceRadarProfiler")
            .field("sessions_count", &self.sessions.len())
            .finish()
    }
}

#[tonic::async_trait]
impl ProfilerService for ServiceRadarProfiler {
    async fn start_profiling(
        &self,
        request: Request<StartProfilingRequest>,
    ) -> Result<Response<StartProfilingResponse>, Status> {
        let req = request.into_inner();
        
        info!(
            "Received profiling request for PID {}, duration {}s, frequency {}Hz",
            req.process_id, req.duration_seconds, req.frequency
        );

        // Validate request parameters
        if req.process_id <= 0 {
            warn!("Invalid process ID: {}", req.process_id);
            return Ok(Response::new(StartProfilingResponse {
                success: false,
                message: "Invalid process ID".to_string(),
                session_id: String::new(),
            }));
        }

        if req.duration_seconds <= 0 || req.duration_seconds > 300 {
            warn!("Invalid duration: {}s (must be 1-300)", req.duration_seconds);
            return Ok(Response::new(StartProfilingResponse {
                success: false,
                message: "Duration must be between 1 and 300 seconds".to_string(),
                session_id: String::new(),
            }));
        }

        if req.frequency <= 0 || req.frequency > 1000 {
            warn!("Invalid frequency: {}Hz (must be 1-1000)", req.frequency);
            return Ok(Response::new(StartProfilingResponse {
                success: false,
                message: "Frequency must be between 1 and 1000 Hz".to_string(),
                session_id: String::new(),
            }));
        }

        // Check if process exists
        if !process_exists(req.process_id) {
            warn!("Process {} does not exist", req.process_id);
            return Ok(Response::new(StartProfilingResponse {
                success: false,
                message: format!("Process {} not found", req.process_id),
                session_id: String::new(),
            }));
        }

        let session_id = Uuid::new_v4().to_string();
        let session = ProfilingSession {
            session_id: session_id.clone(),
            process_id: req.process_id,
            duration_seconds: req.duration_seconds,
            frequency: req.frequency,
            start_time: std::time::SystemTime::now(),
            status: SessionStatus::Starting,
            results: None,
        };

        self.sessions.insert(session_id.clone(), session.clone());
        self.increment_active_sessions().await;

        // Start profiling in background
        let profiler = self.clone();
        let session_id_clone = session_id.clone();
        tokio::spawn(async move {
            profiler.run_profiling_session(session_id_clone).await;
        });

        info!("Started profiling session {} for PID {}", session_id, req.process_id);
        
        Ok(Response::new(StartProfilingResponse {
            success: true,
            message: format!("Profiling started for PID {}", req.process_id),
            session_id,
        }))
    }

    type GetProfilingResultsStream = tokio_stream::wrappers::ReceiverStream<Result<ProfilingResultsChunk, Status>>;

    async fn get_profiling_results(
        &self,
        request: Request<GetProfilingResultsRequest>,
    ) -> Result<Response<Self::GetProfilingResultsStream>, Status> {
        let req = request.into_inner();
        
        debug!("Received results request for session {}", req.session_id);

        let session = match self.sessions.get(&req.session_id) {
            Some(session) => session.clone(),
            None => {
                warn!("Session {} not found", req.session_id);
                return Err(Status::not_found(format!("Session {} not found", req.session_id)));
            }
        };

        match &session.status {
            SessionStatus::Completed => {
                if let Some(results) = &session.results {
                    info!("Streaming results for session {} ({} bytes)", req.session_id, results.len());
                    
                    // Stream the results in chunks
                    let (tx, rx) = tokio::sync::mpsc::channel(4);
                    let results = results.clone();
                    let session_id = req.session_id.clone();
                    
                    tokio::spawn(async move {
                        let chunk_size = 64 * 1024; // 64KB chunks
                        let total_chunks = (results.len() + chunk_size - 1) / chunk_size;
                        
                        for (i, chunk) in results.chunks(chunk_size).enumerate() {
                            let chunk_msg = ProfilingResultsChunk {
                                data: chunk.to_vec(),
                                is_final: i == total_chunks - 1,
                                chunk_index: i as i32,
                                timestamp: std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_secs() as i64,
                            };
                            
                            if tx.send(Ok(chunk_msg)).await.is_err() {
                                debug!("Client disconnected while streaming results for session {}", session_id);
                                break;
                            }
                        }
                    });

                    Ok(Response::new(tokio_stream::wrappers::ReceiverStream::new(rx)))
                } else {
                    warn!("Session {} completed but has no results", req.session_id);
                    Err(Status::internal("Session completed but no results available"))
                }
            }
            SessionStatus::Failed(error) => {
                warn!("Session {} failed: {}", req.session_id, error);
                Err(Status::internal(format!("Profiling failed: {}", error)))
            }
            SessionStatus::Starting | SessionStatus::Running => {
                info!("Session {} still running, returning empty stream", req.session_id);
                let (tx, rx) = tokio::sync::mpsc::channel(1);
                // Close the channel immediately to return empty stream
                drop(tx);
                Ok(Response::new(tokio_stream::wrappers::ReceiverStream::new(rx)))
            }
        }
    }

    async fn get_status(
        &self,
        _request: Request<GetStatusRequest>,
    ) -> Result<Response<GetStatusResponse>, Status> {
        let active_sessions = self.get_active_sessions().await;
        
        debug!("Status request received, {} active sessions", active_sessions);
        
        Ok(Response::new(GetStatusResponse {
            healthy: true,
            version: env!("CARGO_PKG_VERSION").to_string(),
            active_sessions,
            message: "eBPF Profiler Service is running".to_string(),
        }))
    }
}

impl ServiceRadarProfiler {
    async fn run_profiling_session(&self, session_id: String) {
        debug!("Starting profiling session {}", session_id);
        
        // Update session status to running
        if let Some(mut session) = self.sessions.get_mut(&session_id) {
            session.status = SessionStatus::Running;
        }

        // Get session parameters
        let session = match self.sessions.get(&session_id) {
            Some(session) => session.clone(),
            None => {
                error!("Session {} disappeared during profiling", session_id);
                return;
            }
        };

        // Start actual eBPF profiling
        let results = match self.run_ebpf_profiling(&session).await {
            Ok(data) => data,
            Err(e) => {
                error!("eBPF profiling failed for session {}: {}", session_id, e);
                if let Some(mut session_ref) = self.sessions.get_mut(&session_id) {
                    session_ref.status = SessionStatus::Failed(e.to_string());
                }
                self.decrement_active_sessions().await;
                return;
            }
        };
        
        // Update session with results
        if let Some(mut session_ref) = self.sessions.get_mut(&session_id) {
            session_ref.status = SessionStatus::Completed;
            session_ref.results = Some(mock_results);
        }

        self.decrement_active_sessions().await;
        info!("Completed profiling session {}", session_id);
    }
}

// Helper functions
fn process_exists(pid: i32) -> bool {
    #[cfg(target_os = "linux")]
    {
        std::path::Path::new(&format!("/proc/{}", pid)).exists()
    }
    
    #[cfg(not(target_os = "linux"))]
    {
        // On non-Linux systems, use a different approach
        // For now, we'll assume the process exists if it's a reasonable PID
        // In a real implementation, we'd use platform-specific APIs
        pid > 0 && pid < 100000
    }
}

fn generate_mock_flame_graph_data(pid: i32) -> Vec<u8> {
    // Generate mock folded stack data for flame graph
    let sample_stacks = vec![
        format!("main;worker_thread;process_request;database_query 42"),
        format!("main;worker_thread;process_request;json_parse 15"),
        format!("main;worker_thread;process_request;send_response 8"),
        format!("main;signal_handler 2"),
        format!("main;worker_thread;idle_wait 156"),
        format!("main;worker_thread;process_request;expensive_computation;math_operations 89"),
        format!("main;worker_thread;process_request;expensive_computation;memory_allocation 23"),
    ];

    let mut output = String::new();
    for stack in &sample_stacks {
        output.push_str(stack);
        output.push('\n');
    }

    // Add metadata header
    let metadata = format!(
        "# ServiceRadar eBPF Profiler Results\n# PID: {}\n# Timestamp: {}\n# Total samples: {}\n\n",
        pid,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        sample_stacks.len()
    );

    let mut result = metadata.into_bytes();
    result.extend_from_slice(output.as_bytes());
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use tonic::Request;

    #[tokio::test]
    async fn test_profiler_creation() {
        let profiler = ServiceRadarProfiler::new();
        assert_eq!(profiler.sessions.len(), 0);
        assert_eq!(profiler.get_active_sessions().await, 0);
    }

    #[tokio::test]
    async fn test_get_status() {
        let profiler = ServiceRadarProfiler::new();
        let request = Request::new(GetStatusRequest {});
        
        let response = profiler.get_status(request).await;
        assert!(response.is_ok());
        
        let status = response.unwrap().into_inner();
        assert!(status.healthy);
        assert_eq!(status.active_sessions, 0);
        assert!(!status.version.is_empty());
    }

    #[tokio::test]
    async fn test_start_profiling_invalid_pid() {
        let profiler = ServiceRadarProfiler::new();
        let request = Request::new(StartProfilingRequest {
            process_id: -1,
            duration_seconds: 10,
            frequency: 99,
        });
        
        let response = profiler.start_profiling(request).await;
        assert!(response.is_ok());
        
        let start_response = response.unwrap().into_inner();
        assert!(!start_response.success);
        assert!(start_response.message.contains("Invalid process ID"));
    }

    #[tokio::test]
    async fn test_start_profiling_invalid_duration() {
        let profiler = ServiceRadarProfiler::new();
        let request = Request::new(StartProfilingRequest {
            process_id: 1,
            duration_seconds: 0,
            frequency: 99,
        });
        
        let response = profiler.start_profiling(request).await;
        assert!(response.is_ok());
        
        let start_response = response.unwrap().into_inner();
        assert!(!start_response.success);
        assert!(start_response.message.contains("Duration must be"));
    }

    #[tokio::test]
    async fn test_get_results_nonexistent_session() {
        let profiler = ServiceRadarProfiler::new();
        let request = Request::new(GetProfilingResultsRequest {
            session_id: "nonexistent".to_string(),
        });
        
        let response = profiler.get_profiling_results(request).await;
        assert!(response.is_err());
    }

    #[test]
    fn test_process_exists() {
        // Test with current process (should always exist)
        assert!(process_exists(std::process::id() as i32));
        
        // Very high PID unlikely to exist
        assert!(!process_exists(999999));
    }

    #[test]
    fn test_generate_mock_flame_graph_data() {
        let data = generate_mock_flame_graph_data(123);
        let data_str = String::from_utf8(data).unwrap();
        
        assert!(data_str.contains("# PID: 123"));
        assert!(data_str.contains("main;worker_thread"));
        assert!(data_str.contains("# Total samples:"));
    }
}