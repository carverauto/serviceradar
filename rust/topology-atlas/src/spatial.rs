//! Segment intersection index. Endpoint ownership alone misses a line passing
//! through a tile and makes every cross-component line a root-level scan.

use crate::Cell;

#[derive(Clone, Copy, Debug)]
pub(crate) struct Point {
    pub x: u32,
    pub y: u32,
}

#[derive(Clone, Copy)]
pub(crate) struct Line {
    pub source: u32,
    pub target: u32,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Clip {
    pub start: f64,
    pub end: f64,
    pub source: (f64, f64),
    pub target: (f64, f64),
}

#[derive(Clone, Copy)]
struct Bounds {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
}

impl Bounds {
    fn tile(cell: Cell) -> Self {
        let (left, top) = cell.origin();
        Self {
            left,
            top,
            right: left + cell.width(),
            bottom: top + cell.width(),
        }
    }

    fn overlaps(self, other: Self) -> bool {
        self.left <= other.right
            && self.right >= other.left
            && self.top <= other.bottom
            && self.bottom >= other.top
    }

    fn add(&mut self, point: Point) {
        self.left = self.left.min(point.x);
        self.top = self.top.min(point.y);
        self.right = self.right.max(point.x);
        self.bottom = self.bottom.max(point.y);
    }
}

struct Branch {
    bounds: Bounds,
    children: Option<(usize, usize)>,
    range: std::ops::Range<usize>,
}

pub(crate) struct SegmentIndex {
    points: Vec<Point>,
    lines: Vec<Line>,
    ordered: Vec<u32>,
    branches: Vec<Branch>,
}

impl SegmentIndex {
    pub(crate) fn new(points: Vec<Point>, lines: Vec<Line>) -> Self {
        let mut index = Self {
            ordered: (0..lines.len() as u32).collect(),
            points,
            lines,
            branches: Vec::new(),
        };
        if !index.lines.is_empty() {
            index.partition(0..index.lines.len());
        }
        index
    }

    pub(crate) fn retain(&mut self, mut include: impl FnMut(u32) -> bool) {
        self.ordered.retain(|&i| include(i));
        self.branches.clear();
        if !self.ordered.is_empty() {
            self.partition(0..self.ordered.len());
        }
    }

    fn partition(&mut self, range: std::ops::Range<usize>) -> usize {
        let mut bounds = Bounds {
            left: u32::MAX,
            top: u32::MAX,
            right: 0,
            bottom: 0,
        };
        for &i in &self.ordered[range.clone()] {
            let line = self.lines[i as usize];
            bounds.add(self.points[line.source as usize]);
            bounds.add(self.points[line.target as usize]);
        }
        let branch = self.branches.len();
        self.branches.push(Branch {
            bounds,
            range: range.clone(),
            children: None,
        });
        if range.len() > 8 {
            let horizontal = bounds.right - bounds.left >= bounds.bottom - bounds.top;
            let middle = range.start + range.len() / 2;
            let points = &self.points;
            let lines = &self.lines;
            self.ordered[range.clone()].select_nth_unstable_by_key(range.len() / 2, |&i| {
                let line = lines[i as usize];
                let a = points[line.source as usize];
                let b = points[line.target as usize];
                (if horizontal { a.x + b.x } else { a.y + b.y }, i)
            });
            let left = self.partition(range.start..middle);
            let right = self.partition(middle..range.end);
            self.branches[branch].children = Some((left, right));
        }
        branch
    }

    /// Returns tested candidate count and whether the complete intersection set
    /// was visited. The consumer may stop when a budget forces generalization.
    pub(crate) fn visit(
        &self,
        cell: Cell,
        mut visitor: impl FnMut(u32, Clip) -> bool,
    ) -> (usize, bool) {
        if self.branches.is_empty() {
            return (0, true);
        }
        let bounds = Bounds::tile(cell);
        let mut pending = vec![0];
        let mut candidates = 0;
        while let Some(i) = pending.pop() {
            let branch = &self.branches[i];
            if !branch.bounds.overlaps(bounds) {
                continue;
            }
            if let Some((left, right)) = branch.children {
                pending.push(right);
                pending.push(left);
            } else {
                for &line_id in &self.ordered[branch.range.clone()] {
                    candidates += 1;
                    let line = self.lines[line_id as usize];
                    if let Some(clipped) = clip(
                        self.points[line.source as usize],
                        self.points[line.target as usize],
                        bounds,
                    ) && !visitor(line_id, clipped)
                    {
                        return (candidates, false);
                    }
                }
            }
        }
        (candidates, true)
    }

