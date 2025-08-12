use crate::tui::app::{App, ProfilerInput};
use crate::tui::flame::{StackIdentifier, StackInfo, SortColumn};
use crate::tui::view::ViewKind;
use ratatui::{
    buffer::Buffer,
    layout::{Alignment, Constraint, Direction, Layout, Offset, Rect},
    style::{Color, Modifier, Style, Stylize},
    text::{Line, Span, Text},
    widgets::{
        block::Position, Block, Borders, Paragraph, Row, StatefulWidget, Table, TableState, Widget,
        Wrap,
    },
    Frame,
};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::Duration;

const SEARCH_PREFIX: &str = "";
const COLOR_SELECTED_STACK: Color = Color::Rgb(250, 250, 250);
const COLOR_MATCHED_BACKGROUND: Color = Color::Rgb(10, 35, 150);
const COLOR_TABLE_SELECTED_ROW: Color = Color::Rgb(65, 65, 65);

#[derive(Debug, Clone, Default)]
pub struct ProfilerWidgetState {
    frame_height: u16,
    frame_width: u16,
    render_time: Duration,
    cursor_position: Option<(u16, u16)>,
}

struct ZoomState {
    zoom_stack: StackIdentifier,
    ancestors: Vec<StackIdentifier>,
}

pub struct ProfilerWidget<'a> {
    pub app: &'a App,
}

impl<'a> ProfilerWidget<'a> {
    pub fn new(app: &'a App) -> Self {
        Self { app }
    }
}

impl StatefulWidget for ProfilerWidget<'_> {
    type State = ProfilerWidgetState;

    fn render(self, area: Rect, buf: &mut Buffer, state: &mut Self::State) {
        self.render_all(area, buf, state);
    }
}

impl<'a> ProfilerWidget<'a> {
    fn render_all(self, area: Rect, buf: &mut Buffer, state: &mut ProfilerWidgetState) {
        let view_kind_indicator = self.get_view_kind_indicator();
        let version_indicator = self.get_version_indicator();

        let header_text = Text::from(self.get_header_text(area.width));
        let header = Paragraph::new(header_text)
            .wrap(Wrap { trim: false })
            .alignment(Alignment::Center);
        let indicator_width = std::cmp::max(view_kind_indicator.width(), version_indicator.width());
        let _filename_width = area
            .width
            .saturating_sub(indicator_width as u16)
            .saturating_sub(indicator_width as u16);
        // Use fixed height since line_count is private in ratatui 0.29.0
        let header_line_count_with_borders = 3; // Header text + borders

        // Status bars (search, selected stack, etc.)
        let status_bars = self
            .get_status_text(area.width)
            .iter()
            .map(|(title, line)| {
                Paragraph::new(line.clone())
                    .wrap(Wrap { trim: true })
                    .block(
                        Block::new()
                            .borders(Borders::TOP)
                            .title(format!("{} ", title))
                            .title_style(Style::default().add_modifier(Modifier::BOLD).yellow())
                            .title_position(Position::Top),
                    )
            })
            .collect::<Vec<Paragraph>>();

        // Help bar
        let help_tags = self.get_help_tags();
        let help_bar = Paragraph::new(help_tags.get_line())
            .block(
                Block::new()
                    .borders(Borders::TOP)
                    .border_style(Style::default()),
            )
            .alignment(Alignment::Center);

        let mut constraints = vec![
            Constraint::Length(header_line_count_with_borders),
            Constraint::Fill(1),
        ];

        // Constraints for status bars
        let status_bar_index_start = constraints.len();
        for _bar in status_bars.iter() {
            // Use fixed height since line_count is private in ratatui 0.29.0
            constraints.push(Constraint::Length(2));
        }

        // Constraint for help bar
        constraints.push(Constraint::Length(2));
        let help_bar_index = constraints.len() - 1;

        let layout = Layout::default()
            .direction(Direction::Vertical)
            .constraints(constraints)
            .split(area);

        // Header area
        let header_layout = Layout::default()
            .direction(Direction::Horizontal)
            .constraints(vec![
                Constraint::Length(view_kind_indicator.width() as u16),
                Constraint::Fill(1),
                Constraint::Length(version_indicator.width() as u16),
            ])
            .split(layout[0]);
        let header_block = Block::default().borders(Borders::BOTTOM | Borders::TOP);
        let header_offset = Offset { x: 0, y: 1 };
        header_block.render(layout[0], buf);
        view_kind_indicator.render(header_layout[0].offset(header_offset), buf);
        header.render(header_layout[1].offset(header_offset), buf);
        version_indicator.render(header_layout[2].offset(header_offset), buf);

        // Main area for flamegraph / table view
        let tic = std::time::Instant::now();
        let main_area = layout[1];
        if self.is_flamegraph_view() {
            self.render_flamegraph(main_area, buf);
        } else {
            self.render_table(main_area, buf);
        }
        let render_time = tic.elapsed();

        // Status bars
        for (i, bar) in status_bars.iter().enumerate() {
            bar.render(layout[status_bar_index_start + i], buf);
        }

        // Help bar
        help_bar.render(layout[help_bar_index], buf);

        // Update widget state
        state.frame_height = main_area.height;
        state.frame_width = main_area.width;
        state.render_time = render_time;
        state.cursor_position = self.get_cursor_position(layout[help_bar_index - 1]);
    }

