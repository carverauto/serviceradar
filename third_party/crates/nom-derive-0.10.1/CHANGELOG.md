# ChangeLog

## [Unreleased][unreleased]

### Changed/Fixed

### Added

### Thanks

## 0.10.1

### Changed/Fixed

- Fix build failure caused by syn 2.0 (#47, #48)
- Set MSRV to 1.48 (caused by build dependencies)

## 0.10.0

### Changed/Fixed

- Refactor code
- Upgrade to nom 7
- Reduce nom dependencies and features (remove bitvec)
- Fix parsing of String with generic errors enabled (#32)

## 0.9.1

### Changed/Fixed

- Special case derive functions should be public (#27)
- Fixed missing extra_args in parsing function decls (#29)

### Added

- Enable array fields (#26)

### Thanks

- @dbcfd for fixing public attribute on special-case functions
- @katyo for fixing missing extra_args
- @hammypants for arrays (#26)

## 0.9.0

### Changed/Fixed

### Added

- Add Into attribute to convert output/error types
- Generate implementation of Parse trait when possible (closes #21)

The code now generates 3 functions instead of one (parse):
- parse_be: parse object as big-endian
- parse_le: parse object as little-endian
- parse: default function, wraps a call to parse_be
    
If the endianness of the struct is fixed, then all 3 functions are equivalent.

### Thanks

## 0.8.0

Refactor crate:

- Split crate in two (`nom-derive` and `nom-derive-impl`) so it can export public items, in particular the `Parse` trait
- Provide implementation of `Parse` for primitive types, including primitive arrays (closes #4). Also provide example of newtype pattern to specify different implementations (#16)
- Refactor argument parsing and code generation. The AST now include all items, and does not handle most attributes as special, and generate code from top to bottom. This means that
  - attributes are now all handled the same way for deriving struct and enum
  - order of attributes is now important
  - it is possible to specify that a field should be first parse then ignored (#18), or the parse function that will be used with `Count` (#9)
  - endianness is now determined by first looking a field attribute, then object endianness.
  - The `NomBE` and `NomLE` custom derive attributes have been added, and allow specifying global endianness using imports (for ex `use nom_derive::NomLE as Nom`) (#14)
- Add support for generic type parameters and better support for lifetimes and where clauses
- Add `GenericErrors` attribute, to generate a function signature with generic error type (#19)
- Add Complete attribute for top-level (#17)

Except for the order of attributes, there should be no breaking change.

## 0.7.2

- Add LengthCount attribute (#15)
- Add f32 and f64 as native types (#16)
- Rewrite error handling to raise compile errors (instead of panic)

## 0.7.1

- Fix build for syn 1.0.58 (#11)

## 0.7.0

- Upgrade to nom 6

## 0.6.3

- Add support for guards in Selector Patterns (#5)
- Add limited support for Unit fields in enum (#6)
- Make `parse` method public for enums too (#7)

## 0.6.2

- Add ExtraArgs support for structs (top-level only)
- Allow dynamic configuration of endianness (SetEndian attribute)
- Add support for `u128`/`i128` (#3)

## 0.6.1

- Add Tag attribute
- Fix type verification with Cond when using multiple attributes

## 0.6.0

- Switch to nom parsing functions, do not generate macros
- Use qualified paths, caller do not have to import nom macros
- Move all attributes under the 'nom' namespace
- Add many attributes (LittleEndian, BigEndian, Map, Debug, Value, Take,
  AlignAfter/AlignBefore, SkipAfter/SkipBefore, ErrorIf, etc.)
- Deprecate the `NomDeriveDebug` derive (replaced by `DebugDerive` attribute)
- Improve documentation, add many examples
- Rewrite attribute parser, now accepting a more flexible syntax

## 0.5.0

- Upgrade to nom 5.0
- The `parse` method is now public
- Upgrade dependencies (syn, quote, proc-macro2)

## 0.4.0

- Add support for `Enum` parser generator
  - Enums require a selector to choose the variant
  - Fieldless enums (list of constants) are handled as a special case
- Add `NomDeriveDebug` attribute to display generated parser on stderr during build

## 0.3.0

- Move crate to rust-bakery github project
- Add `Count` attribute
