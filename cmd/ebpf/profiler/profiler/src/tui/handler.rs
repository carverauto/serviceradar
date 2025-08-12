use crate::tui::app::{App, AppResult, InputBuffer};
use crate::tui::flame::SortColumn;
use crate::tui::view::ViewKind;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

pub fn handle_key_events(key_event: KeyEvent, app: &mut App) -> AppResult<()> {
    // Handle input buffer mode (search input)
    if app.input_buffer.is_some() {
        return handle_input_mode(key_event, app);
    }

    // Normal navigation mode
    match key_event.code {
        // Quit
        KeyCode::Char('q') => app.quit(),
        
        // Global commands
        KeyCode::Char('r') => {
            app.flamegraph_view.reset_zoom();
            app.clear_transient_message();
        }
        KeyCode::Tab => {
            app.flamegraph_view.toggle_view_mode();
            app.clear_transient_message();
        }
        KeyCode::Char('d') if key_event.modifiers.contains(KeyModifiers::CONTROL) => {
            app.toggle_debug();
        }
        
        // Live profiling controls
        KeyCode::Char('z') if app.live_mode => {
            app.toggle_freeze();
        }
        
        // Search commands
        KeyCode::Char('/') => {
            start_search_input(app);
        }
        KeyCode::Char('c') => {
            app.flamegraph_view.clear_search_pattern().ok();
            app.clear_transient_message();
        }
        KeyCode::Char('#') => {
            app.search_selected();
        }
        KeyCode::Char('n') => {
            app.flamegraph_view.next_search_result();
        }
        KeyCode::Char('N') => {
            app.flamegraph_view.prev_search_result();
        }
        
        // View-specific navigation
        _ => handle_view_specific_keys(key_event, app)?,
    }
    
    Ok(())
}

fn handle_input_mode(key_event: KeyEvent, app: &mut App) -> AppResult<()> {
    let input_buffer = app.input_buffer.as_mut().unwrap();
    
    match key_event.code {
        KeyCode::Enter => {
            // Execute search
            let pattern = input_buffer.buffer.clone();
            app.input_buffer = None;
            
            if !pattern.is_empty() {
                if let Err(e) = app.flamegraph_view.set_search_pattern(&pattern, false) {
                    app.set_transient_message(&format!("Search error: {}", e));
                }
            }
        }
        KeyCode::Esc => {
            // Cancel search
            app.input_buffer = None;
        }
        KeyCode::Backspace => {
            // Remove character
            input_buffer.buffer.pop();
        }
        KeyCode::Char(c) => {
            // Add character
            input_buffer.buffer.push(c);
        }
        _ => {}
    }
    
    Ok(())
}

fn handle_view_specific_keys(key_event: KeyEvent, app: &mut App) -> AppResult<()> {
    match app.flamegraph_view.state.view_kind {
        ViewKind::FlameGraph => handle_flamegraph_keys(key_event, app),
        ViewKind::Table => handle_table_keys(key_event, app),
    }
}

fn handle_flamegraph_keys(key_event: KeyEvent, app: &mut App) -> AppResult<()> {
    match key_event.code {
        // Navigation
        KeyCode::Up | KeyCode::Char('k') => {
            app.flamegraph_view.navigate_up();
        }
        KeyCode::Down | KeyCode::Char('j') => {
            app.flamegraph_view.navigate_down();
        }
        KeyCode::Left | KeyCode::Char('h') => {
            app.flamegraph_view.navigate_left();
        }
        KeyCode::Right | KeyCode::Char('l') => {
            app.flamegraph_view.navigate_right();
        }
        
        // Scrolling
        KeyCode::Char('f') => {
            app.flamegraph_view.scroll_forward();
        }
        KeyCode::Char('b') => {
            app.flamegraph_view.scroll_backward();
        }
        KeyCode::PageDown => {
            app.flamegraph_view.scroll_forward();
        }
        KeyCode::PageUp => {
            app.flamegraph_view.scroll_backward();
        }
        
        // Zooming
        KeyCode::Enter => {
            if !app.flamegraph_view.is_root_selected() {
                let selected = app.flamegraph_view.state.selected;
                app.flamegraph_view.zoom_to_stack(selected);
            }
        }
        KeyCode::Esc | KeyCode::Backspace => {
            app.flamegraph_view.zoom_out();
        }
        
        _ => {}
    }
    
    Ok(())
}

fn handle_table_keys(key_event: KeyEvent, app: &mut App) -> AppResult<()> {
    match key_event.code {
        // Navigation
        KeyCode::Up | KeyCode::Char('k') => {
            app.flamegraph_view.navigate_up();
        }
        KeyCode::Down | KeyCode::Char('j') => {
            app.flamegraph_view.navigate_down();
        }
        
        // Scrolling
        KeyCode::Char('f') => {
            app.flamegraph_view.scroll_forward();
        }
        KeyCode::Char('b') => {
            app.flamegraph_view.scroll_backward();
        }
        KeyCode::PageDown => {
            app.flamegraph_view.scroll_forward();
        }
        KeyCode::PageUp => {
            app.flamegraph_view.scroll_backward();
        }
        
        // Sorting
        KeyCode::Char('1') => {
            app.flamegraph_view.sort_table(SortColumn::Total);
        }
        KeyCode::Char('2') => {
            app.flamegraph_view.sort_table(SortColumn::Own);
        }
        
        // Search selected row
        KeyCode::Enter => {
            app.search_selected_row();
        }
        
        _ => {}
    }
    
    Ok(())
}

fn start_search_input(app: &mut App) {
    app.input_buffer = Some(InputBuffer {
        buffer: String::new(),
        cursor: None,
    });
}