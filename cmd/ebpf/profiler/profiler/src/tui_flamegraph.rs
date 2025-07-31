// TUI-based interactive flamegraph viewer using ratatui

use anyhow::Result;
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph},
    Frame, Terminal,
};
use std::collections::HashMap;
use std::io;

use crate::ebpf_profiler::ProfileStackTrace;

#[derive(Debug, Clone)]
struct FlameNode {
    _name: String,
    self_samples: u64,
    total_samples: u64,
    children: HashMap<String, FlameNode>,
    _parent: Option<String>,
}

impl FlameNode {
    fn new(name: String) -> Self {
        Self {
            _name: name,
            self_samples: 0,
            total_samples: 0,
            children: HashMap::new(),
            _parent: None,
        }
    }

    fn add_sample(&mut self, count: u64) {
        self.self_samples += count;
        self.total_samples += count;
    }

    fn add_child_sample(&mut self, count: u64) {
        self.total_samples += count;
    }
}

pub struct FlameGraphTUI {
    flame_tree: FlameNode,
    current_path: Vec<String>,
    selected_index: usize,
    total_samples: u64,
    pid: i32,
    duration: i32,
}

impl FlameGraphTUI {
    pub fn new(stack_traces: Vec<ProfileStackTrace>, pid: i32, duration: i32) -> Self {
        let mut flame_tree = FlameNode::new("root".to_string());
        let total_samples = stack_traces.iter().map(|t| t.count).sum();

        // Build the flame graph tree structure
        for stack_trace in stack_traces {
            let mut current_node = &mut flame_tree;
            
            // Walk down the stack (reverse order for flame graph)
            for frame in stack_trace.frames.iter().rev() {
                if !current_node.children.contains_key(frame) {
                    current_node.children.insert(frame.clone(), FlameNode::new(frame.clone()));
                }
                
                // Add samples to the path from root to this node
                current_node.add_child_sample(stack_trace.count);
                current_node = current_node.children.get_mut(frame).unwrap();
            }
            
            // Add samples to the leaf node
            current_node.add_sample(stack_trace.count);
        }

        Self {
            flame_tree,
            current_path: vec!["root".to_string()],
            selected_index: 0,
            total_samples,
            pid,
            duration,
        }
    }

    pub fn run(&mut self) -> Result<()> {
        // Setup terminal
        enable_raw_mode()?;
        let mut stdout = io::stdout();
        execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
        let backend = CrosstermBackend::new(stdout);
        let mut terminal = Terminal::new(backend)?;

        let result = self.run_app(&mut terminal);

        // Restore terminal
        disable_raw_mode()?;
        execute!(
            terminal.backend_mut(),
            LeaveAlternateScreen,
            DisableMouseCapture
        )?;
        terminal.show_cursor()?;

        result
    }

