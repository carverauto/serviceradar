use crate::models::*;
use itertools::Itertools;
use std::borrow::Cow;
use std::fmt::{Display, Formatter};
use std::hash::{Hash, Hasher};
use std::iter::FromIterator;
use std::marker::PhantomData;
use std::mem::discriminant;

/// Enum of AS path segment.
#[derive(Debug, Clone)]
pub enum AsPathSegment {
    AsSequence(Vec<Asn>),
    AsSet(Vec<Asn>),
    ConfedSequence(Vec<Asn>),
    ConfedSet(Vec<Asn>),
}

impl AsPathSegment {
    /// Shorthand for creating an `AsSequence` segment.
    pub fn sequence<S: AsRef<[u32]>>(seq: S) -> Self {
        AsPathSegment::AsSequence(seq.as_ref().iter().copied().map_into().collect())
    }

    /// Shorthand for creating an `AsSet` segment.
    pub fn set<S: AsRef<[u32]>>(seq: S) -> Self {
        AsPathSegment::AsSet(seq.as_ref().iter().copied().map_into().collect())
    }

    /// Get the number of ASNs this segment adds to the route. For the number of ASNs within the
    /// segment use [AsPathSegment::len] instead.
    pub fn route_len(&self) -> usize {
        match self {
            AsPathSegment::AsSequence(v) => v.len(),
            AsPathSegment::AsSet(_) => 1,
            AsPathSegment::ConfedSequence(_) | AsPathSegment::ConfedSet(_) => 0,
        }
    }

    /// Ge the total number of ASNs within this segment. For the number of ASNs this segment adds to
    /// a packet's route, use [AsPathSegment::route_len] instead.
    pub fn len(&self) -> usize {
        self.as_ref().len()
    }

    /// Returns true if this segment has a length of 0.
    pub fn is_empty(&self) -> bool {
        self.as_ref().is_empty()
    }

    /// Get an iterator over the ASNs within this path segment
    pub fn iter(&self) -> <&'_ Self as IntoIterator>::IntoIter {
        self.into_iter()
    }

    /// Get a mutable iterator over the ASNs within this path segment
    pub fn iter_mut(&mut self) -> <&'_ mut Self as IntoIterator>::IntoIter {
        self.into_iter()
    }

    /// Gets if a segment represents the local members of an autonomous system confederation.
    /// Shorthand for `matches!(x, AsPathSegment::ConfedSequence(_) | AsPathSegment::ConfedSet(_))`.
    ///
    /// <https://datatracker.ietf.org/doc/html/rfc3065#section-5>
    pub fn is_confed(&self) -> bool {
        matches!(
            self,
            AsPathSegment::ConfedSequence(_) | AsPathSegment::ConfedSet(_)
        )
    }

    /// Merge two [AsPathSegment]s in place and return if the merge was successful.
    ///
    /// See [AsPath::coalesce] for more information.
    fn merge_in_place(&mut self, other: &mut Self) -> bool {
        use AsPathSegment::*;

        match (self, other) {
            (AsSequence(x), AsSequence(y)) | (ConfedSequence(x), ConfedSequence(y)) => {
                x.extend_from_slice(y);
                true
            }
            (x @ (AsSequence(_) | ConfedSequence(_)), y) if x.is_empty() => {
                std::mem::swap(x, y);
                true
            }
            (_, AsSequence(y) | ConfedSequence(y)) if y.is_empty() => true,
            _ => false,
        }
    }

    /// A much more aggressive version of [AsPathSegment::merge_in_place] which de-duplicates and
    /// converts sets with only 1 ASN to sequences.
    ///
    /// See [AsPath::dedup_coalesce] for more information.
    fn dedup_merge_in_place(&mut self, other: &mut Self) -> bool {
        use AsPathSegment::*;

        other.dedup();
        match (self, other) {
            (AsSequence(x), AsSequence(y)) | (ConfedSequence(x), ConfedSequence(y)) => {
                x.extend_from_slice(y);
                x.dedup();
                true
            }
            (x @ (AsSequence(_) | ConfedSequence(_)), y) if x.is_empty() => {
                std::mem::swap(x, y);
                true
            }
            (_, AsSequence(y) | ConfedSequence(y)) if y.is_empty() => true,
            _ => false,
        }
    }

    /// Deduplicate ASNs in this path segment. Additionally, sets are sorted and may be converted to
    /// sequences if they only have a single element.
    ///
    /// See [AsPath::dedup_coalesce] for more information.
    fn dedup(&mut self) {
        match self {
            AsPathSegment::AsSequence(x) | AsPathSegment::ConfedSequence(x) => x.dedup(),
            AsPathSegment::AsSet(x) => {
                x.sort_unstable();
                x.dedup();
                if x.len() == 1 {
                    *self = AsPathSegment::AsSequence(std::mem::take(x));
                }
            }
            AsPathSegment::ConfedSet(x) => {
                x.sort_unstable();
                x.dedup();
                if x.len() == 1 {
                    *self = AsPathSegment::ConfedSequence(std::mem::take(x));
                }
            }
        }
    }

    pub fn to_u32_vec_opt(&self, dedup: bool) -> Option<Vec<u32>> {
        match self {
            AsPathSegment::AsSequence(v) => {
                let mut p: Vec<u32> = v.iter().map(|asn| (*asn).into()).collect();
                if dedup {
                    p.dedup();
                }
                Some(p)
            }
            AsPathSegment::AsSet(v) => {
                if v.len() == 1 {
                    // if the segment is an AS_SET and the length is 1, we can consider this a
                    // single ASN path vector
                    Some(vec![v[0].into()])
                } else {
                    None
                }
            }
            _ => None,
        }
    }
}

impl IntoIterator for AsPathSegment {
    type Item = Asn;
    type IntoIter = std::vec::IntoIter<Asn>;

    fn into_iter(self) -> Self::IntoIter {
        let (AsPathSegment::AsSequence(x)
        | AsPathSegment::AsSet(x)
        | AsPathSegment::ConfedSequence(x)
        | AsPathSegment::ConfedSet(x)) = self;
        x.into_iter()
    }
}

impl<'a> IntoIterator for &'a AsPathSegment {
    type Item = &'a Asn;
    type IntoIter = std::slice::Iter<'a, Asn>;

