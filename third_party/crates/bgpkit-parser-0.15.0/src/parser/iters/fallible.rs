/*!
Fallible iterator implementations that return Results, exposing parsing errors to users.

These iterators complement the default iterators by returning `Result<T, ParserErrorWithBytes>`
instead of silently skipping errors. This allows users to handle errors explicitly while
maintaining backward compatibility with existing code.
*/
use crate::error::{ParserError, ParserErrorWithBytes};
use crate::models::*;
use crate::parser::BgpkitParser;
use crate::{Elementor, Filterable};
use std::io::Read;

/// Fallible iterator over MRT records that returns parsing errors.
///
/// Unlike the default `RecordIterator`, this iterator returns `Result<MrtRecord, ParserErrorWithBytes>`
/// allowing users to handle parsing errors explicitly instead of having them logged and skipped.
pub struct FallibleRecordIterator<R> {
    parser: BgpkitParser<R>,
    elementor: Elementor,
}

impl<R> FallibleRecordIterator<R> {
    pub(crate) fn new(parser: BgpkitParser<R>) -> Self {
        FallibleRecordIterator {
            parser,
            elementor: Elementor::new(),
        }
    }
}

impl<R: Read> Iterator for FallibleRecordIterator<R> {
    type Item = Result<MrtRecord, ParserErrorWithBytes>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            match self.parser.next_record() {
                Ok(record) => {
                    // Apply filters if any are set
                    let filters = &self.parser.filters;
                    if filters.is_empty() {
                        return Some(Ok(record));
                    }

                    // Special handling for PeerIndexTable - always pass through
                    if let MrtMessage::TableDumpV2Message(TableDumpV2Message::PeerIndexTable(_)) =
                        &record.message
                    {
                        let _ = self.elementor.record_to_elems(record.clone());
                        return Some(Ok(record));
                    }

                    // Check if any elements from this record match the filters
                    let elems = self.elementor.record_to_elems(record.clone());
                    if elems.iter().any(|e| e.match_filters(filters)) {
                        return Some(Ok(record));
                    }
                    // Record doesn't match filters, continue to next
                    continue;
                }
                Err(e) if matches!(e.error, ParserError::EofExpected) => {
                    // Normal end of file
                    return None;
                }
                Err(e) => {
                    // Return the error to the user
                    return Some(Err(e));
                }
            }
        }
    }
}

/// Fallible iterator over BGP elements that returns parsing errors.
///
/// Unlike the default `ElemIterator`, this iterator returns `Result<BgpElem, ParserErrorWithBytes>`
/// for each successfully parsed element, and surfaces any parsing errors encountered.
pub struct FallibleElemIterator<R> {
    cache_elems: Vec<BgpElem>,
    record_iter: FallibleRecordIterator<R>,
    elementor: Elementor,
}

impl<R> FallibleElemIterator<R> {
    pub(crate) fn new(parser: BgpkitParser<R>) -> Self {
        FallibleElemIterator {
            record_iter: FallibleRecordIterator::new(parser),
            cache_elems: vec![],
            elementor: Elementor::new(),
        }
    }
}

impl<R: Read> Iterator for FallibleElemIterator<R> {
    type Item = Result<BgpElem, ParserErrorWithBytes>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            // First check if we have cached elements
            if !self.cache_elems.is_empty() {
                if let Some(elem) = self.cache_elems.pop() {
                    if elem.match_filters(&self.record_iter.parser.filters) {
                        return Some(Ok(elem));
                    }
                    // Element doesn't match filters, continue to next
                    continue;
                }
            }

            // Need to refill cache from next record
            match self.record_iter.next() {
                None => return None,
                Some(Err(e)) => return Some(Err(e)),
                Some(Ok(record)) => {
                    let mut elems = self.elementor.record_to_elems(record);
                    if elems.is_empty() {
                        // No elements from this record, try next
                        continue;
                    }
                    // Reverse to maintain order when popping
                    elems.reverse();
                    self.cache_elems = elems;
                    continue;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// Create a test parser with mock data that will cause parsing errors
    fn create_test_parser_with_errors() -> BgpkitParser<Cursor<Vec<u8>>> {
        // Create some invalid MRT data that will trigger parsing errors
        let invalid_data = vec![
            // MRT header with invalid type
            0x00, 0x00, 0x00, 0x00, // timestamp
            0xFF, 0xFF, // invalid type
            0x00, 0x00, // subtype
            0x00, 0x00, 0x00, 0x04, // length
            0x00, 0x00, 0x00, 0x00, // dummy data
        ];

        let cursor = Cursor::new(invalid_data);
        BgpkitParser::from_reader(cursor)
    }

    /// Create a test parser with valid data
    fn create_test_parser_with_valid_data() -> BgpkitParser<Cursor<Vec<u8>>> {
        // This would need actual valid MRT data - for now using empty data
        // which will result in EOF
        let cursor = Cursor::new(vec![]);
        BgpkitParser::from_reader(cursor)
    }

    #[test]
    fn test_fallible_record_iterator_with_errors() {
        let parser = create_test_parser_with_errors();
        let mut iter = parser.into_fallible_record_iter();

        // First item should be an error
        let result = iter.next();
        assert!(result.is_some());
        assert!(result.unwrap().is_err());
    }

    #[test]
    fn test_fallible_record_iterator_eof() {
        let parser = create_test_parser_with_valid_data();
        let mut iter = parser.into_fallible_record_iter();

        // Should return None on EOF
        let result = iter.next();
        assert!(result.is_none());
    }

    #[test]
    fn test_fallible_elem_iterator_with_errors() {
        let parser = create_test_parser_with_errors();
        let mut iter = parser.into_fallible_elem_iter();

        // First item should be an error
        let result = iter.next();
        assert!(result.is_some());
        assert!(result.unwrap().is_err());
    }

    #[test]
    fn test_fallible_elem_iterator_eof() {
        let parser = create_test_parser_with_valid_data();
        let mut iter = parser.into_fallible_elem_iter();

        // Should return None on EOF
        let result = iter.next();
        assert!(result.is_none());
    }
}
