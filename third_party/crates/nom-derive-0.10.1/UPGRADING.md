## Upgrading to 0.9

### Generalization of the Parse trait

`nom-derive` now generates an implementation of the `Parse` trait when possible (when there are no selector or extra args).
The methods `parse_be` and `parse_le` are both generated (unless endianness is fixed), and will recursively call
similarly named methods in child objects.

There are two possibilities:
  - the object can be represented (and parsed) differently, depending on the endianness
  - the object always have the same representation, and does not depend on the endianness (most common case)

If the object always have the same parsing, then the endianness should be fixed. This can be done by using the `NomBE`
or `NomLE` custom derive instead of `Nom`, or by applying the `BigEndian` or `LittleEndian` top-level attributes.

If the object can has different representations, then the `Nom` custom derive should be used.

Additionally, calling the parsing methods requires the `Parse` trait, so callers must import it:
```rust
use nom_derive::Parse;
```

### Manual implementations of the `parse` method

If you have manually implemented or called `parse` methods, you should convert them to implementations of the `Parse`
trait.

There are two possibilities:
  - object does not depend on endianness: only the `parse` method of the trait should be implemented
  - object has different representations: both `parse_be` and `parse_le` should be implemented

For example:

```rust
impl OspfLinkStateAdvertisement {
    pub fn parse(input: &[u8]) -> IResult<&[u8], OspfLinkStateAdvertisement> {
        ...
    }
}
```

An OSPF packet is always represented as big-endian, so this becomes:

```rust
impl<'a> Parse<&'a [u8]> for OspfLinkStateAdvertisement {
    fn parse(input: &'a [u8]) -> IResult<&'a [u8], OspfLinkStateAdvertisement> {
        ...
    }
}
```

In most cases, that means only changing the `impl` statement and removing the `pub` keyword.

## Upgrading to 0.8

### The Parse trait

The trait `Parse` has been introduced in 0.8.0. This trait is used to provide a common interface, and default implementations for primitive types.

As a consequence, it must be imported as well as the custom derive attribute:
`use nom_derive::Nom` now often becomes `use nom_derive::{Nom, Parse}` or `use nom_derive::*`.

### Order of attributes

`nom-derive` will now apply attributes in order of appearance to build a parse tree.

For example, if specifying both `Count` and `Cond` attributes:
- `Count="4", Cond(a > 0)` is built as `Count(4, Cond(a> 0, T::Parse))`, which means a type `Vec<Option<T>>` is expected
- `Cond(a > 0), Count="4"` is built as `Cond(a> 0, Count(4, T::Parse))`, which means a type `Option<Vec<T>>` is expected