    fn into_iter(self) -> Self::IntoIter {
        let (AsPathSegment::AsSequence(x)
        | AsPathSegment::AsSet(x)
        | AsPathSegment::ConfedSequence(x)
        | AsPathSegment::ConfedSet(x)) = self;
        x.iter()
    }
}

impl<'a> IntoIterator for &'a mut AsPathSegment {
    type Item = &'a mut Asn;
    type IntoIter = std::slice::IterMut<'a, Asn>;

    fn into_iter(self) -> Self::IntoIter {
        let (AsPathSegment::AsSequence(x)
        | AsPathSegment::AsSet(x)
        | AsPathSegment::ConfedSequence(x)
        | AsPathSegment::ConfedSet(x)) = self;
        x.iter_mut()
    }
}

impl AsRef<[Asn]> for AsPathSegment {
    fn as_ref(&self) -> &[Asn] {
        let (AsPathSegment::AsSequence(x)
        | AsPathSegment::AsSet(x)
        | AsPathSegment::ConfedSequence(x)
        | AsPathSegment::ConfedSet(x)) = self;
        x
    }
}

impl Hash for AsPathSegment {
    fn hash<H: Hasher>(&self, state: &mut H) {
        // Hash the discriminant since we do not differentiate between confederation segments
        discriminant(self).hash(state);

        let set = match self {
            AsPathSegment::AsSequence(x) | AsPathSegment::ConfedSequence(x) => {
                return x.hash(state)
            }
            AsPathSegment::AsSet(x) | AsPathSegment::ConfedSet(x) => x,
        };

        // FIXME: Once is_sorted is stabilized, call it first to determine if sorting is required
        if set.len() <= 32 {
            let mut buffer = [Asn::new_32bit(0); 32];
            set.iter()
                .zip(&mut buffer)
                .for_each(|(asn, buffer)| *buffer = *asn);

            let slice = &mut buffer[..set.len()];
            slice.sort_unstable();
            Asn::hash_slice(slice, state);
            return;
        }

        // Fallback to allocating a Vec on the heap to sort
        set.iter().sorted().for_each(|x| x.hash(state));
    }
}

/// Check for equality of two path segments.
/// ```rust
/// # use bgpkit_parser::models::AsPathSegment;
/// let a = AsPathSegment::sequence([1, 2, 3]);
/// let b = AsPathSegment::set([1, 2, 3]);
///
/// // Sequences must be identical to be considered equivalent
/// assert_eq!(a, AsPathSegment::sequence([1, 2, 3]));
/// assert_ne!(a, AsPathSegment::sequence([1, 2, 3, 3]));
///
/// // Sets may be reordered, but must contain exactly the same ASNs.
/// assert_eq!(b, AsPathSegment::set([3, 1, 2]));
/// assert_ne!(b, AsPathSegment::set([1, 2, 3, 3]));
/// ```
impl PartialEq for AsPathSegment {
    fn eq(&self, other: &Self) -> bool {
        let (x, y) = match (self, other) {
            (AsPathSegment::AsSequence(x), AsPathSegment::AsSequence(y))
            | (AsPathSegment::ConfedSequence(x), AsPathSegment::ConfedSequence(y)) => {
                return x == y
            }
            (AsPathSegment::AsSet(x), AsPathSegment::AsSet(y))
            | (AsPathSegment::ConfedSet(x), AsPathSegment::ConfedSet(y)) => (x, y),
            _ => return false,
        };

        // Attempt to exit early
        if x.len() != y.len() {
            return false;
        } else if x == y {
            return true;
        }

        if x.len() <= 32 {
            let mut x_buffer = [Asn::new_32bit(0); 32];
            let mut y_buffer = [Asn::new_32bit(0); 32];
            x.iter()
                .zip(&mut x_buffer)
                .for_each(|(asn, buffer)| *buffer = *asn);
            y.iter()
                .zip(&mut y_buffer)
                .for_each(|(asn, buffer)| *buffer = *asn);

            x_buffer[..x.len()].sort_unstable();
            y_buffer[..y.len()].sort_unstable();
            return x_buffer[..x.len()] == y_buffer[..y.len()];
        }

        x.iter()
            .sorted()
            .zip(y.iter().sorted())
            .all(|(a, b)| a == b)
    }
}

impl Eq for AsPathSegment {}

/// This is not a perfect solution since it is theoretically possible that a path could be created
/// with more variations than a u64. That being said, the chances of such a thing occurring are
/// essentially non-existent unless a BGP peer begins announcing maliciously constructed paths.
struct AsPathNumberedRouteIter<'a> {
    path: &'a [AsPathSegment],
    index: usize,
    route_num: u64,
}

impl Iterator for AsPathNumberedRouteIter<'_> {
    type Item = Asn;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            match self.path.first()? {
                AsPathSegment::AsSequence(x) => match x.get(self.index) {
                    None => {
                        self.index = 0;
                        self.path = &self.path[1..];
                    }
                    Some(asn) => {
                        self.index += 1;
                        return Some(*asn);
                    }
                },
                AsPathSegment::AsSet(x) => {
                    self.path = &self.path[1..];
                    if x.is_empty() {
                        return Some(Asn::RESERVED);
                    }

                    let asn = x[(self.route_num % x.len() as u64) as usize];
                    self.route_num /= x.len() as u64;
                    return Some(asn);
                }
                _ => self.path = &self.path[1..],
            }
        }
    }
}

pub struct AsPathRouteIter<'a, D> {
    path: Cow<'a, [AsPathSegment]>,
    route_num: u64,
    total_routes: u64,
    _phantom: PhantomData<D>,
}

impl<D> Iterator for AsPathRouteIter<'_, D>
where
    D: FromIterator<Asn>,
{
    type Item = D;

    fn next(&mut self) -> Option<Self::Item> {
        if self.route_num >= self.total_routes {
            return None;
        }

        // Attempt to speed up what is by far the most common case (a path of a single sequence)
        if self.route_num == 0 && self.path.len() == 1 {
            if let AsPathSegment::AsSequence(sequence) = &self.path[0] {
                let route = D::from_iter(sequence.iter().copied());
                self.route_num += 1;
                return Some(route);
            }
        }

        let route_asn_iter = AsPathNumberedRouteIter {
            path: self.path.as_ref(),
            index: 0,
            route_num: self.route_num,
        };

        self.route_num += 1;
        Some(D::from_iter(route_asn_iter))
    }
}