    fn get_help_tags(&self) -> HelpTags {
        let mut help_tags = HelpTags::new();
        if self.is_flamegraph_view() {
            help_tags.add("hjkl", "move cursor");
            help_tags.add("f/b", "scroll");
            help_tags.add("enter/esc", "zoom");
            help_tags.add("/", "search");
            help_tags.add("#", "search like cursor");
            if let Some(p) = &self.app.flamegraph_view.state.search_pattern {
                if p.is_manual {
                    help_tags.add("n/N", "next/prev search");
                }
            }
            if self.app.live_mode {
                if self.app.freeze {
                    help_tags.add("z", "unfreeze");
                } else {
                    help_tags.add("z", "freeze");
                }
            }
        } else {
            help_tags.add("j/k", "move cursor");
            help_tags.add("f/b", "scroll");
            help_tags.add("1", "sort by total");
            help_tags.add("2", "sort by own");
            help_tags.add("/", "filter");
        }
        help_tags
    }

    fn render_flamegraph(&self, area: Rect, buf: &mut Buffer) {
        let zoom_state = self
            .app
            .flamegraph_view
            .state
            .zoom
            .as_ref()
            .map(|zoom| ZoomState {
                zoom_stack: zoom.stack_id,
                ancestors: self.app.flamegraph().get_ancestors(&zoom.stack_id),
            });
        let re = self
            .app
            .flamegraph_view
            .state
            .search_pattern
            .as_ref()
            .and_then(|p| {
                if p.is_manual {
                    Some(&p.regex)
                } else {
                    None
                }
            });
        self.render_stacks(
            self.app.flamegraph().root(),
            buf,
            area.x,
            area.y,
            area.width as f64,
            area.bottom(),
            &zoom_state,
            &re,
        );
    }

    fn render_table(&self, area: Rect, buf: &mut Buffer) {
        let ordered_stacks_table = self.get_ordered_stacks_table();
        let mut table_state = TableState::default()
            .with_selected(self.app.flamegraph_view.state.table_state.selected)
            .with_offset(self.app.flamegraph_view.state.table_state.offset);
        StatefulWidget::render(ordered_stacks_table, area, buf, &mut table_state);
    }

    #[allow(clippy::too_many_arguments)]
    fn render_stacks(
        &self,
        stack: &'a StackInfo,
        buf: &mut Buffer,
        x: u16,
        y: u16,
        x_budget: f64,
        y_max: u16,
        zoom_state: &Option<ZoomState>,
        re: &Option<&regex::Regex>,
    ) -> bool {
        let after_level_offset = stack.level >= self.app.flamegraph_view.state.level_offset;

        // Only render if the stack is visible
        let effective_x_budget = x_budget as u16;
        if y < y_max && effective_x_budget > 0 {
            if after_level_offset {
                let stack_color = self.get_stack_color(stack, zoom_state);
                let text_color = Self::get_text_color(stack_color);
                let style = Style::default().fg(text_color).bg(stack_color);
                let line = self.get_line_for_stack(stack, effective_x_budget, style, re);
                buf.set_line(x, y, &line, effective_x_budget);
            }
        } else {
            // Can skip rendering children if the stack is already not visible
            let has_more_rows_to_render = (y >= y_max) && effective_x_budget > 0;
            return has_more_rows_to_render;
        }

        // Render children
        let mut x_offset = 0;
        let zoomed_child = stack
            .children
            .iter()
            .position(|child_id| {
                if let Some(zoom_state) = zoom_state {
                    *child_id == zoom_state.zoom_stack || zoom_state.ancestors.contains(child_id)
                } else {
                    false
                }
            })
            .map(|idx| stack.children[idx]);

        let mut has_more_rows_to_render = false;
        for child_id in &stack.children {
            let child_stack = self.app.flamegraph().get_stack(child_id).unwrap();
            let child_x_budget = if let Some(zoomed_child_id) = zoomed_child {
                // Zoomed child takes all space
                if zoomed_child_id == *child_id {
                    x_budget
                } else {
                    0.0
                }
            } else {
                x_budget * (child_stack.total_count as f64 / stack.total_count as f64)
            };
            has_more_rows_to_render |= self.render_stacks(
                child_stack,
                buf,
                x + x_offset,
                y + if after_level_offset { 1 } else { 0 },
                child_x_budget,
                y_max,
                zoom_state,
                re,
            );
            x_offset += child_x_budget as u16;
        }

        has_more_rows_to_render
    }

