use crate::ebpf_profiler::ProfileStackTrace;
use crate::tui::{App, AppResult, handle_key_events, render};
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event as CrosstermEvent, KeyEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    Terminal,
};
use std::io;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// Main entry point for the enhanced TUI flamegraph viewer
pub fn run_enhanced_tui(stack_traces: Vec<ProfileStackTrace>, pid: i32, duration: i32) -> AppResult<()> {
    // Create application
    let mut app = App::with_stack_traces(stack_traces, pid, duration);

    // Initialize the terminal user interface
    let backend = CrosstermBackend::new(io::stderr());
    let terminal = Terminal::new(backend)?;
    let mut tui = Tui::new(terminal);
    tui.init()?;

    // Start the main loop
    while app.running {
        // Render the user interface
        tui.draw(&mut app)?;
        
        // Handle events
        match tui.next_event()? {
            TuiEvent::Tick => app.tick(),
            TuiEvent::Key(key_event) => {
                if key_event.kind == KeyEventKind::Press {
                    handle_key_events(key_event, &mut app)?;
                }
            }
            TuiEvent::Mouse(_) => {}
            TuiEvent::Resize(_, _) => {}
        }
    }

    // Exit the user interface
    tui.exit()?;
    Ok(())
}

/// Run TUI in live profiling mode
pub fn run_live_tui(pid: i32) -> AppResult<()> {
    // Create application for live profiling
    let mut app = App::with_live_profiling(pid);

    // Start background profiling thread
    start_live_profiling_thread(pid, app.get_next_flamegraph_ref())?;

    // Initialize the terminal user interface  
    let backend = CrosstermBackend::new(io::stderr());
    let terminal = Terminal::new(backend)?;
    let mut tui = Tui::new(terminal);
    tui.init()?;

    // Start the main loop
    while app.running {
        // Render the user interface
        tui.draw(&mut app)?;
        
        // Handle events
        match tui.next_event()? {
            TuiEvent::Tick => app.tick(),
            TuiEvent::Key(key_event) => {
                if key_event.kind == KeyEventKind::Press {
                    handle_key_events(key_event, &mut app)?;
                }
            }
            TuiEvent::Mouse(_) => {}
            TuiEvent::Resize(_, _) => {}
        }
    }

    // Exit the user interface
    tui.exit()?;
    Ok(())
}

fn start_live_profiling_thread(
    _pid: i32,
    next_flamegraph: Arc<Mutex<Option<crate::tui::app::ParsedFlameGraph>>>,
) -> AppResult<()> {
    thread::spawn(move || {
        // TODO: Import the actual eBPF profiler functions
        loop {
            // Run profiling for 2 seconds
            let tic = std::time::Instant::now();
            
            // This is where we would call the actual eBPF profiler
            // For now, we'll create dummy data
            let stack_traces = vec![
                ProfileStackTrace {
                    frames: vec![
                        "main".to_string(),
                        "worker_loop".to_string(),
                        "process_request".to_string(),
                    ],
                    count: 42,
                },
                ProfileStackTrace {
                    frames: vec![
                        "main".to_string(),
                        "idle_wait".to_string(),
                    ],
                    count: 18,
                },
            ];
            
            let flamegraph = crate::tui::flame::FlameGraph::from_stack_traces(stack_traces);
            let parsed = crate::tui::app::ParsedFlameGraph {
                flamegraph,
                elapsed: tic.elapsed(),
            };
            
            // Update shared flamegraph
            *next_flamegraph.lock().unwrap() = Some(parsed);
            
            // Wait before next profiling session
            thread::sleep(Duration::from_secs(2));
        }
    });
    
    Ok(())
}

/// Terminal user interface wrapper
pub struct Tui {
    terminal: Terminal<CrosstermBackend<io::Stderr>>,
    tick_rate: Duration,
}

impl Tui {
    pub fn new(terminal: Terminal<CrosstermBackend<io::Stderr>>) -> Self {
        Self {
            terminal,
            tick_rate: Duration::from_millis(250),
        }
    }

    pub fn init(&mut self) -> AppResult<()> {
        enable_raw_mode()?;
        execute!(io::stderr(), EnterAlternateScreen, EnableMouseCapture)?;
        self.terminal.hide_cursor()?;
        self.terminal.clear()?;
        Ok(())
    }

    pub fn draw(&mut self, app: &mut App) -> AppResult<()> {
        self.terminal.draw(|frame| render(app, frame))?;
        Ok(())
    }

    pub fn next_event(&self) -> AppResult<TuiEvent> {
        if event::poll(self.tick_rate)? {
            match event::read()? {
                CrosstermEvent::Key(key) => Ok(TuiEvent::Key(key)),
                CrosstermEvent::Mouse(mouse) => Ok(TuiEvent::Mouse(mouse)),
                CrosstermEvent::Resize(w, h) => Ok(TuiEvent::Resize(w, h)),
                CrosstermEvent::FocusGained => Ok(TuiEvent::Tick),
                CrosstermEvent::FocusLost => Ok(TuiEvent::Tick),
                CrosstermEvent::Paste(_) => Ok(TuiEvent::Tick),
            }
        } else {
            Ok(TuiEvent::Tick)
        }
    }

    pub fn exit(&mut self) -> AppResult<()> {
        disable_raw_mode()?;
        execute!(
            self.terminal.backend_mut(),
            LeaveAlternateScreen,
            DisableMouseCapture
        )?;
        self.terminal.show_cursor()?;
        Ok(())
    }
}

/// Custom event type
#[derive(Clone, Debug)]
pub enum TuiEvent {
    Tick,
    Key(crossterm::event::KeyEvent),
    Mouse(crossterm::event::MouseEvent),
    Resize(u16, u16),
}
