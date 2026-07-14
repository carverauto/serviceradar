use der_parser::ber::*;
use der_parser::der::*;
use std::env;
use std::io;

use nom::HexDisplay;

struct BerPrinter {}

impl BerPrinter {
    /// try to parse contents, constructed or not
    ///
    /// Do not raise errors if object is not constructed
    fn try_print_encapsulated(&mut self, data: &[u8], depth: usize, ber: &BerObject) {
        let mut i = data;
        let mut first_object = true;
        while !i.is_empty() {
            match parse_ber_any_r(i, MAX_RECURSION) {
                Ok((rem, inner)) => {
                    if first_object {
                        println!("{:1$}encapsulates {{", " ", depth * 2);
                        first_object = false;
                    }
                    self.run_at(&inner, depth + 1);
                    i = rem;
                }
                Err(e) => {
                    if ber.is_constructed() {
                        // object was constructed, so should have been parsed correctly
                        eprintln!(
                            "Error while parsing constructed object at depth {}: {}",
                            depth, e
                        );
                        eprintln!("tried to parse\n{}", data.to_hex(16));
                    } else {
                        // does not look like encapsulated data
                        i = &[];
                    }
                    break;
                }
            }
        }
        if !first_object {
            println!("{:1$}}}", " ", depth * 2);
        }
        if !i.is_empty() {
            println!("WARNING: {} remaining bytes at depth {}", i.len(), depth);
        }
    }
}

impl<'a> Visit<'a> for BerPrinter {
    fn visit_ber(&mut self, ber: &'_ BerObject<'a>, depth: usize) {
        // create a printer without the recursive flag, recursion is handled by the
        // visitor pattern
        let pp = PrettyBer::new(ber, vec![PrettyPrinterFlag::ShowHeader], depth * 2, 2);
        println!("{:?}", pp);
        match ber.content {
            BerObjectContent::Unknown(ref any) => {
                self.try_print_encapsulated(any.data, depth, ber);
            }
            // Bitstring and OctetString also can encapsulate objects
            BerObjectContent::OctetString(data) => {
                self.try_print_encapsulated(data, depth, ber);
            }
            _ => (),
        }
    }
}

pub fn main() -> io::Result<()> {
    let mut parse_as_ber = false;
    for file_name in env::args().skip(1) {
        match file_name.as_ref() {
            "--ber" => {
                parse_as_ber = true;
                continue;
            }
            "--der" => {
                parse_as_ber = false;
                continue;
            }
            _ => (),
        }
        let data = std::fs::read(file_name.clone()).expect("Unable to read file");
        let (rem, obj) = if parse_as_ber {
            parse_ber(&data).expect("could not parse BER data")
        } else {
            parse_der(&data).expect("could not parse DER data")
        };
        let mut printer = BerPrinter {};
        printer.run_at(&obj, 1);
        if !rem.is_empty() {
            println!("WARNING: extra bytes after BER/DER object:\n{:x?}", rem);
        }
    }
    Ok(())
}
