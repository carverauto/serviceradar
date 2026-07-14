/// This type is public but not publically reachable
///
/// It is used to prevent direct construction of structs, but allow functional updates like: `Foo
/// { bar: 0, ..Default::default() }`
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Default)]
pub struct NonExhaustiveMarker;
