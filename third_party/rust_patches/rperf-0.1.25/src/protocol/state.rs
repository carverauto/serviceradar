// rperf/src/protocol/state.rs
pub trait RunState {
    fn is_alive(&self) -> bool;
}