    fn get_ordered_stacks_table(&self) -> Table {
        let add_sorted_indicator = |label: &str, sort_column: SortColumn| {
            let suffix = if sort_column == self.app.flamegraph().ordered_stacks.sorted_column {
                " [▼]"
            } else {
                ""
            };
            format!("{}{}", label, suffix)
        };
        let header = Row::new(vec![
            add_sorted_indicator("Total", SortColumn::Total),
            add_sorted_indicator("Own", SortColumn::Own),
            "Name".to_string(),
        ])
        .style(
            Style::default()
                .add_modifier(Modifier::BOLD)
                .add_modifier(Modifier::REVERSED),
        );
        let entries = &self.app.flamegraph().ordered_stacks.entries;
        let mut rows = vec![];
        let total_count = self.app.flamegraph().total_count();
        let mut total_max_width: u16 = 0;
        let mut own_max_width: u16 = 0;

        fn format_count(count: u64, total_count: u64) -> String {
            format!(
                "{} ({:.2}%)  ",
                count,
                100.0 * count as f64 / total_count as f64
            )
        }

        for entry in entries.iter().filter(|entry| entry.visible) {
            let total_formatted = Line::from(format_count(entry.total_count, total_count));
            let own_formatted = Line::from(format_count(entry.own_count, total_count));
            total_max_width = total_max_width.max(total_formatted.width() as u16);
            own_max_width = own_max_width.max(own_formatted.width() as u16);
            let name_formatted = if let Some(p) = &self.app.flamegraph_view.state.search_pattern {
                if p.is_manual {
                    Line::from(self.get_highlighted_spans(
                        entry.name.as_str(),
                        &p.regex,
                        Style::default(),
                    ))
                } else {
                    Line::from(entry.name.as_str())
                }
            } else {
                Line::from(entry.name.as_str())
            };
            rows.push(Row::new(vec![
                total_formatted,
                own_formatted,
                name_formatted,
            ]));
        }
        let widths = [
            Constraint::Max(total_max_width),
            Constraint::Max(own_max_width),
            Constraint::Fill(1),
        ];
        Table::new(rows, widths)
            .header(header)
            .row_highlight_style(Style::default().bg(COLOR_TABLE_SELECTED_ROW))
    }

