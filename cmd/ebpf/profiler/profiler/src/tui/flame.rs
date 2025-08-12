use crate::ebpf_profiler::ProfileStackTrace;
use anyhow::Result;
use regex::Regex;
use std::collections::HashMap;

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
    pub hit: bool,
    pub name: String,
    pub full_name: String,
}

#[derive(Debug, Clone)]
pub struct SearchPattern {
    pub pattern: String,
    pub regex: Regex,
    pub is_manual: bool,
    pub is_regex: bool,
}

impl SearchPattern {
    pub fn new(pattern: &str, is_regex: bool, is_manual: bool) -> Result<Self> {
        let regex = if is_regex {
            Regex::new(pattern)
        } else {
            Regex::new(&regex::escape(pattern))
        };
        
        match regex {
            Ok(re) => Ok(Self {
                pattern: pattern.to_string(),
                regex: re,
                is_manual,
                is_regex,
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
pub enum SortColumn {
    Total,
    Own,
}

#[derive(Debug, Clone)]
pub struct OrderedStackEntry {
    pub stack_id: StackIdentifier,
    pub name: String,
    pub total_count: u64,
    pub own_count: u64,
    pub visible: bool,
}

#[derive(Debug, Clone)]
pub struct OrderedStacks {
    pub entries: Vec<OrderedStackEntry>,
    pub sorted_column: SortColumn,
    pub search_pattern_ignored_because_of_no_match: bool,
}

#[derive(Debug, Clone)]
pub struct FlameGraph {
    pub stacks: HashMap<StackIdentifier, StackInfo>,
    pub root_id: StackIdentifier,
    pub total_samples: u64,
    pub levels: Vec<Vec<StackIdentifier>>,
    pub ordered_stacks: OrderedStacks,
    pub hit_coverage_count: Option<u64>,
    next_id: StackIdentifier,
}

impl FlameGraph {
    /// Create an empty flamegraph
    pub fn empty() -> Self {
        let mut stacks = HashMap::new();
        stacks.insert(ROOT_ID, StackInfo {
            id: ROOT_ID,
            total_count: 0,
            self_count: 0,
            parent: None,
            children: Vec::new(),
            level: 0,
            hit: false,
            name: ROOT.to_string(),
            full_name: ROOT.to_string(),
        });

        Self {
            stacks,
            root_id: ROOT_ID,
            total_samples: 0,
            levels: vec![vec![ROOT_ID]],
            ordered_stacks: OrderedStacks {
                entries: Vec::new(),
                sorted_column: SortColumn::Total,
                search_pattern_ignored_because_of_no_match: false,
            },
            hit_coverage_count: None,
            next_id: 1,
        }
    }

    /// Create flamegraph from stack traces
    pub fn from_stack_traces(stack_traces: Vec<ProfileStackTrace>) -> Self {
        let mut flamegraph = Self::empty();
        flamegraph.total_samples = stack_traces.iter().map(|t| t.count).sum();
        
        // Build the flame graph tree structure
        for stack_trace in &stack_traces {
            flamegraph.process_stack_trace(stack_trace);
        }
        
        // Update root total count
        flamegraph.stacks.get_mut(&ROOT_ID).unwrap().total_count = flamegraph.total_samples;
        
        // Build levels and ordered stacks
        flamegraph.build_levels();
        flamegraph.build_ordered_stacks();
        
        flamegraph
    }

    fn process_stack_trace(&mut self, stack_trace: &ProfileStackTrace) {
        let mut parent_id = ROOT_ID;
        let mut level = 1;
        
        // Walk through the stack trace (reverse order for flame graph)
        for frame in stack_trace.frames.iter().rev() {
            let stack_id = self.find_or_create_stack(frame, parent_id, level);
            
            // Update counts
            self.stacks.get_mut(&stack_id).unwrap().total_count += stack_trace.count;
            if level == stack_trace.frames.len() {
                // This is the leaf node
                self.stacks.get_mut(&stack_id).unwrap().self_count += stack_trace.count;
            }
            
            parent_id = stack_id;
            level += 1;
        }
    }
    
    fn find_or_create_stack(
        &mut self,
        name: &str,
        parent_id: StackIdentifier,
        level: usize,
    ) -> StackIdentifier {
        // Check if this stack already exists as a child of the parent
        let parent = &self.stacks[&parent_id];
        for &child_id in &parent.children {
            if self.stacks[&child_id].name == name {
                return child_id;
            }
        }
        
        // Create new stack
        let stack_id = self.next_id;
        self.next_id += 1;
        
        // Build full name by walking up the parent chain
        let full_name = self.build_full_name(name, parent_id);
        
        self.stacks.insert(stack_id, StackInfo {
            id: stack_id,
            total_count: 0,
            self_count: 0,
            parent: Some(parent_id),
            children: Vec::new(),
            level,
            hit: false,
            name: name.to_string(),
            full_name,
        });
        
        // Add to parent's children
        self.stacks.get_mut(&parent_id).unwrap().children.push(stack_id);
        stack_id
    }

    fn build_full_name(&self, name: &str, parent_id: StackIdentifier) -> String {
        if parent_id == ROOT_ID {
            name.to_string()
        } else {
            let parent = &self.stacks[&parent_id];
            format!("{};{}", parent.full_name, name)
        }
    }

    fn build_levels(&mut self) {
        self.levels.clear();
        self.build_levels_recursive(ROOT_ID);
        
        // Sort children by count for better visualization
        let stack_counts: HashMap<usize, u64> = self.stacks
            .iter()
            .map(|(id, s)| (*id, s.total_count))
            .collect();
        
        for stack in self.stacks.values_mut() {
            stack.children.sort_by(|&a, &b| {
                let count_a = stack_counts.get(&a).unwrap_or(&0);
                let count_b = stack_counts.get(&b).unwrap_or(&0);
                count_b.cmp(count_a)
            });
        }
    }
    
    fn build_levels_recursive(&mut self, stack_id: StackIdentifier) {
        let level = self.stacks[&stack_id].level;
        
        // Ensure levels vector is large enough
        while self.levels.len() <= level {
            self.levels.push(Vec::new());
        }
        self.levels[level].push(stack_id);
        
        // Process children
        let children = self.stacks[&stack_id].children.clone();
        for child_id in children {
            self.build_levels_recursive(child_id);
        }
    }

    fn build_ordered_stacks(&mut self) {
        let mut entries: Vec<OrderedStackEntry> = self.stacks
            .values()
            .filter(|stack| stack.name != ROOT)
            .map(|stack| OrderedStackEntry {
                stack_id: stack.id,
                name: stack.name.clone(),
                total_count: stack.total_count,
                own_count: stack.self_count,
                visible: true,
            })
            .collect();

        // Sort by total count initially
        entries.sort_by(|a, b| b.total_count.cmp(&a.total_count));

        self.ordered_stacks = OrderedStacks {
            entries,
            sorted_column: SortColumn::Total,
            search_pattern_ignored_because_of_no_match: false,
        };
    }

    /// Get a stack by ID
    pub fn get_stack(&self, id: &StackIdentifier) -> Option<&StackInfo> {
        self.stacks.get(id)
    }

    /// Get the root stack
    pub fn root(&self) -> &StackInfo {
        &self.stacks[&self.root_id]
    }

    /// Get total sample count
    pub fn total_count(&self) -> u64 {
        self.total_samples
    }

    /// Get ancestors of a stack
    pub fn get_ancestors(&self, stack_id: &StackIdentifier) -> Vec<StackIdentifier> {
        let mut ancestors = Vec::new();
        let mut current_id = *stack_id;
        
        while let Some(stack) = self.stacks.get(&current_id) {
            ancestors.push(current_id);
            if let Some(parent_id) = stack.parent {
                current_id = parent_id;
            } else {
                break;
            }
        }
        
        ancestors
    }

    /// Get short name for a stack
    pub fn get_stack_short_name(&self, stack_id: &StackIdentifier) -> &str {
        if let Some(stack) = self.stacks.get(stack_id) {
            &stack.name
        } else {
            ""
        }
    }

    /// Get short name from stack info
    pub fn get_stack_short_name_from_info<'a>(&self, stack: &'a StackInfo) -> &'a str {
        &stack.name
    }

    /// Get full name from stack info
    pub fn get_stack_full_name_from_info<'a>(&self, stack: &'a StackInfo) -> &'a str {
        &stack.full_name
    }

    /// Apply search pattern to stacks
    pub fn apply_search_pattern(&mut self, pattern: &SearchPattern) {
        for stack in self.stacks.values_mut() {
            stack.hit = pattern.regex.is_match(&stack.name);
        }

        // Calculate hit coverage
        self.hit_coverage_count = Some(
            self.stacks
                .values()
                .filter(|s| s.hit)
                .map(|s| s.total_count)
                .sum()
        );

        // Update ordered stacks visibility
        for entry in &mut self.ordered_stacks.entries {
            if let Some(stack) = self.stacks.get(&entry.stack_id) {
                entry.visible = stack.hit;
            }
        }

        // Check if any matches found
        let has_matches = self.ordered_stacks.entries.iter().any(|e| e.visible);
        if !has_matches {
            // Show all if no matches
            for entry in &mut self.ordered_stacks.entries {
                entry.visible = true;
            }
            self.ordered_stacks.search_pattern_ignored_because_of_no_match = true;
        } else {
            self.ordered_stacks.search_pattern_ignored_because_of_no_match = false;
        }
    }

    /// Clear search pattern
    pub fn clear_search_pattern(&mut self) {
        for stack in self.stacks.values_mut() {
            stack.hit = false;
        }
        
        for entry in &mut self.ordered_stacks.entries {
            entry.visible = true;
        }
        
        self.hit_coverage_count = None;
        self.ordered_stacks.search_pattern_ignored_because_of_no_match = false;
    }

    /// Get hit coverage count
    pub fn hit_coverage_count(&self) -> Option<u64> {
        self.hit_coverage_count
    }

    /// Sort ordered stacks by column
    pub fn sort_ordered_stacks(&mut self, column: SortColumn) {
        match column {
            SortColumn::Total => {
                self.ordered_stacks.entries.sort_by(|a, b| b.total_count.cmp(&a.total_count));
            }
            SortColumn::Own => {
                self.ordered_stacks.entries.sort_by(|a, b| b.own_count.cmp(&a.own_count));
            }
        }
        self.ordered_stacks.sorted_column = column;
    }
}