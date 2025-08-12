use crate::ebpf_profiler::ProfileStackTrace;
use crate::tui::flame::FlameGraph;
use crate::tui::view::FlameGraphView;
use std::collections::HashMap;
use std::error;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Application result type.
pub type AppResult<T> = std::result::Result<T, Box<dyn error::Error + Send + Sync>>;

#[derive(Debug)]
pub enum ProfilerInput {
    Static(i32, i32), // pid, duration for static profiling
    Live(i32),        // pid for live profiling
}

#[derive(Debug)]
pub struct ParsedFlameGraph {
    pub flamegraph: FlameGraph,
    pub elapsed: Duration,
}

#[derive(Debug)]
pub struct InputBuffer {
    pub buffer: String,
    pub cursor: Option<(u16, u16)>,
}

/// Application state
#[derive(Debug)]
pub struct App {
    /// Is the application running?
    pub running: bool,
    /// Flamegraph view
    pub flamegraph_view: FlameGraphView,
    /// Profiler input information
    pub profiler_input: ProfilerInput,
    /// User input buffer for search
    pub input_buffer: Option<InputBuffer>,
    /// Timing information for debugging
    pub elapsed: HashMap<String, Duration>,
    /// Transient message to show user
    pub transient_message: Option<String>,
    /// Debug mode
    pub debug: bool,
    /// Next flamegraph to swap in (for live mode)
    next_flamegraph: Arc<Mutex<Option<ParsedFlameGraph>>>,
    /// Live profiling state
    pub live_mode: bool,
    pub freeze: bool,
}

impl App {
    /// Create a new app with static flamegraph data
    pub fn with_stack_traces(stack_traces: Vec<ProfileStackTrace>, pid: i32, duration: i32) -> Self {
        let flamegraph = FlameGraph::from_stack_traces(stack_traces);
        Self {
            running: true,
            flamegraph_view: FlameGraphView::new(flamegraph),
            profiler_input: ProfilerInput::Static(pid, duration),
            input_buffer: None,
            elapsed: HashMap::new(),
            transient_message: None,
            debug: false,
            next_flamegraph: Arc::new(Mutex::new(None)),
            live_mode: false,
            freeze: false,
        }
    }

    /// Create a new app for live profiling
    pub fn with_live_profiling(pid: i32) -> Self {
        let flamegraph = FlameGraph::empty();
        Self {
            running: true,
            flamegraph_view: FlameGraphView::new(flamegraph),
            profiler_input: ProfilerInput::Live(pid),
            input_buffer: None,
            elapsed: HashMap::new(),
            transient_message: None,
            debug: false,
            next_flamegraph: Arc::new(Mutex::new(None)),
            live_mode: true,
            freeze: false,
        }
    }

    /// Get a reference to the next flamegraph Arc for the collector thread
    pub fn get_next_flamegraph_ref(&self) -> Arc<Mutex<Option<ParsedFlameGraph>>> {
        self.next_flamegraph.clone()
    }

    /// Handles the tick event of the terminal
    pub fn tick(&mut self) {
        // Replace flamegraph if not frozen and new data is available
        if self.live_mode && !self.freeze {
            if let Some(parsed) = self.next_flamegraph.lock().unwrap().take() {
                self.elapsed
                    .insert("flamegraph".to_string(), parsed.elapsed);
                let tic = std::time::Instant::now();
                self.flamegraph_view.replace_flamegraph(parsed.flamegraph);
                self.elapsed
                    .insert("replacement".to_string(), tic.elapsed());
            }
        }
    }

    /// Set running to false to quit the application
    pub fn quit(&mut self) {
        self.running = false;
    }

    /// Get reference to the flamegraph
    pub fn flamegraph(&self) -> &FlameGraph {
        &self.flamegraph_view.flamegraph
    }

    /// Add elapsed timing information
    pub fn add_elapsed(&mut self, name: &str, elapsed: Duration) {
        self.elapsed.insert(name.to_string(), elapsed);
    }

    /// Search for the currently selected stack
    pub fn search_selected(&mut self) {
        if self.flamegraph_view.is_root_selected() {
            return;
        }
        if let Some(stack) = self.flamegraph_view.get_selected_stack() {
            let stack_id = stack.id;
            // Get the short name before borrowing mutably
            let short_name = self.flamegraph().get_stack_short_name(&stack_id).to_string();
            self.set_manual_search_pattern(&short_name, false);
        }
    }

    /// Search for the currently selected row in table view
    pub fn search_selected_row(&mut self) {
        if let Some(name) = self.flamegraph_view.get_selected_row_name() {
            // Clone the name to avoid borrow conflicts
            let name = name.to_string();
            self.set_manual_search_pattern(&name, false);
        }
        self.flamegraph_view.toggle_view_mode();
    }

    /// Set a manual search pattern
    pub fn set_manual_search_pattern(&mut self, pattern: &str, is_regex: bool) {
        match self.flamegraph_view.set_search_pattern(pattern, is_regex) {
            Ok(_) => {}
            Err(_) => {
                self.set_transient_message(&format!("Invalid regex: {}", pattern));
            }
        }
    }

    /// Set a transient message to show the user
    pub fn set_transient_message(&mut self, message: &str) {
        self.transient_message = Some(message.to_string());
    }

    /// Clear the transient message
    pub fn clear_transient_message(&mut self) {
        self.transient_message = None;
    }

    /// Toggle debug mode
    pub fn toggle_debug(&mut self) {
        self.debug = !self.debug;
    }

    /// Toggle freeze mode (for live profiling)
    pub fn toggle_freeze(&mut self) {
        if self.live_mode {
            self.freeze = !self.freeze;
        }
    }

    /// Get the PID being profiled
    pub fn get_pid(&self) -> i32 {
        match &self.profiler_input {
            ProfilerInput::Static(pid, _) => *pid,
            ProfilerInput::Live(pid) => *pid,
        }
    }

    /// Get the duration (for static profiling)
    pub fn get_duration(&self) -> Option<i32> {
        match &self.profiler_input {
            ProfilerInput::Static(_, duration) => Some(*duration),
            ProfilerInput::Live(_) => None,
        }
    }
}