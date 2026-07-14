/*!
Default iterator implementations that skip errors and return successfully parsed items.
*/
use crate::error::ParserError;
use crate::models::*;
use crate::parser::BgpkitParser;
use crate::{Elementor, Filterable};
use log::{error, warn};
use std::io::Read;

/*********
MrtRecord Iterator
**********/

pub struct RecordIterator<R> {
    pub parser: BgpkitParser<R>,
    pub count: u64,
    elementor: Elementor,
}

impl<R> RecordIterator<R> {
    pub(crate) fn new(parser: BgpkitParser<R>) -> Self {
        RecordIterator {
            parser,
            count: 0,
            elementor: Elementor::new(),
        }
    }
}

impl<R: Read> Iterator for RecordIterator<R> {
    type Item = MrtRecord;

    fn next(&mut self) -> Option<MrtRecord> {
        self.count += 1;
        loop {
            return match self.parser.next_record() {
                Ok(v) => {
                    // if None, the reaches EoF.
                    let filters = &self.parser.filters;
                    if filters.is_empty() {
                        Some(v)
                    } else {
                        if let MrtMessage::TableDumpV2Message(TableDumpV2Message::PeerIndexTable(
                            _,
                        )) = &v.message
                        {
                            let _ = self.elementor.record_to_elems(v.clone());
                            return Some(v);
                        }
                        let elems = self.elementor.record_to_elems(v.clone());
                        if elems.iter().any(|e| e.match_filters(&self.parser.filters)) {
                            Some(v)
                        } else {
                            continue;
                        }
                    }
                }
                Err(e) => {
                    match e.error {
                        ParserError::TruncatedMsg(err_str) | ParserError::Unsupported(err_str) => {
                            if self.parser.options.show_warnings {
                                warn!("parser warn: {}", err_str);
                            }
                            if let Some(bytes) = e.bytes {
                                std::fs::write("mrt_core_dump", bytes)
                                    .expect("Unable to write to mrt_core_dump");
                            }
                            continue;
                        }
                        ParserError::ParseError(err_str) => {
                            error!("parser error: {}", err_str);
                            if self.parser.core_dump {
                                if let Some(bytes) = e.bytes {
                                    std::fs::write("mrt_core_dump", bytes)
                                        .expect("Unable to write to mrt_core_dump");
                                }
                                None
                            } else {
                                continue;
                            }
                        }
                        ParserError::EofExpected => {
                            // normal end of file
                            None
                        }
                        ParserError::IoError(err) | ParserError::EofError(err) => {
                            // when reaching IO error, stop iterating
                            error!("{:?}", err);
                            if self.parser.core_dump {
                                if let Some(bytes) = e.bytes {
                                    std::fs::write("mrt_core_dump", bytes)
                                        .expect("Unable to write to mrt_core_dump");
                                }
                            }
                            None
                        }
                        #[cfg(feature = "oneio")]
                        ParserError::OneIoError(_) => None,
                        ParserError::FilterError(_) => {
                            // this should not happen at this stage
                            None
                        }
                    }
                }
            };
        }
    }
}

/*********
BgpElem Iterator
**********/

pub struct ElemIterator<R> {
    cache_elems: Vec<BgpElem>,
    record_iter: RecordIterator<R>,
    elementor: Elementor,
    count: u64,
}

impl<R> ElemIterator<R> {
    pub(crate) fn new(parser: BgpkitParser<R>) -> Self {
        ElemIterator {
            record_iter: RecordIterator::new(parser),
            count: 0,
            cache_elems: vec![],
            elementor: Elementor::new(),
        }
    }
}

impl<R: Read> Iterator for ElemIterator<R> {
    type Item = BgpElem;

    fn next(&mut self) -> Option<BgpElem> {
        self.count += 1;

        loop {
            if self.cache_elems.is_empty() {
                // refill cache elems
                loop {
                    match self.record_iter.next() {
                        None => {
                            // no more records
                            return None;
                        }
                        Some(r) => {
                            let mut elems = self.elementor.record_to_elems(r);
                            if elems.is_empty() {
                                // somehow this record does not contain any elems, continue to parse next record
                                continue;
                            } else {
                                elems.reverse();
                                self.cache_elems = elems;
                                break;
                            }
                        }
                    }
                }
                // when reaching here, the `self.cache_elems` has been refilled with some more elems
            }

            // popping cached elems. note that the original elems order is preseved by reversing the
            // vector before putting it on to cache_elems.
            let elem = self.cache_elems.pop();
            match elem {
                None => return None,
                Some(e) => match e.match_filters(&self.record_iter.parser.filters) {
                    true => return Some(e),
                    false => continue,
                },
            }
        }
    }
}