    /// Page by raw index position, including rejected clips. Both returned rows
    /// and candidate work are bounded; empty pages still advance or finish.
    pub(crate) fn visit_page(
        &self,
        cell: Cell,
        offset: usize,
        candidate_limit: usize,
        mut visitor: impl FnMut(u32, Clip) -> bool,
    ) -> (usize, Option<usize>) {
        if self.branches.is_empty() {
            return (0, None);
        }
        let bounds = Bounds::tile(cell);
        let mut pending = vec![0];
        let mut candidates = 0;
        while let Some(i) = pending.pop() {
            let branch = &self.branches[i];
            if branch.range.end <= offset || !branch.bounds.overlaps(bounds) {
                continue;
            }
            if let Some((left, right)) = branch.children {
                pending.push(right);
                pending.push(left);
                continue;
            }
            for raw in branch.range.start.max(offset)..branch.range.end {
                if candidates == candidate_limit {
                    return (candidates, Some(raw));
                }
                candidates += 1;
                let line_id = self.ordered[raw];
                let line = self.lines[line_id as usize];
                if let Some(clipped) = clip(
                    self.points[line.source as usize],
                    self.points[line.target as usize],
                    bounds,
                ) && !visitor(line_id, clipped)
                {
                    return (
                        candidates,
                        (raw + 1 < self.ordered.len()).then_some(raw + 1),
                    );
                }
            }
        }
        (candidates, None)
    }
}

/// Exact segment parameters keep corner ownership independent of floating-point
/// roundoff. Products use i128 so classification also remains safe if a caller
/// constructs a Point outside the supported 24-bit world before validation.
#[derive(Clone, Copy)]
struct Parameter {
    numerator: i64,
    denominator: i64,
}

impl Parameter {
    const ZERO: Self = Self {
        numerator: 0,
        denominator: 1,
    };
    const ONE: Self = Self {
        numerator: 1,
        denominator: 1,
    };

    fn new(numerator: i64, denominator: i64) -> Self {
        if denominator < 0 {
            Self {
                numerator: -numerator,
                denominator: -denominator,
            }
        } else {
            Self {
                numerator,
                denominator,
            }
        }
    }

    fn compare(self, other: Self) -> std::cmp::Ordering {
        (i128::from(self.numerator) * i128::from(other.denominator))
            .cmp(&(i128::from(other.numerator) * i128::from(self.denominator)))
    }

    fn value(self) -> f64 {
        self.numerator as f64 / self.denominator as f64
    }
}

fn contains(bounds: Bounds, point: Point) -> bool {
    point.x >= bounds.left
        && point.x < bounds.right
        && point.y >= bounds.top
        && point.y < bounds.bottom
}

fn portal(a: Point, b: Point, at: Parameter, bounds: Bounds) -> Option<(f64, f64)> {
    let denominator = i128::from(at.denominator);
    let numerator = i128::from(at.numerator);
    let x = i128::from(a.x) * denominator + (i128::from(b.x) - i128::from(a.x)) * numerator;
    let y = i128::from(a.y) * denominator + (i128::from(b.y) - i128::from(a.y)) * numerator;
    let vertical = if x == i128::from(bounds.left) * denominator {
        Some(bounds.left)
    } else if x == i128::from(bounds.right) * denominator {
        Some(bounds.right)
    } else {
        None
    };
    let horizontal = if y == i128::from(bounds.top) * denominator {
        Some(bounds.top)
    } else if y == i128::from(bounds.bottom) * denominator {
        Some(bounds.bottom)
    } else {
        None
    };
    let along = at.value();
    match (vertical, horizontal) {
        (Some(x), Some(y)) => Some((f64::from(x), f64::from(y))),
        (Some(x), None) => Some((
            f64::from(x),
            f64::from(a.y) + (f64::from(b.y) - f64::from(a.y)) * along,
        )),
        (None, Some(y)) => Some((
            f64::from(a.x) + (f64::from(b.x) - f64::from(a.x)) * along,
            f64::from(y),
        )),
        (None, None) => None,
    }
}

fn clip(a: Point, b: Point, bounds: Bounds) -> Option<Clip> {
    let (owns_source, owns_target) = (contains(bounds, a), contains(bounds, b));
    let source_point = (f64::from(a.x), f64::from(a.y));
    let target_point = (f64::from(b.x), f64::from(b.y));
    if a.x == b.x && a.y == b.y {
        // The caller folds an owned self-loop into its internal-relation count.
        return owns_source.then_some(Clip {
            start: 0.0,
            end: 1.0,
            source: source_point,
            target: target_point,
        });
    }

    let (dx, dy) = (
        i64::from(b.x) - i64::from(a.x),
        i64::from(b.y) - i64::from(a.y),
    );
    // A line lying on a shared right/bottom boundary belongs to its neighbor.
    // Lines crossing that boundary still terminate at the same shared portal.
    if (dx == 0 && a.x == bounds.right) || (dy == 0 && a.y == bounds.bottom) {
        return None;
    }
    let (mut start, mut end) = (Parameter::ZERO, Parameter::ONE);
    for (direction, distance) in [
        (-dx, i64::from(a.x) - i64::from(bounds.left)),
        (dx, i64::from(bounds.right) - i64::from(a.x)),
        (-dy, i64::from(a.y) - i64::from(bounds.top)),
        (dy, i64::from(bounds.bottom) - i64::from(a.y)),
    ] {
        if direction == 0 {
            if distance < 0 {
                return None;
            }
        } else {
            let at = Parameter::new(distance, direction);
            if direction < 0 && at.compare(start).is_gt() {
                start = at;
            } else if direction > 0 && at.compare(end).is_lt() {
                end = at;
            }
        }
    }
    let order = start.compare(end);
    if order.is_gt() || (order.is_eq() && !owns_source && !owns_target) {
        return None;
    }

    Some(Clip {
        start: start.value(),
        end: end.value(),
        source: if owns_source {
            source_point
        } else {
            portal(a, b, start, bounds)?
        },
        target: if owns_target {
            target_point
        } else {
            portal(a, b, end, bounds)?
        },
    })
}
