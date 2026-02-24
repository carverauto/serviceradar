use rustler::NifMap;

#[derive(Debug, Clone, NifMap)]
pub struct CausalStateReasonRow {
    pub state: u8,
    pub reason: String,
    pub root_index: i64,
    pub parent_index: i64,
    pub hop_distance: i64,
}