    fn run_app(&mut self, terminal: &mut Terminal<CrosstermBackend<io::Stdout>>) -> Result<()> {
        let mut list_state = ListState::default();
        list_state.select(Some(0));

        loop {
            terminal.draw(|f| self.ui(f, &mut list_state))?;

            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    match key.code {
                        KeyCode::Char('q') => return Ok(()),
                        KeyCode::Down => {
                            let current_node = self.get_current_node();
                            let children_count = current_node.children.len();
                            if children_count > 0 {
                                self.selected_index = (self.selected_index + 1) % children_count;
                                list_state.select(Some(self.selected_index));
                            }
                        }
                        KeyCode::Up => {
                            let current_node = self.get_current_node();
                            let children_count = current_node.children.len();
                            if children_count > 0 {
                                self.selected_index = if self.selected_index == 0 {
                                    children_count - 1
                                } else {
                                    self.selected_index - 1
                                };
                                list_state.select(Some(self.selected_index));
                            }
                        }
                        KeyCode::Enter | KeyCode::Right => {
                            let current_node = self.get_current_node();
                            let children: Vec<_> = current_node.children.keys().collect();
                            if !children.is_empty() && self.selected_index < children.len() {
                                let selected_child = children[self.selected_index].clone();
                                self.current_path.push(selected_child);
                                self.selected_index = 0;
                                list_state.select(Some(0));
                            }
                        }
                        KeyCode::Left | KeyCode::Backspace => {
                            if self.current_path.len() > 1 {
                                self.current_path.pop();
                                self.selected_index = 0;
                                list_state.select(Some(0));
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    }

    fn get_current_node(&self) -> &FlameNode {
        let mut current = &self.flame_tree;
        for path_element in self.current_path.iter().skip(1) {
            current = current.children.get(path_element).unwrap();
        }
        current
    }

    fn ui(&mut self, f: &mut Frame, list_state: &mut ListState) {
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // Header
                Constraint::Min(0),    // Main content
                Constraint::Length(4), // Footer
            ])
            .split(f.area());

        // Header
        let header = Paragraph::new(vec![
            Line::from(vec![
                Span::styled("Flame Graph Viewer", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
                Span::raw(format!(" - PID: {} | Duration: {}s | Total Samples: {}", 
                    self.pid, self.duration, self.total_samples)),
            ]),
            Line::from(format!("Path: {}", self.current_path.join(" → "))),
        ])
        .block(Block::default().borders(Borders::ALL).title("Profile Info"));
        f.render_widget(header, chunks[0]);

        // Main content - function list
        let current_node = self.get_current_node();
        let mut children: Vec<_> = current_node.children.iter().collect();
        children.sort_by(|a, b| b.1.total_samples.cmp(&a.1.total_samples));

        let items: Vec<ListItem> = children
            .iter()
            .map(|(name, node)| {
                let percentage = (node.total_samples as f64 / self.total_samples as f64) * 100.0;
                let self_percentage = (node.self_samples as f64 / self.total_samples as f64) * 100.0;
                
                let content = if node.self_samples > 0 {
                    format!(
                        "{:<50} {:>8} ({:>5.1}%) self: {} ({:.1}%)",
                        name,
                        node.total_samples,
                        percentage,
                        node.self_samples,
                        self_percentage
                    )
                } else {
                    format!(
                        "{:<50} {:>8} ({:>5.1}%)",
                        name,
                        node.total_samples,
                        percentage
                    )
                };
                
                let style = if percentage > 10.0 {
                    Style::default().fg(Color::Red)
                } else if percentage > 5.0 {
                    Style::default().fg(Color::Yellow)
                } else {
                    Style::default().fg(Color::Green)
                };
                
                ListItem::new(content).style(style)
            })
            .collect();

        let list = List::new(items)
            .block(Block::default().borders(Borders::ALL).title("Functions"))
            .highlight_style(Style::default().bg(Color::DarkGray).add_modifier(Modifier::BOLD))
            .highlight_symbol("► ");

        f.render_stateful_widget(list, chunks[1], list_state);

        // Footer with controls
        let footer = Paragraph::new(vec![
            Line::from("Controls:"),
            Line::from("↑/↓: Navigate | Enter/→: Drill Down | ←/Backspace: Go Back | q: Quit"),
        ])
        .block(Block::default().borders(Borders::ALL).title("Help"));
        f.render_widget(footer, chunks[2]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
            StackTrace {
                frames: vec!["main".to_string(), "other".to_string()],
                count: 5,
            },
        ]
    }

    #[test]
    fn test_flamegraph_tree_building() {
        let stack_traces = create_test_stack_traces();
        let tui = FlameGraphTUI::new(stack_traces, 123, 30);
        
        assert_eq!(tui.total_samples, 35);
        assert_eq!(tui.flame_tree.total_samples, 35);
        assert_eq!(tui.flame_tree.children.len(), 1); // Should have "main" as only child
        
        let main_node = tui.flame_tree.children.get("main").unwrap();
        assert_eq!(main_node.total_samples, 35);
        assert_eq!(main_node.children.len(), 2); // "foo" and "other"
    }
}