#[derive(Debug, PartialEq, Clone, Eq, Default, Hash)]
pub struct AsPath {
    pub segments: Vec<AsPathSegment>,
}

// Define iterator type aliases. The storage mechanism and by extension the iterator types may
// change later, but these types should remain consistent.
pub type SegmentIter<'a> = std::slice::Iter<'a, AsPathSegment>;
pub type SegmentIterMut<'a> = std::slice::IterMut<'a, AsPathSegment>;
pub type SegmentIntoIter = std::vec::IntoIter<AsPathSegment>;

impl AsPath {
    pub fn new() -> AsPath {
        AsPath { segments: vec![] }
    }

    /// Shorthand for creating an `AsPath` consisting of a single `AsSequence` segment.
    pub fn from_sequence<S: AsRef<[u32]>>(seq: S) -> Self {
        let segment = AsPathSegment::AsSequence(seq.as_ref().iter().copied().map_into().collect());

        AsPath {
            segments: vec![segment],
        }
    }

    pub fn from_segments(segments: Vec<AsPathSegment>) -> AsPath {
        AsPath { segments }
    }

    /// Adds a new segment to the end of the path. This will change the origin of the path. No
    /// validation or merging the segment is performed during this step.
    pub fn append_segment(&mut self, segment: AsPathSegment) {
        self.segments.push(segment);
    }

    /// Check if the path is empty. Note that a non-empty path may have a route length of 0 due to
    /// empty segments or confederation segments.
    pub fn is_empty(&self) -> bool {
        self.segments.is_empty()
    }

    /// Get the total length of the routes this path represents. For example, if this route
    /// contained a sequence of 5 ASNs followed by a set of 3 ASNs, the total route length would be
    /// 6.
    ///
    /// Confederation segments do not count towards the total route length. This means it is
    /// possible to have a non-empty AsPath with a length of 0.
    pub fn route_len(&self) -> usize {
        self.segments.iter().map(AsPathSegment::route_len).sum()
    }

    /// Get the number of segments that make up this path. For the number of ASNs in routes
    /// represented by this path, use [AsPath::route_len].
    pub fn len(&self) -> usize {
        self.segments.len()
    }

    /// Get the total number of routes this path represents. This function assumes the total number
    /// of route variations can be represented by a u64.
    pub fn num_route_variations(&self) -> u64 {
        let mut variations: u64 = 1;

        for segment in &self.segments {
            if let AsPathSegment::AsSet(x) = segment {
                variations *= x.len() as u64;
            }
        }

        variations
    }

    /// Checks if any segments of this [AsPath] contain the following ASN.
    pub fn contains_asn(&self, x: Asn) -> bool {
        self.iter_segments().flatten().contains(&x)
    }

    /// Coalesce this [AsPath] into the minimum number of segments required without changing the
    /// values along the path. This can be helpful as some BGP servers will prepend additional
    /// segments without coalescing sequences. For de-duplicating see [AsPath::dedup_coalesce].
    ///
    /// Changes applied by this function:
    ///  - Merge adjacent AS_SEQUENCE segments
    ///  - Merge adjacent AS_CONFED_SEQUENCE segments
    ///  - Removing empty AS_SEQUENCE and AS_CONFED_SEQUENCE segments
    ///
    /// ```rust
    /// # use bgpkit_parser::models::{AsPath, AsPathSegment};
    /// let mut a = AsPath::from_segments(vec![
    ///     AsPathSegment::sequence([]),
    ///     AsPathSegment::sequence([1, 2]),
    ///     AsPathSegment::sequence([]),
    ///     AsPathSegment::sequence([2]),
    ///     AsPathSegment::set([2]),
    ///     AsPathSegment::set([5, 3, 3, 2]),
    /// ]);
    ///
    /// let expected = AsPath::from_segments(vec![
    ///     AsPathSegment::sequence([1, 2, 2]),
    ///     AsPathSegment::set([2]),
    ///     AsPathSegment::set([5, 3, 3, 2]),
    /// ]);
    ///
    /// a.coalesce();
    /// assert_eq!(a, expected);
    /// ```
    /// If there is only one segment, no changes will occur. This function will not attempt to
    /// deduplicate sequences or alter sets.
    pub fn coalesce(&mut self) {
        let mut end_index = 0;
        let mut scan_index = 1;

        while scan_index < self.segments.len() {
            let (a, b) = self.segments.split_at_mut(scan_index);
            if !AsPathSegment::merge_in_place(&mut a[end_index], &mut b[0]) {
                end_index += 1;
                self.segments.swap(end_index, scan_index);
            }
            scan_index += 1;
        }

        self.segments.truncate(end_index + 1);
    }

    /// A more aggressive version of [AsPath::coalesce] which also de-duplicates ASNs within this
    /// path and converts sets of a single ASN to sequences. Some BGP servers will prepend their own
    /// ASN multiple times when announcing a path to artificially increase the route length and make
    /// the route seem less less desirable to peers.This function is best suited for use-cases which
    /// only care about transitions between ASes along the path.
    ///
    /// Changes applied by this function:
    ///  - Merge adjacent AS_SEQUENCE segments
    ///  - Merge adjacent AS_CONFED_SEQUENCE segments
    ///  - Removing empty AS_SEQUENCE and AS_CONFED_SEQUENCE segments
    ///  - De-duplicate ASNs in AS_SEQUENCE and AS_CONFED_SEQUENCE segments
    ///  - Sort and de-duplicate ASNs in AS_SET and AS_CONFED_SET segments
    ///  - Convert AS_SET and AS_CONFED_SET segments with exactly 1 element to sequences
    ///
    /// ```rust
    /// # use bgpkit_parser::models::{AsPath, AsPathSegment};
    /// let mut a = AsPath::from_segments(vec![
    ///     AsPathSegment::sequence([1, 2]),
    ///     AsPathSegment::sequence([]),
    ///     AsPathSegment::sequence([2]),
    ///     AsPathSegment::set([2]),
    ///     AsPathSegment::set([5, 3, 3, 2]),
    /// ]);
    ///
    /// let expected = AsPath::from_segments(vec![
    ///     AsPathSegment::sequence([1, 2]),
    ///     AsPathSegment::set([2, 3, 5]),
    /// ]);
    ///
    /// a.dedup_coalesce();
    /// assert_eq!(a, expected);
    /// ```
    pub fn dedup_coalesce(&mut self) {
        if !self.segments.is_empty() {
            self.segments[0].dedup();
        }
        let mut end_index = 0;
        let mut scan_index = 1;

        while scan_index < self.segments.len() {
            let (a, b) = self.segments.split_at_mut(scan_index);
            if !AsPathSegment::dedup_merge_in_place(&mut a[end_index], &mut b[0]) {
                end_index += 1;
                self.segments.swap(end_index, scan_index);
            }
            scan_index += 1;
        }

        self.segments.truncate(end_index + 1);
    }

