//! Server-authored topology geometry. Coordinates survive incremental updates;
//! changing the coordinate space requires a new, explicitly published layout.

mod details;
mod health;
mod layout;
mod spatial;
mod tiles;

pub use details::{
    AggregateSelection, BundleCursor, BundleInfo, BundlePage, DETAIL_EDGE_LIMIT,
    DETAIL_MEMBER_LIMIT, DETAIL_NODE_LIMIT, DetailCursor, DetailPage, DetailRelation, DetailScope,
    MAX_SELECTION_BYTES, RELATION_CANDIDATE_LIMIT, RelationCursor, RelationPage, SelectedRelation,
    TileSelection,
};
pub use health::{
    DeviceIdsCursor, DeviceIdsPage, GlyphHealth, HEALTH_BATCH_LIMIT, HealthApply, HealthCounts,
    HealthIndex, HealthInfo, HealthObservation, HealthSnapshot, HealthState, TileHealth,
};
pub use layout::reconcile;
pub use tiles::{Budget, Glyph, GlyphKind, Tile, TileEdge, TileProfile, World};

/// Integers in this extent are exactly representable by Float32.
pub const WORLD_EXTENT: u32 = 1 << 24;
pub const ALGORITHM: &str = "hierarchical-morton-v1";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    pub id: String,
    pub label: String,
    /// Backbone, infrastructure, endpoint, in increasing order.
    pub importance: u8,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Relation {
    pub id: String,
    pub source: String,
    pub target: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Cell {
    pub z: u8,
    pub x: u32,
    pub y: u32,
}

impl Cell {
    pub fn new(z: u8, x: u32, y: u32) -> Result<Self, Error> {
        if z > 24 || x >= 1u32 << z || y >= 1u32 << z {
            return Err(Error::InvalidCell);
        }
        Ok(Self { z, x, y })
    }

    pub fn width(self) -> u32 {
        WORLD_EXTENT >> self.z
    }

    pub fn origin(self) -> (u32, u32) {
        (self.x * self.width(), self.y * self.width())
    }

    pub fn contains(self, x: u32, y: u32) -> bool {
        let (left, top) = self.origin();
        x >= left && y >= top && x - left < self.width() && y - top < self.width()
    }

    pub fn ancestor(self, z: u8) -> Self {
        assert!(z <= self.z);
        Self {
            z,
            x: self.x >> (self.z - z),
            y: self.y >> (self.z - z),
        }
    }

    pub fn at_point(z: u8, x: u32, y: u32) -> Result<Self, Error> {
        if x >= WORLD_EXTENT || y >= WORLD_EXTENT || z > 24 {
            return Err(Error::InvalidCell);
        }
        Self::new(z, x >> (24 - z), y >> (24 - z))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Position {
    pub id: String,
    pub label: String,
    pub x: u32,
    pub y: u32,
    pub min_zoom: u8,
    pub parent_id: Option<String>,
    pub component_id: String,
    pub component: Cell,
    pub placement_depth: u8,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    InvalidCell,
    InvalidIdentity,
    DuplicateIdentity(String),
    MissingEndpoint(String),
    InvalidPosition(String),
    ExhaustedWorld,
    InvalidBudget,
    DetailNotFound,
    InvalidDetailCursor,
    StaleDetailRevision,
    InvalidHealthUpdate,
    SelectionBudgetExceeded,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for Error {}