    fn get_highlighted_spans<'b>(
        &self,
        text: &'b str,
        re: &regex::Regex,
        style: Style,
    ) -> Vec<Span<'b>> {
        let mut spans = Vec::new();
        let mut matches = re.find_iter(text);
        for part in re.split(text) {
            // Non-match, regular style
            spans.push(Span::styled(part, style));
            // Match, highlighted style
            if let Some(matched) = matches.next() {
                spans.push(Span::styled(
                    matched.as_str(),
                    style
                        .fg(Color::Rgb(225, 10, 10))
                        .add_modifier(Modifier::BOLD),
                ));
            }
        }
        spans
    }

    fn get_line_for_stack<'b>(
        &self,
        stack: &'b StackInfo,
        width: u16,
        style: Style,
        re: &Option<&regex::Regex>,
    ) -> Line<'b> {
        let short_name = self.app.flamegraph().get_stack_short_name_from_info(stack);

        // Empty space separator at the beginning
        let mut spans = vec![Span::styled(if width > 1 { " " } else { "." }, style)];

        // Stack name with highlighted search terms if needed
        let short_name_spans = if let (true, &Some(re)) = (stack.hit, re) {
            self.get_highlighted_spans(short_name, re, style)
        } else {
            vec![Span::styled(short_name, style)]
        };
        spans.extend(short_name_spans);

        // Padding to fill the rest of the width
        let pad_length = width
            .saturating_sub(short_name.len() as u16)
            .saturating_sub(1) as usize;
        spans.push(Span::styled(
            format!("{:width$}", "", width = pad_length),
            style,
        ));

        Line::from(spans)
    }

    fn get_stack_color(&self, stack: &StackInfo, zoom_state: &Option<ZoomState>) -> Color {
        if self.app.flamegraph_view.state.selected == stack.id {
            return COLOR_SELECTED_STACK;
        }
        // Hash-based color generation like flamelens
        fn hash_name(name: &str) -> f64 {
            let mut hasher = DefaultHasher::new();
            name.hash(&mut hasher);
            hasher.finish() as f64 / u64::MAX as f64
        }
        let full_name = self.app.flamegraph().get_stack_full_name_from_info(stack);
        let v1 = hash_name(full_name);
        let v2 = hash_name(full_name);
        let mut r;
        let mut g;
        let mut b;
        if !stack.hit {
            r = 205 + (50.0 * v2) as u8;
            g = (230.0 * v1) as u8;
            b = (55.0 * v2) as u8;
        } else if let Color::Rgb(r_, g_, b_) = COLOR_MATCHED_BACKGROUND {
            r = r_;
            g = g_;
            b = b_;
        } else {
            unreachable!();
        }
        if let Some(zoom_state) = zoom_state {
            if zoom_state.ancestors.contains(&stack.id) {
                r = (r as f64 / 2.5) as u8;
                g = (g as f64 / 2.5) as u8;
                b = (b as f64 / 2.5) as u8;
            }
        }
        Color::Rgb(r, g, b)
    }

    fn get_text_color(c: Color) -> Color {
        match c {
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

    fn get_view_kind_indicator(&self) -> Line {
        let mut header_bottom_title_spans = vec![Span::from(" ")];

        fn _get_view_kind_span(
            label: &str,
            view_kind: ViewKind,
            current_view_kind: ViewKind,
        ) -> Span {
            let (content, style) = if view_kind == current_view_kind {
                (format!("[{}]", label), Style::default().bold().yellow())
            } else {
                (label.to_string(), Style::default().bold())
            };
            Span::styled(content, style)
        }

        header_bottom_title_spans.push(_get_view_kind_span(
            "Flamegraph",
            ViewKind::FlameGraph,
            self.app.flamegraph_view.state.view_kind,
        ));
        header_bottom_title_spans.push(Span::from(" | "));
        header_bottom_title_spans.push(_get_view_kind_span(
            "Top",
            ViewKind::Table,
            self.app.flamegraph_view.state.view_kind,
        ));
        header_bottom_title_spans.push(Span::from(" "));
        Line::from(header_bottom_title_spans)
    }

    fn get_version_indicator(&self) -> Line {
        Line::from(format!("ServiceRadar Profiler v{}", env!("CARGO_PKG_VERSION")))
            .style(Style::default().bold())
    }

    fn get_header_text(&self, _width: u16) -> Line {
        let header_text = match &self.app.profiler_input {
            ProfilerInput::Static(pid, duration) => {
                format!("Process: {} | Duration: {}s | Samples: {}", 
                    pid, duration, self.app.flamegraph().total_count())
            }
            ProfilerInput::Live(pid) => {
                let mut text = format!("Process: {} [Live]", pid);
                if self.app.freeze {
                    text.push_str(" [Frozen; press 'z' to unfreeze]");
                }
                text
            }
        };
        Line::from(header_text).style(Style::default().bold())
    }

    fn get_status_text(&self, width: u16) -> Vec<(&'static str, Line)> {
        if self.app.input_buffer.is_some() {
            self.get_status_text_buffer()
        } else {
            self.get_status_text_command(width)
        }
    }

    fn get_status_text_buffer(&self) -> Vec<(&'static str, Line)> {
        let input_buffer = self.app.input_buffer.as_ref().unwrap();
        let status_text = format!("{}{}", SEARCH_PREFIX, input_buffer.buffer);
        vec![("Search", Line::from(status_text))]
    }

    fn get_cursor_position(&self, status_area: Rect) -> Option<(u16, u16)> {
        self.app.input_buffer.as_ref().map(|input_buffer| {
            (
                (input_buffer.buffer.len() + SEARCH_PREFIX.len()) as u16,
                status_area.bottom().saturating_sub(1),
            )
        })
    }

    fn get_status_text_command(&self, width: u16) -> Vec<(&'static str, Line)> {
        let stack = self
            .app
            .flamegraph()
            .get_stack(&self.app.flamegraph_view.state.selected);
        let root_total_count = self.app.flamegraph().root().total_count;
        let mut lines = vec![];
        match stack {
            Some(stack) => {
                let zoom_total_count = self.app.flamegraph_view.state.zoom.as_ref().map(|zoom| {
                    self.app
                        .flamegraph()
                        .get_stack(&zoom.stack_id)
                        .unwrap()
                        .total_count
                });
                if let Some(p) = &self.app.flamegraph_view.state.search_pattern {
                    if let (true, Some(hit_coverage_count)) =
                        (p.is_manual, self.app.flamegraph().hit_coverage_count())
                    {
                        let mut match_text = format!(
                            "\"{}\" {}",
                            p.regex.as_str(),
                            Self::get_count_stats_str(
                                None,
                                hit_coverage_count,
                                root_total_count,
                                zoom_total_count,
                            )
                        );
                        if self.is_table_view()
                            && self
                                .app
                                .flamegraph()
                                .ordered_stacks
                                .search_pattern_ignored_because_of_no_match
                        {
                            match_text += " (no match; showing all)";
                        }
                        let match_text = format!("{:width$}", match_text, width = width as usize,);
                        lines.push(("Match", Line::from(match_text)));
                    }
                }
                let selected_text = format!(
                    "{} {}",
                    self.app.flamegraph().get_stack_short_name_from_info(stack),
                    Self::get_count_stats_str(
                        None,
                        stack.total_count,
                        root_total_count,
                        zoom_total_count
                    ),
                );
                let status_text = format!("{:width$}", selected_text, width = width as usize,);
                if self.is_flamegraph_view() {
                    lines.push(("Selected", Line::from(status_text)));
                }
                if self.app.debug {
                    let elapsed_str = format!(
                        "Debug: {}",
                        self.app
                            .elapsed
                            .iter()
                            .map(|(k, v)| format!("{}:{:.2}ms", k, v.as_micros() as f64 / 1000.0))
                            .collect::<Vec<String>>()
                            .join(" ")
                    );
                    lines.push(("Debug", Line::from(elapsed_str)));
                }
                if let Some(transient_message) = &self.app.transient_message {
                    lines.push(("Info", Line::from(transient_message.as_str())));
                }
                lines
            }
            None => vec![("Info", Line::from("No stack selected"))],
        }
    }

    fn get_count_stats_str(
        name: Option<&str>,
        count: u64,
        total_count: u64,
        zoomed_total_count: Option<u64>,
    ) -> String {
        format!(
            "[{}{} samples, {:.2}% of all{}]",
            name.map(|n| format!("{}: ", n)).unwrap_or_default(),
            count,
            (count as f64 / total_count as f64) * 100.0,
            if let Some(zoomed_total_count) = zoomed_total_count {
                format!(
                    ", {:.2}% of zoomed",
                    (count as f64 / zoomed_total_count as f64) * 100.0
                )
            } else {
                "".to_string()
            }
        )
    }

    fn view_kind(&self) -> ViewKind {
        self.app.flamegraph_view.state.view_kind
    }

    fn is_table_view(&self) -> bool {
        self.view_kind() == ViewKind::Table
    }

    fn is_flamegraph_view(&self) -> bool {
        self.view_kind() == ViewKind::FlameGraph
    }
}

struct HelpTags {
    tags: Vec<(&'static str, &'static str)>,
    default: Vec<(&'static str, &'static str)>,
}

impl HelpTags {
    fn new() -> Self {
        Self {
            tags: vec![],
            default: vec![("r", "reset"), ("tab", "switch view"), ("q", "quit")],
        }
    }

    fn add(&mut self, tag: &'static str, description: &'static str) {
        self.tags.push((tag, description));
    }

    fn get_line(&self) -> Line<'static> {
        let mut spans = vec![Span::from(" ")];
        for (tag, description) in self.tags.iter().chain(self.default.iter()) {
            spans.push(Span::from("["));
            spans.push(Span::styled(
                *tag,
                Style::default().add_modifier(Modifier::BOLD).yellow(),
            ));
            spans.push(Span::from(format!(": {}", description)));
            spans.push(Span::from("] "));
        }
        Line::from(spans)
    }
}

/// Renders the user interface widgets.
pub fn render(app: &mut App, frame: &mut Frame) {
    let profiler_widget = ProfilerWidget::new(app);
    let mut profiler_state = ProfilerWidgetState::default();
    frame.render_stateful_widget(profiler_widget, frame.area(), &mut profiler_state);
    app.flamegraph_view
        .set_frame_height(profiler_state.frame_height);
    app.flamegraph_view
        .set_frame_width(profiler_state.frame_width);
    app.add_elapsed("render", profiler_state.render_time);
    if let Some(input_buffer) = &mut app.input_buffer {
        input_buffer.cursor = profiler_state.cursor_position;
    }
}