    /// Checks if two paths correspond to equivalent routes. Unlike `a == b`, this function will
    /// ignore duplicate ASNs by comparing the coalesced versions of each path.
    ///
    /// This is equivalent to [AsPath::eq] after calling [AsPath::dedup_coalesce] on both paths.
    pub fn has_equivalent_routing(&self, other: &Self) -> bool {
        let mut a = self.to_owned();
        let mut b = other.to_owned();

        a.dedup_coalesce();
        b.dedup_coalesce();

        a == b
    }

    /// Get the length of ASN required to store all of the ASNs within this path
    pub fn required_asn_length(&self) -> AsnLength {
        self.iter_segments().flatten().map(Asn::required_len).fold(
            AsnLength::Bits16,
            |a, b| match (a, b) {
                (AsnLength::Bits16, AsnLength::Bits16) => AsnLength::Bits16,
                _ => AsnLength::Bits32,
            },
        )
    }

    pub fn iter_segments(&self) -> SegmentIter<'_> {
        self.segments.iter()
    }

    pub fn iter_segments_mut(&mut self) -> SegmentIterMut<'_> {
        self.segments.iter_mut()
    }

    pub fn into_segments_iter(self) -> SegmentIntoIter {
        self.segments.into_iter()
    }

    /// Gets an iterator over all possible routes this path represents.
    pub fn iter_routes<D>(&self) -> AsPathRouteIter<'_, D>
    where
        D: FromIterator<Asn>,
    {
        AsPathRouteIter {
            path: Cow::Borrowed(&self.segments),
            route_num: 0,
            total_routes: self.num_route_variations(),
            _phantom: PhantomData,
        }
    }

    /// Construct AsPath from AS_PATH and AS4_PATH
    ///
    /// <https://datatracker.ietf.org/doc/html/rfc6793#section-4.2.3>
    ///
    /// ```text
    ///    If the number of AS numbers in the AS_PATH attribute is less than the
    ///    number of AS numbers in the AS4_PATH attribute, then the AS4_PATH
    ///    attribute SHALL be ignored, and the AS_PATH attribute SHALL be taken
    ///    as the AS path information.
    ///
    ///    If the number of AS numbers in the AS_PATH attribute is larger than
    ///    or equal to the number of AS numbers in the AS4_PATH attribute, then
    ///    the AS path information SHALL be constructed by taking as many AS
    ///    numbers and path segments as necessary from the leading part of the
    ///    AS_PATH attribute, and then prepending them to the AS4_PATH attribute
    ///    so that the AS path information has a number of AS numbers identical
    ///    to that of the AS_PATH attribute.  Note that a valid
    ///    AS_CONFED_SEQUENCE or AS_CONFED_SET path segment SHALL be prepended
    ///    if it is either the leading path segment or is adjacent to a path
    ///    segment that is prepended.
    /// ```
    pub fn merge_aspath_as4path(aspath: &AsPath, as4path: &AsPath) -> AsPath {
        if aspath.route_len() < as4path.route_len() {
            // Per RFC6793, if 2-byte AS path is shorter than 4-byte AS path, ignore 4-byte AS path
            return aspath.clone();
        }

        let mut as4iter = as4path.segments.iter();
        let mut new_segs: Vec<AsPathSegment> = vec![];

        for seg in &aspath.segments {
            match as4iter.next() {
                None => {
                    new_segs.push(seg.clone());
                }
                Some(as4seg_unwrapped) => {
                    if let (AsPathSegment::AsSequence(seq), AsPathSegment::AsSequence(seq4)) =
                        (seg, as4seg_unwrapped)
                    {
                        let diff_len = seq.len() as i32 - seq4.len() as i32;
                        match diff_len {
                            d if d > 0 => {
                                // 2-byte ASN path is longer than 4-byte ASN path
                                // we take the leading part of 2-byte ASN path and prepend it to 4-byte ASN path
                                let mut new_seq: Vec<Asn> = vec![];
                                new_seq.extend(seq.iter().take(d as usize));
                                new_seq.extend(seq4);
                                new_segs.push(AsPathSegment::AsSequence(new_seq));
                            }
                            d if d < 0 => {
                                new_segs.push(AsPathSegment::AsSequence(seq.clone()));
                            }
                            _ => {
                                new_segs.push(AsPathSegment::AsSequence(seq4.clone()));
                            }
                        }
                    } else {
                        new_segs.push(as4seg_unwrapped.clone());
                    }
                }
            };
        }

        AsPath { segments: new_segs }
    }

    /// Iterate through the originating ASNs of this path. This functionality is provided for
    /// completeness, but in almost all cases this iterator should only contain a single element.
    pub fn iter_origins(&self) -> impl '_ + Iterator<Item = Asn> {
        let origin_slice = match self.segments.last() {
            Some(AsPathSegment::AsSequence(v)) => v.last().map(std::slice::from_ref).unwrap_or(&[]),
            Some(AsPathSegment::AsSet(v)) => v.as_ref(),
            _ => &[],
        };

        origin_slice.iter().copied()
    }

    /// This function serves as a alternative to [AsPath::iter_origins] which attempts to make the
    /// assumption that a path can only have exactly one origin. If a path does not have exactly 1
    /// origin (such as when empty or ending in a set), then `None` will be returned instead.
    pub fn get_origin_opt(&self) -> Option<Asn> {
        match self.segments.last() {
            Some(AsPathSegment::AsSequence(v)) => v.last().copied(),
            Some(AsPathSegment::AsSet(v)) if v.len() == 1 => Some(v[0]),
            _ => None,
        }
    }

    /// This function optionally returns the first hop in the AS hop, which is considered as the
    /// collector ASN of the message.
    pub fn get_collector_opt(&self) -> Option<Asn> {
        match self.segments.first() {
            Some(AsPathSegment::AsSequence(v)) => v.first().copied(),
            Some(AsPathSegment::AsSet(v)) if v.len() == 1 => Some(v[0]),
            _ => None,
        }
    }

    pub fn to_u32_vec_opt(&self, dedup: bool) -> Option<Vec<u32>> {
        let mut path = vec![];

        // Iterate over the segments in reverse order
        for seg in self.segments.iter().rev() {
            if let Some(p) = seg.to_u32_vec_opt(dedup) {
                // for each segment, we also reverse the order of ASNs so that we will eventually
                // get a reversed AS path stored in `path`.
                path.extend(p.iter().rev());
            } else {
                // If we encounter a segment that cannot be converted to a u32, we return None.
                // This is because the path is not a simple sequence of ASNs, and returning partial
                // AS path would be misleading.
                return None;
            }
        }

        match path.is_empty() {
            true => {
                // empty path is not a valid AS path
                None
            }
            false => {
                // reverse the order of ASNs to get the original path
                path.reverse();
                Some(path)
            }
        }
    }
}

