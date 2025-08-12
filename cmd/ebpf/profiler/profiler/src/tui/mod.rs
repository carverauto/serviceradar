pub mod app;
pub mod flame;
pub mod handler;
pub mod ui;
pub mod view;

pub use app::{App, AppResult};
pub use handler::handle_key_events;
pub use ui::render;