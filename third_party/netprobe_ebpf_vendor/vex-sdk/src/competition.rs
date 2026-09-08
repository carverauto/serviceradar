//! Competition Control

unsafe extern "system" {
    pub fn vexCompetitionStatus() -> u32;
    pub fn vexCompetitionControl(data: u32);
}