/// Iterates over all route variations the given `AsPath` represents.
impl<'a> IntoIterator for &'a AsPath {
    type Item = Vec<Asn>;
    type IntoIter = AsPathRouteIter<'a, Vec<Asn>>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter_routes()
    }
}

/// Iterates over all route variations the given `AsPath` represents.
impl IntoIterator for AsPath {
    type Item = Vec<Asn>;
    type IntoIter = AsPathRouteIter<'static, Vec<Asn>>;

    fn into_iter(self) -> Self::IntoIter {
        AsPathRouteIter {
            total_routes: self.num_route_variations(),
            path: Cow::Owned(self.segments),
            route_num: 0,
            _phantom: PhantomData,
        }
    }
}

impl Display for AsPath {
    fn fmt(&self, f: &mut Formatter) -> std::fmt::Result {
        for (index, segment) in self.iter_segments().enumerate() {
            if index != 0 {
                write!(f, " ")?;
            }

            match segment {
                AsPathSegment::AsSequence(v) | AsPathSegment::ConfedSequence(v) => {
                    let mut asn_iter = v.iter();
                    if let Some(first_element) = asn_iter.next() {
                        write!(f, "{first_element}")?;

                        for asn in asn_iter {
                            write!(f, " {asn}")?;
                        }
                    }
                }
                AsPathSegment::AsSet(v) | AsPathSegment::ConfedSet(v) => {
                    write!(f, "{{")?;
                    let mut asn_iter = v.iter();
                    if let Some(first_element) = asn_iter.next() {
                        write!(f, "{first_element}")?;

                        for asn in asn_iter {
                            write!(f, ",{asn}")?;
                        }
                    }
                    write!(f, "}}")?;
                }
            }
        }

        Ok(())
    }
}

#[cfg(feature = "serde")]
mod serde_impl {
    use super::*;
    use serde::de::{SeqAccess, Visitor};
    use serde::ser::SerializeSeq;
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use std::borrow::Cow;

    /// Segment type names using names from RFC3065.
    ///
    /// <https://datatracker.ietf.org/doc/html/rfc3065#section-5>
    #[allow(non_camel_case_types)]
    #[derive(Serialize, Deserialize)]
    enum SegmentType {
        AS_SET,
        AS_SEQUENCE,
        AS_CONFED_SEQUENCE,
        AS_CONFED_SET,
    }

