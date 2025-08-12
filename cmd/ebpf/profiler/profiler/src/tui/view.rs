use crate::tui::flame::{FlameGraph, SearchPattern, StackIdentifier, StackInfo, SortColumn, ZoomState, ROOT_ID};
use anyhow::Result;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ViewKind {
    FlameGraph,
    Table,
}

#[derive(Debug, Clone)]
pub struct TableState {
    pub selected: Option<usize>,
    pub offset: usize,
}

impl Default for TableState {
    fn default() -> Self {
        Self {
            selected: Some(0),
            offset: 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct FlameGraphState {
    pub selected: StackIdentifier,
    pub zoom: Option<ZoomState>,
    pub search_pattern: Option<SearchPattern>,
    pub view_kind: ViewKind,
    pub level_offset: usize,
    pub table_state: TableState,
    pub freeze: bool,
    pub search_result_index: Option<usize>,
    pub search_results: Vec<StackIdentifier>,
}

impl Default for FlameGraphState {
    fn default() -> Self {
        Self {
            selected: ROOT_ID,
            zoom: None,
            search_pattern: None,
            view_kind: ViewKind::FlameGraph,
            level_offset: 0,
            table_state: TableState::default(),
            freeze: false,
            search_result_index: None,
            search_results: Vec::new(),
        }
    }
}

#[derive(Debug)]
pub struct FlameGraphView {
    pub flamegraph: FlameGraph,
    pub state: FlameGraphState,
    frame_width: u16,
    frame_height: u16,
}

impl FlameGraphView {
    pub fn new(flamegraph: FlameGraph) -> Self {
        Self {
            flamegraph,
            state: FlameGraphState::default(),
            frame_width: 120,
            frame_height: 40,
        }
    }

    /// Replace the flamegraph while preserving state as much as possible
    pub fn replace_flamegraph(&mut self, new_flamegraph: FlameGraph) {
        // Try to preserve selected stack if it still exists
        let old_selected_name = self.flamegraph.get_stack_short_name(&self.state.selected);
        let mut new_selected = ROOT_ID;
        
        // Find a stack with the same name in the new flamegraph
        for (id, stack) in &new_flamegraph.stacks {
            if stack.name == old_selected_name {
                new_selected = *id;
                break;
            }
        }
        
        // Update flamegraph
        self.flamegraph = new_flamegraph;
        self.state.selected = new_selected;
        
        // Re-apply search pattern if exists
        if let Some(pattern) = &self.state.search_pattern {
            self.flamegraph.apply_search_pattern(pattern);
            self.build_search_results();
        }
        
        // Clear zoom if zoomed stack no longer exists
        if let Some(zoom) = &self.state.zoom {
            if !self.flamegraph.stacks.contains_key(&zoom.stack_id) {
                self.state.zoom = None;
                self.state.level_offset = 0;
            }
        }
    }

    /// Set search pattern
    pub fn set_search_pattern(&mut self, pattern: &str, is_regex: bool) -> Result<()> {
        if pattern.is_empty() {
            return self.clear_search_pattern();
        }
        
        let search_pattern = SearchPattern::new(pattern, is_regex, true)?;
        self.flamegraph.apply_search_pattern(&search_pattern);
        self.state.search_pattern = Some(search_pattern);
        self.build_search_results();
        
        // Jump to first search result
        if !self.state.search_results.is_empty() {
            self.state.search_result_index = Some(0);
            self.state.selected = self.state.search_results[0];
        }
        
        Ok(())
    }

    /// Clear search pattern
    pub fn clear_search_pattern(&mut self) -> Result<()> {
        self.flamegraph.clear_search_pattern();
        self.state.search_pattern = None;
        self.state.search_results.clear();
        self.state.search_result_index = None;
        Ok(())
    }

    /// Build list of search results
    fn build_search_results(&mut self) {
        self.state.search_results = self.flamegraph
            .stacks
            .values()
            .filter(|s| s.hit)
            .map(|s| s.id)
            .collect();
        
        // Sort by total count descending
        self.state.search_results.sort_by(|&a, &b| {
            let count_a = self.flamegraph.stacks[&a].total_count;
            let count_b = self.flamegraph.stacks[&b].total_count;
            count_b.cmp(&count_a)
        });
    }

    /// Navigate to next search result
    pub fn next_search_result(&mut self) {
        if let Some(current_index) = self.state.search_result_index {
            if !self.state.search_results.is_empty() {
                let next_index = (current_index + 1) % self.state.search_results.len();
                self.state.search_result_index = Some(next_index);
                self.state.selected = self.state.search_results[next_index];
            }
        }
    }

    /// Navigate to previous search result
    pub fn prev_search_result(&mut self) {
        if let Some(current_index) = self.state.search_result_index {
            if !self.state.search_results.is_empty() {
                let prev_index = if current_index == 0 {
                    self.state.search_results.len() - 1
                } else {
                    current_index - 1
                };
                self.state.search_result_index = Some(prev_index);
                self.state.selected = self.state.search_results[prev_index];
            }
        }
    }

    /// Zoom to a stack
    pub fn zoom_to_stack(&mut self, stack_id: StackIdentifier) {
        let ancestors = self.flamegraph.get_ancestors(&stack_id);
        self.state.zoom = Some(ZoomState { stack_id, ancestors });
        if let Some(stack) = self.flamegraph.get_stack(&stack_id) {
            self.state.level_offset = stack.level;
        }
    }

    /// Zoom out
    pub fn zoom_out(&mut self) {
        if let Some(zoom) = &self.state.zoom {
            if let Some(stack) = self.flamegraph.get_stack(&zoom.stack_id) {
                if let Some(parent_id) = stack.parent {
                    if parent_id == ROOT_ID {
                        self.reset_zoom();
                    } else {
                        self.zoom_to_stack(parent_id);
                    }
                } else {
                    self.reset_zoom();
                }
            } else {
                self.reset_zoom();
            }
        }
    }

    /// Reset zoom
    pub fn reset_zoom(&mut self) {
        self.state.zoom = None;
        self.state.level_offset = 0;
        self.state.selected = ROOT_ID;
    }

    /// Toggle view mode
    pub fn toggle_view_mode(&mut self) {
        self.state.view_kind = match self.state.view_kind {
            ViewKind::FlameGraph => ViewKind::Table,
            ViewKind::Table => ViewKind::FlameGraph,
        };
    }

    /// Navigate up in flamegraph
    pub fn navigate_up(&mut self) {
        match self.state.view_kind {
            ViewKind::FlameGraph => {
                if let Some(stack) = self.flamegraph.get_stack(&self.state.selected) {
                    if let Some(parent_id) = stack.parent {
                        self.state.selected = parent_id;
                    }
                }
            }
            ViewKind::Table => {
                if let Some(selected) = self.state.table_state.selected {
                    if selected > 0 {
                        self.state.table_state.selected = Some(selected - 1);
                    }
                } else {
                    self.state.table_state.selected = Some(0);
                }
            }
        }
    }

    /// Navigate down in flamegraph
    pub fn navigate_down(&mut self) {
        match self.state.view_kind {
            ViewKind::FlameGraph => {
                if let Some(stack) = self.flamegraph.get_stack(&self.state.selected) {
                    if !stack.children.is_empty() {
                        self.state.selected = stack.children[0];
                    }
                }
            }
            ViewKind::Table => {
                let visible_count = self.flamegraph.ordered_stacks.entries.iter()
                    .filter(|e| e.visible)
                    .count();
                
                if let Some(selected) = self.state.table_state.selected {
                    if selected + 1 < visible_count {
                        self.state.table_state.selected = Some(selected + 1);
                    }
                } else if visible_count > 0 {
                    self.state.table_state.selected = Some(0);
                }
            }
        }
    }

    /// Navigate left in flamegraph
    pub fn navigate_left(&mut self) {
        if self.state.view_kind == ViewKind::FlameGraph {
            if let Some(stack) = self.flamegraph.get_stack(&self.state.selected) {
                if let Some(parent_id) = stack.parent {
                    if let Some(parent) = self.flamegraph.get_stack(&parent_id) {
                        if let Some(pos) = parent.children.iter().position(|&id| id == self.state.selected) {
                            if pos > 0 {
                                self.state.selected = parent.children[pos - 1];
                            }
                        }
                    }
                }
            }
        }
    }

    /// Navigate right in flamegraph
    pub fn navigate_right(&mut self) {
        if self.state.view_kind == ViewKind::FlameGraph {
            if let Some(stack) = self.flamegraph.get_stack(&self.state.selected) {
                if let Some(parent_id) = stack.parent {
                    if let Some(parent) = self.flamegraph.get_stack(&parent_id) {
                        if let Some(pos) = parent.children.iter().position(|&id| id == self.state.selected) {
                            if pos + 1 < parent.children.len() {
                                self.state.selected = parent.children[pos + 1];
                            }
                        }
                    }
                }
            }
        }
    }

    /// Scroll forward (page down)
    pub fn scroll_forward(&mut self) {
        match self.state.view_kind {
            ViewKind::FlameGraph => {
                // Scroll down by frame height
                self.state.level_offset = self.state.level_offset.saturating_add(self.frame_height as usize / 2);
            }
            ViewKind::Table => {
                // Page down in table
                if let Some(selected) = self.state.table_state.selected {
                    let visible_count = self.flamegraph.ordered_stacks.entries.iter()
                        .filter(|e| e.visible)
                        .count();
                    let new_selected = std::cmp::min(selected + self.frame_height as usize, visible_count.saturating_sub(1));
                    self.state.table_state.selected = Some(new_selected);
                }
            }
        }
    }

    /// Scroll backward (page up)
    pub fn scroll_backward(&mut self) {
        match self.state.view_kind {
            ViewKind::FlameGraph => {
                // Scroll up
                self.state.level_offset = self.state.level_offset.saturating_sub(self.frame_height as usize / 2);
            }
            ViewKind::Table => {
                // Page up in table
                if let Some(selected) = self.state.table_state.selected {
                    let new_selected = selected.saturating_sub(self.frame_height as usize);
                    self.state.table_state.selected = Some(new_selected);
                }
            }
        }
    }

    /// Sort table by column
    pub fn sort_table(&mut self, column: SortColumn) {
        self.flamegraph.sort_ordered_stacks(column);
    }

    /// Get currently selected stack
    pub fn get_selected_stack(&self) -> Option<&StackInfo> {
        self.flamegraph.get_stack(&self.state.selected)
    }

    /// Check if root is selected
    pub fn is_root_selected(&self) -> bool {
        self.state.selected == ROOT_ID
    }

    /// Get selected row name in table view
    pub fn get_selected_row_name(&self) -> Option<&str> {
        if let Some(selected_index) = self.state.table_state.selected {
            let visible_entries: Vec<_> = self.flamegraph.ordered_stacks.entries.iter()
                .filter(|e| e.visible)
                .collect();
            
            if selected_index < visible_entries.len() {
                return Some(&visible_entries[selected_index].name);
            }
        }
        None
    }

    /// Set frame dimensions
    pub fn set_frame_width(&mut self, width: u16) {
        self.frame_width = width;
    }

    pub fn set_frame_height(&mut self, height: u16) {
        self.frame_height = height;
    }
}