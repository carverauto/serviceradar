/// Component type for edge onboarding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComponentType {
    Gateway,
    Agent,
    Checker,
    Sync,
}

impl ComponentType {
    pub fn as_str(&self) -> &'static str {
        match self {
            ComponentType::Gateway => "gateway",
            ComponentType::Agent => "agent",
            ComponentType::Checker => "checker",
            ComponentType::Sync => "sync",
        }
    }

    pub fn config_filename(&self) -> &'static str {
        match self {
            ComponentType::Gateway => "gateway.json",
            ComponentType::Agent => "agent.json",
            ComponentType::Checker => "checker.json",
            ComponentType::Sync => "sync.json",
        }
    }
}