    #[derive(Serialize, Deserialize)]
    struct VerboseSegment<'s> {
        ty: SegmentType,
        values: Cow<'s, [Asn]>,
    }

    impl Serialize for AsPathSegment {
        fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer,
        {
            let (ty, elements) = match self {
                AsPathSegment::AsSequence(x) => (SegmentType::AS_SEQUENCE, x.as_ref()),
                AsPathSegment::AsSet(x) => (SegmentType::AS_SET, x.as_ref()),
                AsPathSegment::ConfedSequence(x) => (SegmentType::AS_CONFED_SEQUENCE, x.as_ref()),
                AsPathSegment::ConfedSet(x) => (SegmentType::AS_CONFED_SET, x.as_ref()),
            };

            let verbose = VerboseSegment {
                ty,
                values: Cow::Borrowed(elements),
            };

            verbose.serialize(serializer)
        }
    }

    impl<'de> Deserialize<'de> for AsPathSegment {
        fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
        where
            D: Deserializer<'de>,
        {
            let verbose = VerboseSegment::deserialize(deserializer)?;

            let values = verbose.values.into_owned();
            match verbose.ty {
                SegmentType::AS_SET => Ok(AsPathSegment::AsSet(values)),
                SegmentType::AS_SEQUENCE => Ok(AsPathSegment::AsSequence(values)),
                SegmentType::AS_CONFED_SEQUENCE => Ok(AsPathSegment::ConfedSequence(values)),
                SegmentType::AS_CONFED_SET => Ok(AsPathSegment::ConfedSet(values)),
            }
        }
    }

    /// Check if we can serialize an `AsPath` using the simplified format and get the number of
    /// elements to do so. The ambiguities that could prevent us from doing so are confederation
    /// segments and adjacent sequence segments.
    fn simplified_format_len(segments: &[AsPathSegment]) -> Option<usize> {
        let mut elements = 0;
        let mut prev_was_sequence = false;
        for segment in segments {
            match segment {
                AsPathSegment::AsSequence(seq) if !prev_was_sequence => {
                    prev_was_sequence = true;
                    elements += seq.len();
                }
                AsPathSegment::AsSet(_) => {
                    prev_was_sequence = false;
                    elements += 1;
                }
                _ => return None,
            }
        }

        Some(elements)
    }

    /// # Serialization format
    /// For the sake of readability and ease of use within other applications, there are verbose and
    /// simplified variants for serialization.
    ///
    /// ## Simplified format
    /// The simplified format is the default preferred serialization format. This format does not
    /// cover confederation segments and involves a single list of ASNs within the path sequence.
    /// For sets, a list of set members is used in place of an ASN.
    /// ```rust
    /// # use bgpkit_parser::models::{Asn, AsPath};
    /// # use bgpkit_parser::models::AsPathSegment::*;
    ///
    /// let a: AsPath = serde_json::from_str("[123, 942, 102]").unwrap();
    /// let b: AsPath = serde_json::from_str("[231, 432, [643, 836], 352]").unwrap();
    ///
    /// assert_eq!(&a.segments, &[
    ///     AsSequence(vec![Asn::from(123), Asn::from(942), Asn::from(102)])
    /// ]);
    /// assert_eq!(&b.segments, &[
    ///     AsSequence(vec![Asn::from(231), Asn::from(432)]),
    ///     AsSet(vec![Asn::from(643), Asn::from(836)]),
    ///     AsSequence(vec![Asn::from(352)])
    /// ]);
    /// ```
    ///
    /// ## Verbose format
    /// The verbose format serves as the fallback format for when the simplified format can not be
    /// used due to ambiguity. This happens when confederation segments are present, or multiple
    /// sequences occur back to back. In this format, segments are explicitly seperated and labeled.
    /// Segment types, denoted by the `ty` field, correspond to the names used within RFC3065
    /// (`AS_SET`, `AS_SEQUENCE`, `AS_CONFED_SEQUENCE`, `AS_CONFED_SET`).
    /// ```rust
    /// # use bgpkit_parser::models::{Asn, AsPath};
    /// # use bgpkit_parser::models::AsPathSegment::*;
    ///
    /// let a = r#"[
    ///     { "ty": "AS_CONFED_SEQUENCE", "values": [123, 942] },
    ///     { "ty": "AS_SEQUENCE", "values": [773] },
    ///     { "ty": "AS_SEQUENCE", "values": [382, 293] }
    /// ]"#;
    ///
    /// let parsed: AsPath = serde_json::from_str(a).unwrap();
    /// assert_eq!(&parsed.segments, &[
    ///     ConfedSequence(vec![Asn::from(123), Asn::from(942)]),
    ///     AsSequence(vec![Asn::from(773)]),
    ///     AsSequence(vec![Asn::from(382), Asn::from(293)])
    /// ]);
    /// ```
    impl Serialize for AsPath {
        fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
        where
            S: Serializer,
        {
            if let Some(num_elements) = simplified_format_len(&self.segments) {
                // Serialize simplified format
                let mut seq_serializer = serializer.serialize_seq(Some(num_elements))?;

                for segment in &self.segments {
                    match segment {
                        AsPathSegment::AsSequence(elements) => {
                            elements
                                .iter()
                                .try_for_each(|x| seq_serializer.serialize_element(x))?;
                        }
                        AsPathSegment::AsSet(x) => seq_serializer.serialize_element(x)?,
                        _ => unreachable!("simplified_format_len checked for confed segments"),
                    }
                }
                return seq_serializer.end();
            }

            // Serialize verbose format
            serializer.collect_seq(&self.segments)
        }
    }

    struct AsPathVisitor;

    impl<'de> Visitor<'de> for AsPathVisitor {
        type Value = AsPath;

        fn expecting(&self, formatter: &mut Formatter) -> std::fmt::Result {
            formatter.write_str("list of AS_PATH segments")
        }

        fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
        where
            A: SeqAccess<'de>,
        {
            // Technically, we can handle an input that mixes the simplified and verbose formats,
            // but we do not want to document this behavior as it may change in future updates.
            #[derive(Deserialize)]
            #[serde(untagged)]
            enum PathElement {
                SequenceElement(Asn),
                Set(Vec<Asn>),
                Verbose(AsPathSegment),
            }

            let mut append_new_sequence = false;
            let mut segments = Vec::new();
            while let Some(element) = seq.next_element()? {
                match element {
                    PathElement::SequenceElement(x) => {
                        if append_new_sequence {
                            // If the input is mixed between verbose and regular segments, this flag
                            // is used to prevent appending to a verbose sequence.
                            append_new_sequence = false;
                            segments.push(AsPathSegment::AsSequence(Vec::new()));
                        }

                        if let Some(AsPathSegment::AsSequence(last_sequence)) = segments.last_mut()
                        {
                            last_sequence.push(x);
                        } else {
                            segments.push(AsPathSegment::AsSequence(vec![x]));
                        }
                    }
                    PathElement::Set(values) => {
                        segments.push(AsPathSegment::AsSet(values));
                    }
                    PathElement::Verbose(verbose) => {
                        segments.push(verbose);
                    }
                }
            }

            Ok(AsPath { segments })
        }
    }

    impl<'de> Deserialize<'de> for AsPath {
        fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
        where
            D: Deserializer<'de>,
        {
            deserializer.deserialize_seq(AsPathVisitor)
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::models::*;
    use itertools::Itertools;
    use std::collections::HashSet;

    #[test]
    fn test_aspath_as4path_merge() {
        let aspath = AsPath::from_sequence([1, 2, 3, 5]);
        let as4path = AsPath::from_sequence([2, 3, 7]);
        let newpath = AsPath::merge_aspath_as4path(&aspath, &as4path);
        assert_eq!(newpath.segments[0], AsPathSegment::sequence([1, 2, 3, 7]));

        let aspath = AsPath::from_sequence([1, 2]);
        let as4path = AsPath::from_sequence([2, 3, 7]);
        let newpath = AsPath::merge_aspath_as4path(&aspath, &as4path);
        assert_eq!(newpath.segments[0], AsPathSegment::sequence([1, 2]));

        // when the sequence length is the same, the as4path should be used
        let aspath = AsPath::from_sequence([1, 2]);
        let as4path = AsPath::from_sequence([3, 4]);
        let newpath = AsPath::merge_aspath_as4path(&aspath, &as4path);
        assert_eq!(newpath.segments[0], AsPathSegment::sequence([3, 4]));

        let aspath = AsPath::from_segments(vec![
            AsPathSegment::sequence([1, 2, 3, 5]),
            AsPathSegment::set([7, 8]),
        ]);
        let as4path = AsPath::from_sequence([6, 7, 8]);
        let newpath = AsPath::merge_aspath_as4path(&aspath, &as4path);
        assert_eq!(newpath.segments.len(), 2);
        assert_eq!(newpath.segments[0], AsPathSegment::sequence([1, 6, 7, 8]));
        assert_eq!(newpath.segments[1], AsPathSegment::set([7, 8]));

        let aspath = AsPath::from_segments(vec![
            AsPathSegment::sequence([1, 2]),
            AsPathSegment::sequence([3, 5]),
            AsPathSegment::set([13, 14]),
        ]);
        let as4path = AsPath::from_segments(vec![
            AsPathSegment::sequence([8, 4, 6]),
            AsPathSegment::set([11, 12]),
        ]);
        let newpath = AsPath::merge_aspath_as4path(&aspath, &as4path);
        assert_eq!(newpath.segments.len(), 3);
        assert_eq!(newpath.segments[0], AsPathSegment::sequence([1, 2]));
        assert_eq!(newpath.segments[1], AsPathSegment::set([11, 12]));
        assert_eq!(newpath.segments[2], AsPathSegment::set([13, 14]));

        let aspath = AsPath::from_segments(vec![
            AsPathSegment::sequence([1, 2, 3]),
            AsPathSegment::sequence([5]),
            AsPathSegment::set([13, 14]),
        ]);
        let as4path = AsPath::from_segments(vec![
            AsPathSegment::sequence([7, 8]),
            AsPathSegment::set([11, 12]),
        ]);
        let newpath = AsPath::merge_aspath_as4path(&aspath, &as4path);
        assert_eq!(newpath.segments.len(), 3);
        assert_eq!(newpath.segments[0], AsPathSegment::sequence([1, 7, 8]));
        assert_eq!(newpath.segments[1], AsPathSegment::set([11, 12]));
        assert_eq!(newpath.segments[2], AsPathSegment::set([13, 14]));
    }

    #[test]
    fn test_get_origin() {
        let aspath = AsPath::from_sequence([1, 2, 3, 5]);
        let origin = aspath.get_origin_opt();
        assert_eq!(origin.unwrap(), 5);

        let aspath = AsPath::from_segments(vec![AsPathSegment::set([1, 2, 3, 5])]);
        let origin = aspath.get_origin_opt();
        assert!(origin.is_none());

        let aspath = AsPath::from_segments(vec![AsPathSegment::set([1])]);
        let origin = aspath.get_origin_opt();
        assert_eq!(origin.unwrap(), 1);

        let aspath = AsPath::from_segments(vec![
            AsPathSegment::sequence([1, 2, 3, 5]),
            AsPathSegment::set([7, 8]),
        ]);
        let origins = aspath.iter_origins().map_into::<u32>().collect::<Vec<_>>();
        assert_eq!(origins, vec![7, 8]);

        let aspath = AsPath::from_segments(vec![
            AsPathSegment::sequence([1, 2, 3, 5]),
            AsPathSegment::ConfedSet(vec![Asn::new_32bit(9)]),
        ]);
        let origins = aspath.iter_origins().map_into::<u32>().collect::<Vec<_>>();
        assert_eq!(origins, Vec::<u32>::new());
    }

    #[test]
    fn test_get_collector() {
        let aspath = AsPath::from_sequence([1, 2, 3, 5]);
        let collector = aspath.get_collector_opt();
        assert_eq!(collector.unwrap(), 1);

        let aspath = AsPath::from_segments(vec![AsPathSegment::set([7])]);
        let collector = aspath.get_collector_opt();
        assert_eq!(collector.unwrap(), 7);

        let aspath = AsPath::from_segments(vec![AsPathSegment::set([7, 8])]);
        let collector = aspath.get_collector_opt();
        assert!(collector.is_none());
    }

    #[test]
    fn test_aspath_route_iter() {
        let path = AsPath::from_segments(vec![AsPathSegment::sequence([3, 4])]);
        let mut routes = HashSet::new();
        for route in &path {
            assert!(routes.insert(route));
        }
        assert_eq!(1, routes.len());

        let path = AsPath::from_segments(vec![
            AsPathSegment::set([3, 4]),
            AsPathSegment::set([5, 6]),
            AsPathSegment::sequence([7, 8]),
            AsPathSegment::ConfedSet(vec![Asn::new_32bit(9)]),
            AsPathSegment::ConfedSequence(vec![Asn::new_32bit(9)]),
        ]);
        assert_eq!(path.route_len(), 4);

        let mut routes = HashSet::new();
        for route in &path {
            assert!(routes.insert(route));
        }

        assert_eq!(routes.len(), 4);
        assert!(routes.contains(&vec![
            Asn::from(3),
            Asn::from(5),
            Asn::from(7),
            Asn::from(8)
        ]));
        assert!(routes.contains(&vec![
            Asn::from(3),
            Asn::from(6),
            Asn::from(7),
            Asn::from(8)
        ]));
        assert!(routes.contains(&vec![
            Asn::from(4),
            Asn::from(5),
            Asn::from(7),
            Asn::from(8)
        ]));
        assert!(routes.contains(&vec![
            Asn::from(4),
            Asn::from(6),
            Asn::from(7),
            Asn::from(8)
        ]));
    }

    #[test]
    fn test_segment() {
        let path_segment = AsPathSegment::sequence([1, 2, 3, 4]);
        assert_eq!(path_segment.len(), 4);

        // test iter
        let mut iter = path_segment.iter();
        assert_eq!(iter.next(), Some(&Asn::new_32bit(1)));
        assert_eq!(iter.next(), Some(&Asn::new_32bit(2)));
        assert_eq!(iter.next(), Some(&Asn::new_32bit(3)));
        assert_eq!(iter.next(), Some(&Asn::new_32bit(4)));
        assert_eq!(iter.next(), None);

        // test iter_mut
        let mut path_segment = AsPathSegment::sequence([1]);
        let mut iter_mut = path_segment.iter_mut();
        assert_eq!(iter_mut.next(), Some(&mut Asn::new_32bit(1)));
        assert_eq!(iter_mut.next(), None);

        // test is_confed
        assert!(AsPathSegment::ConfedSequence(vec![Asn::new_32bit(1)]).is_confed());
        assert!(AsPathSegment::ConfedSet(vec![Asn::new_32bit(1)]).is_confed());
    }

    #[test]
    fn test_coalesce() {
        let mut a = AsPath::from_segments(vec![
            AsPathSegment::sequence([]),
            AsPathSegment::sequence([1, 2]),
            AsPathSegment::sequence([]),
            AsPathSegment::sequence([2]),
            AsPathSegment::set([2]),
            AsPathSegment::set([5, 3, 3, 2]),
        ]);

        let expected = AsPath::from_segments(vec![
            AsPathSegment::sequence([1, 2, 2]),
            AsPathSegment::set([2]),
            AsPathSegment::set([5, 3, 3, 2]),
        ]);

        a.coalesce();
        assert_eq!(a, expected);
    }

    #[test]
    fn test_confed_set_dedup() {
        let mut path_segment = AsPathSegment::ConfedSet(vec![Asn::new_32bit(1), Asn::new_32bit(1)]);
        path_segment.dedup();
        assert_eq!(
            path_segment,
            AsPathSegment::ConfedSequence(vec![Asn::new_32bit(1)])
        );

        let mut path_segment = AsPathSegment::ConfedSet(vec![
            Asn::new_32bit(1),
            Asn::new_32bit(2),
            Asn::new_32bit(2),
        ]);
        path_segment.dedup();
        assert_eq!(
            path_segment,
            AsPathSegment::ConfedSet(vec![Asn::new_32bit(1), Asn::new_32bit(2)])
        );
    }

    #[test]
    fn test_path_to_u32() {
        // regular sequence
        let path_segment = AsPathSegment::sequence([1, 2, 3, 3]);
        assert_eq!(path_segment.to_u32_vec_opt(false), Some(vec![1, 2, 3, 3]));
        assert_eq!(path_segment.to_u32_vec_opt(true), Some(vec![1, 2, 3]));

        // regular set: should return None
        let path_segment = AsPathSegment::set([1, 2, 3, 3]);
        assert_eq!(path_segment.to_u32_vec_opt(false), None);
        assert_eq!(path_segment.to_u32_vec_opt(true), None);

        // singular set: should be converted to singleton vector
        let path_segment = AsPathSegment::set([1]);
        assert_eq!(path_segment.to_u32_vec_opt(false), Some(vec![1]));
        assert_eq!(path_segment.to_u32_vec_opt(true), Some(vec![1]));

        // combination of a sequence and a few singleton sets, should be merged into a single vector
        let as_path = AsPath::from_segments(vec![
            AsPathSegment::set([4]),
            AsPathSegment::sequence([2, 3, 3]),
            AsPathSegment::set([1]),
        ]);
        assert_eq!(as_path.to_u32_vec_opt(false), Some(vec![4, 2, 3, 3, 1]));
        assert_eq!(as_path.to_u32_vec_opt(true), Some(vec![4, 2, 3, 1]));

        // should the path containing any non-convertible segments, return None
        let as_path = AsPath::from_segments(vec![
            AsPathSegment::set([4, 2]),
            AsPathSegment::sequence([2, 3, 3]),
            AsPathSegment::set([1]),
        ]);
        assert_eq!(as_path.to_u32_vec_opt(false), None);
        assert_eq!(as_path.to_u32_vec_opt(true), None);

        // other corner cases

        // empty path
        let as_path = AsPath::from_segments(vec![]);
        assert_eq!(as_path.to_u32_vec_opt(false), None);
        assert_eq!(as_path.to_u32_vec_opt(true), None);

        // path with federation segments
        let as_path = AsPath::from_segments(vec![
            AsPathSegment::ConfedSet(vec![Asn::new_32bit(1), Asn::new_32bit(2)]),
            AsPathSegment::ConfedSequence(vec![Asn::new_32bit(3), Asn::new_32bit(4)]),
        ]);
        assert_eq!(as_path.to_u32_vec_opt(false), None);
        assert_eq!(as_path.to_u32_vec_opt(true), None);
    }

    #[test]
    fn test_as_ref() {
        let path_segment = AsPathSegment::sequence([1, 2]);
        assert_eq!(
            path_segment.as_ref(),
            &[Asn::new_32bit(1), Asn::new_32bit(2)]
        );

        let path_segment = AsPathSegment::set([1, 2]);
        assert_eq!(
            path_segment.as_ref(),
            &[Asn::new_32bit(1), Asn::new_32bit(2)]
        );

        let path_segment =
            AsPathSegment::ConfedSequence(vec![Asn::new_32bit(1), Asn::new_32bit(2)]);
        assert_eq!(
            path_segment.as_ref(),
            &[Asn::new_32bit(1), Asn::new_32bit(2)]
        );

        let path_segment = AsPathSegment::ConfedSet(vec![Asn::new_32bit(1), Asn::new_32bit(2)]);
        assert_eq!(
            path_segment.as_ref(),
            &[Asn::new_32bit(1), Asn::new_32bit(2)]
        );
    }

    #[test]
    fn test_hashing() {
        let path_segment = AsPathSegment::sequence([1, 2]);
        let path_segment2 = AsPathSegment::sequence([1, 2]);

        let hashset = std::iter::once(path_segment).collect::<HashSet<_>>();
        assert!(hashset.contains(&path_segment2));
    }

    #[test]
    fn test_equality() {
        let path_segment = AsPathSegment::sequence([1, 2]);
        let path_segment2 = AsPathSegment::sequence([1, 2]);

        assert_eq!(path_segment, path_segment2);

        let path_segment = AsPathSegment::sequence([1, 2]);
        let path_segment2 = AsPathSegment::set([1, 2, 3]);
        assert_ne!(path_segment, path_segment2);

        // test equality of AS path longer than 32 ASNs
        let path_segment = AsPathSegment::sequence((1..33).collect::<Vec<_>>());
        let path_segment2 = AsPathSegment::sequence((1..33).collect::<Vec<_>>());
        assert_eq!(path_segment, path_segment2);
    }

    #[test]
    fn test_as_path_display() {
        let path = AsPath::from_segments(vec![
            AsPathSegment::sequence([1, 2]),
            AsPathSegment::set([3, 4]),
            AsPathSegment::sequence([5, 6]),
            AsPathSegment::ConfedSet(vec![Asn::new_32bit(7)]),
            AsPathSegment::ConfedSequence(vec![Asn::new_32bit(8)]),
        ]);

        assert_eq!(path.to_string(), "1 2 {3,4} 5 6 {7} 8");
    }
}
