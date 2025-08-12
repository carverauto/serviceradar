// TUI-based interactive flamegraph viewer using ratatui - Enhanced with flamelens architecture

use anyhow::Result;
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseEvent, MouseEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Table, Row},
    Frame, Terminal,
};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::io;
use regex::Regex;

use crate::ebpf_profiler::ProfileStackTrace;

pub type StackIdentifier = usize;
pub static ROOT: &str = "all";
pub static ROOT_ID: usize = 0;

#[derive(Debug, Clone, PartialEq)]
pub struct StackInfo {
    pub id: StackIdentifier,
    pub total_count: u64,
    pub self_count: u64,
    pub parent: Option<StackIdentifier>,
    pub children: Vec<StackIdentifier>,
    pub level: usize,
    pub width_factor: f64,
    pub hit: bool,
    pub name: String,
    pub full_name: String,
}

#[derive(Debug, Clone)]
pub struct SearchPattern {
    pub pattern: String,
    pub regex: Regex,
    pub is_active: bool,
}

impl SearchPattern {
    pub fn new(pattern: &str) -> Result<Self> {
        let regex = if pattern.starts_with("regex:") {
            Regex::new(&pattern[6..])
        } else {
            Regex::new(&regex::escape(pattern))
        };
        
        match regex {
            Ok(re) => Ok(Self {
                pattern: pattern.to_string(),
                regex: re,
                is_active: true,
            }),
            Err(e) => Err(anyhow::anyhow!("Invalid regex pattern: {}", e)),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ZoomState {
    pub stack_id: StackIdentifier,
    pub ancestors: Vec<StackIdentifier>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ViewMode {
    FlameGraph,
    Table,
}

#[derive(Debug, Clone)]
struct FlameRect {
    stack_id: StackIdentifier,
    name: String,
    samples: u64,
    x: u16,
    width: u16,
    y: u16,
    color: Color,
    selected: bool,
}

pub struct FlameGraphTUI {
    stacks: Vec<StackInfo>,
    levels: Vec<Vec<StackIdentifier>>,
    total_samples: u64,
    pid: i32,
    duration: i32,
    viewport_width: u16,
    viewport_height: u16,
    
    // UI State
    selected_stack: StackIdentifier,
    zoom_state: Option<ZoomState>,
    search_pattern: Option<SearchPattern>,
    view_mode: ViewMode,
    level_offset: usize,
    
    // Table state for table view
    table_selected: Option<usize>,
    table_offset: usize,
    
    // Input buffer for search
    input_buffer: Option<String>,
}

impl FlameGraphTUI {
    pub fn new(stack_traces: Vec<ProfileStackTrace>, pid: i32, duration: i32) -> Self {
        let total_samples = stack_traces.iter().map(|t| t.count).sum();
        
        // Initialize with root stack
        let mut stacks = Vec::new();
        stacks.push(StackInfo {
            id: ROOT_ID,
            total_count: 0,
            self_count: 0,
            parent: None,
            children: Vec::new(),
            level: 0,
            width_factor: 1.0,
            hit: false,
            name: ROOT.to_string(),
            full_name: ROOT.to_string(),
        });
        
        // Build the flame graph tree structure
        for stack_trace in &stack_traces {
            Self::process_stack_trace(&mut stacks, stack_trace);
        }
        
        // Calculate total count for root
        stacks[ROOT_ID].total_count = total_samples;
        
        let mut tui = Self {
            stacks,
            levels: Vec::new(),
            total_samples,
            pid,
            duration,
            viewport_width: 120,
            viewport_height: 40,
            selected_stack: ROOT_ID,
            zoom_state: None,
            search_pattern: None,
            view_mode: ViewMode::FlameGraph,
            level_offset: 0,
            table_selected: None,
            table_offset: 0,
            input_buffer: None,
        };
        
        // Populate levels and calculate width factors
        tui.populate_levels();
        tui
    }
    
    fn process_stack_trace(stacks: &mut Vec<StackInfo>, stack_trace: &ProfileStackTrace) {
        let mut parent_id = ROOT_ID;
        let mut level = 1;
        
        // Walk through the stack trace (reverse order for flame graph)
        for frame in stack_trace.frames.iter().rev() {
            let stack_id = Self::find_or_create_stack(stacks, frame, parent_id, level);
            
            // Update counts
            stacks[stack_id].total_count += stack_trace.count;
            if level == stack_trace.frames.len() {
                // This is the leaf node
                stacks[stack_id].self_count += stack_trace.count;
            }
            
            parent_id = stack_id;
            level += 1;
        }
    }
    
    fn find_or_create_stack(
        stacks: &mut Vec<StackInfo>,
        name: &str,
        parent_id: StackIdentifier,
        level: usize,
    ) -> StackIdentifier {
        // Check if this stack already exists as a child of the parent
        let parent = &stacks[parent_id];
        for &child_id in &parent.children {
            if stacks[child_id].name == name {
                return child_id;
            }
        }
        
        // Create new stack
        let stack_id = stacks.len();
        stacks.push(StackInfo {
            id: stack_id,
            total_count: 0,
            self_count: 0,
            parent: Some(parent_id),
            children: Vec::new(),
            level,
            width_factor: 0.0,
            hit: false,
            name: name.to_string(),
            full_name: name.to_string(), // TODO: Build full path
        });
        
        // Add to parent's children
        stacks[parent_id].children.push(stack_id);
        stack_id
    }
    
    fn populate_levels(&mut self) {
        self.levels.clear();
        self.populate_levels_recursive(ROOT_ID, 0, None);
        
        // Sort children by count for better visualization
        // We need to collect the counts first to avoid borrowing conflicts
        let stack_counts: std::collections::HashMap<usize, u64> = self.stacks
            .iter()
            .map(|s| (s.id, s.total_count))
            .collect();
        
        for stack in &mut self.stacks {
            stack.children.sort_by(|&a, &b| {
                let count_a = stack_counts.get(&a).unwrap_or(&0);
                let count_b = stack_counts.get(&b).unwrap_or(&0);
                count_b.cmp(count_a)
            });
        }
    }
    
    fn populate_levels_recursive(
        &mut self,
        stack_id: StackIdentifier,
        level: usize,
        parent_width_factor: Option<f64>,
    ) {
        // Ensure levels vector is large enough
        while self.levels.len() <= level {
            self.levels.push(Vec::new());
        }
        self.levels[level].push(stack_id);
        
        // Calculate width factor
        let width_factor = if let Some(parent_width) = parent_width_factor {
            let parent_count = if let Some(parent_id) = self.stacks[stack_id].parent {
                self.stacks[parent_id].total_count
            } else {
                self.total_samples
            };
            
            if parent_count > 0 {
                parent_width * (self.stacks[stack_id].total_count as f64 / parent_count as f64)
            } else {
                0.0
            }
        } else {
            1.0
        };
        
        self.stacks[stack_id].width_factor = width_factor;
        
        // Process children
        let children = self.stacks[stack_id].children.clone();
        for child_id in children {
            self.populate_levels_recursive(child_id, level + 1, Some(width_factor));
        }
    }

    // Search functionality
    fn set_search_pattern(&mut self, pattern: &str) -> Result<()> {
        if pattern.is_empty() {
            self.clear_search();
            return Ok(());
        }
        
        let search_pattern = SearchPattern::new(pattern)?;
        
        // Mark matching stacks
        for stack in &mut self.stacks {
            stack.hit = search_pattern.regex.is_match(&stack.name);
        }
        
        self.search_pattern = Some(search_pattern);
        Ok(())
    }
    
    fn clear_search(&mut self) {
        for stack in &mut self.stacks {
            stack.hit = false;
        }
        self.search_pattern = None;
    }
    
    // Navigation functions
    fn zoom_to_stack(&mut self, stack_id: StackIdentifier) {
        let ancestors = self.get_ancestors(stack_id);
        self.zoom_state = Some(ZoomState { stack_id, ancestors });
        self.level_offset = self.stacks[stack_id].level;
    }
    
    fn zoom_out(&mut self) {
        if let Some(zoom_state) = &self.zoom_state {
            if let Some(parent_id) = self.stacks[zoom_state.stack_id].parent {
                if parent_id == ROOT_ID {
                    self.zoom_state = None;
                    self.level_offset = 0;
                } else {
                    self.zoom_to_stack(parent_id);
                }
            } else {
                self.zoom_state = None;
                self.level_offset = 0;
            }
        }
    }
    
    fn reset_zoom(&mut self) {
        self.zoom_state = None;
        self.level_offset = 0;
        self.selected_stack = ROOT_ID;
    }
    
    fn get_ancestors(&self, stack_id: StackIdentifier) -> Vec<StackIdentifier> {
        let mut ancestors = Vec::new();
        let mut current_id = stack_id;
        
        while let Some(stack) = self.stacks.get(current_id) {
            ancestors.push(current_id);
            if let Some(parent_id) = stack.parent {
                current_id = parent_id;
            } else {
                break;
            }
        }
        
        ancestors
    }
    
    // Color generation similar to flamelens
    fn get_stack_color(&self, stack: &StackInfo) -> Color {
        if self.selected_stack == stack.id {
            return Color::Rgb(250, 250, 250); // Selected color
        }
        
        // Hash-based color generation like flamelens
        let mut hasher = DefaultHasher::new();
        stack.name.hash(&mut hasher);
        let hash_value = hasher.finish() as f64 / u64::MAX as f64;
        
        let (mut r, mut g, mut b) = if !stack.hit {
            // Normal color scheme
            (
                205 + (50.0 * hash_value) as u8,
                (230.0 * hash_value) as u8,
                (55.0 * hash_value) as u8,
            )
        } else {
            // Highlighted color for search matches
            (10, 35, 150)
        };
        
        // Dim ancestors when zoomed
        if let Some(zoom_state) = &self.zoom_state {
            if zoom_state.ancestors.contains(&stack.id) && stack.id != zoom_state.stack_id {
                r = (r as f64 / 2.5) as u8;
                g = (g as f64 / 2.5) as u8;
                b = (b as f64 / 2.5) as u8;
            }
        }
        
        Color::Rgb(r, g, b)
    }
    
    fn get_text_color(&self, bg_color: Color) -> Color {
        match bg_color {
            Color::Rgb(r, g, b) => {
                let luma = 0.2126 * r as f64 + 0.7152 * g as f64 + 0.0722 * b as f64;
                if luma > 128.0 {
                    Color::Rgb(10, 10, 10)
                } else {
                    Color::Rgb(225, 225, 225)
                }
            }
            _ => Color::Black,
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
        loop {
            // Update viewport size
            let size = terminal.size()?;
            if self.viewport_width != size.width || self.viewport_height != size.height {
                self.viewport_width = size.width;
                self.viewport_height = size.height;
            }
            
            terminal.draw(|f| self.ui(f))?;

            if let Some(input_buffer) = &self.input_buffer {
                // Handle input mode
                match event::read()? {
                    Event::Key(key) if key.kind == KeyEventKind::Press => {
                        match key.code {
                            KeyCode::Enter => {
                                // Execute search
                                let pattern = input_buffer.clone();
                                self.input_buffer = None;
                                if let Err(e) = self.set_search_pattern(&pattern) {
                                    // TODO: Show error message
                                    eprintln!("Search error: {}", e);
                                }
                            }
                            KeyCode::Esc => {
                                // Cancel search
                                self.input_buffer = None;
                            }
                            KeyCode::Backspace => {
                                // Remove character
                                let mut buffer = input_buffer.clone();
                                buffer.pop();
                                self.input_buffer = Some(buffer);
                            }
                            KeyCode::Char(c) => {
                                // Add character
                                let mut buffer = input_buffer.clone();
                                buffer.push(c);
                                self.input_buffer = Some(buffer);
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                }
            } else {
                // Normal navigation mode
                match event::read()? {
                    Event::Key(key) if key.kind == KeyEventKind::Press => {
                        match key.code {
                            KeyCode::Char('q') => return Ok(()),
                            KeyCode::Char('r') => {
                                self.reset_zoom();
                            }
                            KeyCode::Char('/') => {
                                // Start search
                                self.input_buffer = Some(String::new());
                            }
                            KeyCode::Char('c') => {
                                // Clear search
                                self.clear_search();
                            }
                            KeyCode::Tab => {
                                // Switch view mode
                                self.view_mode = match self.view_mode {
                                    ViewMode::FlameGraph => ViewMode::Table,
                                    ViewMode::Table => ViewMode::FlameGraph,
                                };
                            }
                            KeyCode::Left | KeyCode::Backspace => {
                                // Zoom out
                                self.zoom_out();
                            }
                            KeyCode::Right | KeyCode::Enter => {
                                // Zoom into selected stack
                                if self.selected_stack != ROOT_ID {
                                    self.zoom_to_stack(self.selected_stack);
                                }
                            }
                            KeyCode::Up | KeyCode::Char('k') => {
                                // Navigate up
                                self.navigate_up();
                            }
                            KeyCode::Down | KeyCode::Char('j') => {
                                // Navigate down
                                self.navigate_down();
                            }
                            KeyCode::Char('h') => {
                                // Move left in flame graph
                                self.navigate_left();
                            }
                            KeyCode::Char('l') => {
                                // Move right in flame graph
                                self.navigate_right();
                            }
                            _ => {}
                        }
                    }
                    Event::Mouse(MouseEvent { kind: MouseEventKind::Down(_), column, row, .. }) => {
                        self.handle_mouse_click(column, row);
                    }
                    _ => {}
                }
            }
        }
    }
    
    // Navigation methods
    fn navigate_up(&mut self) {
        if self.view_mode == ViewMode::FlameGraph {
            // Move to parent level
            if let Some(parent_id) = self.stacks[self.selected_stack].parent {
                self.selected_stack = parent_id;
            }
        } else {
            // Table navigation
            if let Some(selected) = self.table_selected {
                if selected > 0 {
                    self.table_selected = Some(selected - 1);
                }
            } else {
                self.table_selected = Some(0);
            }
        }
    }
    
    fn navigate_down(&mut self) {
        if self.view_mode == ViewMode::FlameGraph {
            // Move to first child
            let children = &self.stacks[self.selected_stack].children;
            if !children.is_empty() {
                self.selected_stack = children[0];
            }
        } else {
            // Table navigation
            let visible_count = self.get_visible_stack_count();
            if let Some(selected) = self.table_selected {
                if selected + 1 < visible_count {
                    self.table_selected = Some(selected + 1);
                }
            } else if visible_count > 0 {
                self.table_selected = Some(0);
            }
        }
    }
    
    fn navigate_left(&mut self) {
        if self.view_mode == ViewMode::FlameGraph {
            // Move to previous sibling
            if let Some(parent_id) = self.stacks[self.selected_stack].parent {
                let siblings = &self.stacks[parent_id].children;
                if let Some(pos) = siblings.iter().position(|&id| id == self.selected_stack) {
                    if pos > 0 {
                        self.selected_stack = siblings[pos - 1];
                    }
                }
            }
        }
    }
    
    fn navigate_right(&mut self) {
        if self.view_mode == ViewMode::FlameGraph {
            // Move to next sibling
            if let Some(parent_id) = self.stacks[self.selected_stack].parent {
                let siblings = &self.stacks[parent_id].children;
                if let Some(pos) = siblings.iter().position(|&id| id == self.selected_stack) {
                    if pos + 1 < siblings.len() {
                        self.selected_stack = siblings[pos + 1];
                    }
                }
            }
        }
    }
    
    fn get_visible_stack_count(&self) -> usize {
        self.stacks.iter().filter(|stack| {
            if let Some(search) = &self.search_pattern {
                search.is_active && stack.hit
            } else {
                true
            }
        }).count()
    }
    
    fn handle_mouse_click(&mut self, column: u16, row: u16) {
        if self.view_mode == ViewMode::FlameGraph {
            // Find stack at clicked position
            let clicked_stack = self.find_stack_at_position(column, row);
            if let Some(stack_id) = clicked_stack {
                self.selected_stack = stack_id;
            }
        }
    }
    
    fn find_stack_at_position(&self, x: u16, y: u16) -> Option<StackIdentifier> {
        // Calculate which level was clicked
        let header_height = 3; // Account for header
        if y < header_height {
            return None;
        }
        
        let level = (y - header_height) as usize + self.level_offset;
        
        if level >= self.levels.len() {
            return None;
        }
        
        // Find stack at this position within the level
        let mut x_offset = 0.0;
        let viewport_width = self.viewport_width.saturating_sub(2) as f64;
        
        for &stack_id in &self.levels[level] {
            let stack = &self.stacks[stack_id];
            let width = (stack.width_factor * viewport_width) as u16;
            
            if x >= x_offset as u16 && x < (x_offset + width as f64) as u16 {
                return Some(stack_id);
            }
            
            x_offset += width as f64;
        }
        
        None
    }

    fn ui(&mut self, f: &mut Frame) {
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // Header
                Constraint::Min(0),    // Main content
                Constraint::Length(if self.input_buffer.is_some() { 3 } else { 2 }), // Status/Search
                Constraint::Length(2), // Help bar
            ])
            .split(f.area());

        // Header
        self.render_header(f, chunks[0]);

        // Main content (flame graph or table)
        match self.view_mode {
            ViewMode::FlameGraph => self.render_flamegraph(f, chunks[1]),
            ViewMode::Table => self.render_table(f, chunks[1]),
        }

        // Status/Search bar
        self.render_status_bar(f, chunks[2]);

        // Help bar
        self.render_help_bar(f, chunks[3]);
    }
    
    fn render_header(&self, f: &mut Frame, area: Rect) {
        let view_indicator = match self.view_mode {
            ViewMode::FlameGraph => "[Flamegraph]",
            ViewMode::Table => "[Table]",
        };
        
        let zoom_info = if let Some(zoom_state) = &self.zoom_state {
            format!(" | Zoomed: {}", self.stacks[zoom_state.stack_id].name)
        } else {
            String::new()
        };
        
        let header = Paragraph::new(vec![
            Line::from(vec![
                Span::styled("🔥 Enhanced Flame Graph", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
                Span::raw(format!(" | PID: {} | Duration: {}s | Samples: {}", 
                    self.pid, self.duration, self.total_samples)),
                Span::styled(zoom_info, Style::default().fg(Color::Cyan)),
            ]),
            Line::from(format!("{} | flamelens v{}", view_indicator, env!("CARGO_PKG_VERSION"))),
        ])
        .block(Block::default().borders(Borders::ALL).title("ServiceRadar eBPF Profiler"));
        f.render_widget(header, area);
    }
    
    fn render_help_bar(&self, f: &mut Frame, area: Rect) {
        let help_text = if self.input_buffer.is_some() {
            "Search: [Enter] Execute | [Esc] Cancel | [Backspace] Delete"
        } else {
            match self.view_mode {
                ViewMode::FlameGraph => "[hjkl] Navigate | [Enter] Zoom | [Backspace] Zoom Out | [/] Search | [Tab] Table | [r] Reset | [q] Quit",
                ViewMode::Table => "[jk] Navigate | [Tab] Flamegraph | [/] Filter | [q] Quit",
            }
        };
        
        let help = Paragraph::new(help_text)
            .block(Block::default().borders(Borders::TOP))
            .style(Style::default().fg(Color::Gray));
        f.render_widget(help, area);
    }
    
    fn render_status_bar(&self, f: &mut Frame, area: Rect) {
        if let Some(input_buffer) = &self.input_buffer {
            // Search input mode
            let search_text = format!("Search: {}", input_buffer);
            let search_widget = Paragraph::new(search_text)
                .block(Block::default().borders(Borders::ALL).title("Search Pattern"));
            f.render_widget(search_widget, area);
        } else {
            // Status information
            let selected_stack = &self.stacks[self.selected_stack];
            let percentage = if self.total_samples > 0 {
                (selected_stack.total_count as f64 / self.total_samples as f64) * 100.0
            } else {
                0.0
            };
            
            let search_info = if let Some(search) = &self.search_pattern {
                let hit_count = self.stacks.iter().filter(|s| s.hit).count();
                format!(" | Search: '{}' ({} matches)", search.pattern, hit_count)
            } else {
                String::new()
            };
            
            let status_text = format!(
                "Selected: {} | {} samples ({:.1}%) | Level {}{}", 
                selected_stack.name, 
                selected_stack.total_count, 
                percentage, 
                selected_stack.level,
                search_info
            );
            
            let status = Paragraph::new(status_text)
                .block(Block::default().borders(Borders::TOP).title("Status"))
                .style(Style::default().fg(Color::Yellow));
            f.render_widget(status, area);
        }
    }
    
    fn render_flamegraph(&self, f: &mut Frame, area: Rect) {
        if self.stacks.is_empty() {
            let empty = Paragraph::new("No flame data to display")
                .style(Style::default().fg(Color::Gray))
                .block(Block::default().borders(Borders::ALL));
            f.render_widget(empty, area);
            return;
        }
        
        // Generate visual rectangles like the original implementation
        let flame_rects = self.generate_flame_rectangles(area);
        self.render_flame_rectangles(f, area, flame_rects);
    }
    
    fn generate_flame_rectangles(&self, area: Rect) -> Vec<FlameRect> {
        let mut rects = Vec::new();
        
        if area.width <= 2 || self.total_samples == 0 {
            return rects;
        }
        
        let viewport_width = area.width.saturating_sub(2);
        
        // Start from root or zoomed stack
        let start_stack_id = if let Some(zoom_state) = &self.zoom_state {
            zoom_state.stack_id
        } else {
            ROOT_ID
        };
        
        self.generate_rects_recursive(
            start_stack_id,
            0,
            0,
            viewport_width,
            &mut rects,
        );
        
        rects
    }
    
    fn generate_rects_recursive(
        &self,
        stack_id: StackIdentifier,
        x: u16,
        y: u16,
        width: u16,
        rects: &mut Vec<FlameRect>,
    ) {
        if width == 0 {
            return;
        }
        
        let stack = &self.stacks[stack_id];
        
        // Skip root stack from display
        if stack.name != ROOT {
            let bg_color = self.get_stack_color(stack);
            rects.push(FlameRect {
                stack_id,
                name: stack.name.clone(),
                samples: stack.total_count,
                x,
                width,
                y,
                color: bg_color,
                selected: self.selected_stack == stack_id,
            });
        }
        
        // Render children
        if !stack.children.is_empty() {
            let mut child_x = x;
            let child_y = y + if stack.name != ROOT { 1 } else { 0 };
            
            // Check if we're in a zoomed view
            let zoomed_child = if let Some(zoom_state) = &self.zoom_state {
                stack.children.iter().find(|&&child_id| {
                    child_id == zoom_state.stack_id || zoom_state.ancestors.contains(&child_id)
                }).copied()
            } else {
                None
            };
            
            for &child_id in &stack.children {
                let child_stack = &self.stacks[child_id];
                let child_width = if let Some(zoomed_child_id) = zoomed_child {
                    if zoomed_child_id == child_id {
                        width // Zoomed child takes all space
                    } else {
                        0 // Hide other children
                    }
                } else {
                    // Normal proportional width
                    if stack.total_count > 0 {
                        ((child_stack.total_count as f64 / stack.total_count as f64) * width as f64) as u16
                    } else {
                        0
                    }
                };
                
                if child_width > 0 {
                    self.generate_rects_recursive(child_id, child_x, child_y, child_width, rects);
                    child_x += child_width;
                }
            }
        }
    }
    
    fn render_flame_rectangles(&self, f: &mut Frame, area: Rect, flame_rects: Vec<FlameRect>) {
        if flame_rects.is_empty() {
            let empty = Paragraph::new("No flame data to display")
                .style(Style::default().fg(Color::Gray))
                .block(Block::default().borders(Borders::ALL));
            f.render_widget(empty, area);
            return;
        }
        
        // Calculate available space for flame display
        let flame_area = Rect {
            x: area.x + 1,
            y: area.y + 1, 
            width: area.width.saturating_sub(2),
            height: area.height.saturating_sub(2),
        };
        
        // Find the maximum depth to initialize lines
        let max_depth = flame_rects.iter().map(|r| r.y).max().unwrap_or(0) + 1;
        
        // Initialize empty lines
        let mut lines = Vec::new();
        for _ in 0..max_depth {
            lines.push(vec![' '; flame_area.width as usize]);
        }
        
        // Fill in flame rectangles with function names
        for rect in &flame_rects {
            if (rect.y as usize) < lines.len() {
                let line = &mut lines[rect.y as usize];
                let start = rect.x as usize;
                let end = (rect.x + rect.width) as usize;
                
                if start < line.len() {
                    let actual_end = std::cmp::min(end, line.len());
                    let rect_width = actual_end - start;
                    
                    // Function name for display
                    let display_name = if rect.name.len() > rect_width {
                        format!("{}...", &rect.name[0..rect_width.saturating_sub(3)])
                    } else {
                        rect.name.clone()
                    };
                    
                    // Fill background with block character
                    let fill_char = if rect.selected {
                        '█' // Full block for selected
                    } else {
                        '▄' // Lower half block for normal
                    };
                    
                    // Fill the entire rectangle area first
                    for j in start..actual_end {
                        line[j] = fill_char;
                    }
                    
                    // Overlay function name if there's space
                    if rect_width >= 3 && !display_name.is_empty() {
                        let text_start = start + (rect_width.saturating_sub(display_name.len())) / 2;
                        let text_chars: Vec<char> = display_name.chars().collect();
                        
                        for (char_idx, &ch) in text_chars.iter().enumerate() {
                            let pos = text_start + char_idx;
                            if pos < actual_end && pos < line.len() {
                                line[pos] = ch;
                            }
                        }
                    }
                }
            }
        }
        
        // Convert lines to styled spans
        let mut text_lines = Vec::new();
        
        for (depth, line) in lines.iter().enumerate() {
            let mut spans = Vec::new();
            let mut current_span = String::new();
            let mut current_color = Color::White;
            
            for (pos, &ch) in line.iter().enumerate() {
                // Find which rectangle this position belongs to
                let mut rect_color = Color::White;
                let mut found_rect = false;
                
                for rect in &flame_rects {
                    if rect.y == depth as u16 && pos >= rect.x as usize && pos < (rect.x + rect.width) as usize {
                        rect_color = if rect.selected {
                            Color::Cyan // Highlight selected
                        } else {
                            rect.color
                        };
                        found_rect = true;
                        break;
                    }
                }
                
                if !found_rect {
                    rect_color = Color::White;
                }
                
                // If color changed, finalize current span
                if rect_color != current_color && !current_span.is_empty() {
                    spans.push(Span::styled(current_span.clone(), Style::default().fg(current_color)));
                    current_span.clear();
                }
                
                current_span.push(ch);
                current_color = rect_color;
            }
            
            // Add final span
            if !current_span.is_empty() {
                spans.push(Span::styled(current_span, Style::default().fg(current_color)));
            }
            
            text_lines.push(Line::from(spans));
        }
        
        // Render the flame visualization
        let flame_display = Paragraph::new(text_lines)
            .block(Block::default().borders(Borders::ALL).title("Enhanced Flame Graph"))
            .style(Style::default().bg(Color::Black));
            
        f.render_widget(flame_display, flame_area);
    }
    
    fn create_stack_line<'a>(&self, stack: &'a StackInfo, width: u16, style: Style) -> Line<'a> {
        let mut spans = Vec::new();
        
        // Add a space at the beginning
        if width > 1 {
            spans.push(Span::styled(" ", style));
        }
        
        // Add the function name with search highlighting if needed
        let name_spans = if stack.hit && self.search_pattern.is_some() {
            self.create_highlighted_spans(&stack.name, style)
        } else {
            vec![Span::styled(&stack.name, style)]
        };
        spans.extend(name_spans);
        
        // Fill the rest with padding
        let used_width = 1 + stack.name.len(); // space + name
        let padding_width = width.saturating_sub(used_width as u16) as usize;
        if padding_width > 0 {
            spans.push(Span::styled(
                " ".repeat(padding_width),
                style,
            ));
        }
        
        Line::from(spans)
    }
    
    fn create_highlighted_spans<'a>(&self, text: &'a str, base_style: Style) -> Vec<Span<'a>> {
        if let Some(search) = &self.search_pattern {
            let mut spans = Vec::new();
            let mut last_end = 0;
            
            for mat in search.regex.find_iter(text) {
                // Add text before match
                if mat.start() > last_end {
                    spans.push(Span::styled(&text[last_end..mat.start()], base_style));
                }
                
                // Add highlighted match
                spans.push(Span::styled(
                    mat.as_str(),
                    base_style.fg(Color::Rgb(255, 0, 0)).add_modifier(Modifier::BOLD),
                ));
                
                last_end = mat.end();
            }
            
            // Add remaining text
            if last_end < text.len() {
                spans.push(Span::styled(&text[last_end..], base_style));
            }
            
            spans
        } else {
            vec![Span::styled(text, base_style)]
        }
    }
    
    fn render_table(&self, f: &mut Frame, area: Rect) {
        // Create table rows for all stacks sorted by total count
        let mut stack_entries: Vec<_> = self.stacks.iter()
            .filter(|stack| stack.name != ROOT)
            .collect();
        
        stack_entries.sort_by(|a, b| b.total_count.cmp(&a.total_count));
        
        let header = Row::new(vec!["Total", "Self", "Name"])
            .style(Style::default().add_modifier(Modifier::BOLD));
        
        let rows: Vec<Row> = stack_entries
            .iter()
            .filter(|stack| {
                if let Some(search) = &self.search_pattern {
                    !search.is_active || stack.hit
                } else {
                    true
                }
            })
            .enumerate()
            .map(|(i, stack)| {
                let total_pct = (stack.total_count as f64 / self.total_samples as f64) * 100.0;
                let self_pct = (stack.self_count as f64 / self.total_samples as f64) * 100.0;
                
                let style = if Some(i) == self.table_selected {
                    Style::default().bg(Color::Rgb(65, 65, 65))
                } else {
                    Style::default()
                };
                
                Row::new(vec![
                    format!("{} ({:.1}%)", stack.total_count, total_pct),
                    format!("{} ({:.1}%)", stack.self_count, self_pct),
                    stack.name.clone(),
                ]).style(style)
            })
            .collect();
        
        let table = Table::new(
            rows,
            [
                Constraint::Length(15),
                Constraint::Length(15),
                Constraint::Fill(1),
            ],
        )
        .header(header)
        .block(Block::default().borders(Borders::ALL).title("Function Statistics"));
        
        f.render_widget(table, area);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_stack_traces() -> Vec<ProfileStackTrace> {
        vec![
            ProfileStackTrace {
                frames: vec!["main".to_string(), "foo".to_string(), "bar".to_string()],
                count: 10,
            },
            ProfileStackTrace {
                frames: vec!["main".to_string(), "foo".to_string(), "baz".to_string()],
                count: 20,
            },
            ProfileStackTrace {
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