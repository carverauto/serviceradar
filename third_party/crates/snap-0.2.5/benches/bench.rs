#![feature(test)]

#[macro_use]
extern crate lazy_static;
extern crate snap;
#[cfg(feature = "cpp")]
extern crate snappy_cpp;
extern crate test;

macro_rules! compress {
    ($comp:expr, $name:ident, $filename:expr) => {
        compress!($comp, $name, $filename, 0);
    };
    ($comp:expr, $name:ident, $filename:expr, $size:expr) => {
        #[bench]
        fn $name(b: &mut ::test::Bencher) {
            lazy_static! {
                static ref SRC: Vec<u8> = {
                    let src =
                        include_bytes!(concat!("../data/", $filename));
                    let mut src = &src[..];
                    if $size > 0 {
                        src = &src[0..$size];
                    }
                    src.to_owned()
                };
            };
            let mut dst = vec![0; ::snap::max_compress_len(SRC.len())];
            b.bytes = SRC.len() as u64;
            b.iter(|| {
                $comp(SRC.as_slice(), &mut dst).unwrap()
            });
        }
    };
}

macro_rules! decompress {
    ($dec:expr, $name:ident, $filename:expr) => {
        decompress!($dec, $name, $filename, 0);
    };
    ($dec:expr, $name:ident, $filename:expr, $size:expr) => {
        #[bench]
        fn $name(b: &mut ::test::Bencher) {
            lazy_static! {
                static ref SRC: Vec<u8> = {
                    let src =
                        include_bytes!(concat!("../data/", $filename));
                    let mut src = &src[..];
                    if $size > 0 {
                        src = &src[0..$size];
                    }
                    src.to_owned()
                };
                static ref COMPRESSED: Vec<u8> = {
                    ::snap::Encoder::new().compress_vec(&*SRC).unwrap()
                };
            };

            let mut dst = vec![0; SRC.len()];
            b.bytes = SRC.len() as u64;
            b.iter(|| {
                $dec(COMPRESSED.as_slice(), &mut dst).unwrap()
            });
        }
    };
}

mod rust {
    use snap::{Encoder, Decoder, Result};

    #[inline(always)]
    fn compress(input: &[u8], output: &mut [u8]) -> Result<usize> {
        Encoder::new().compress(input, output)
    }

    #[inline(always)]
    fn decompress(input: &[u8], output: &mut [u8]) -> Result<usize> {
        Decoder::new().decompress(input, output)
    }

    compress!(compress, zflat00_html, "html");
    compress!(compress, zflat01_urls, "urls.10K");
    compress!(compress, zflat02_jpg, "fireworks.jpeg");
    compress!(compress, zflat03_jpg_200, "fireworks.jpeg", 200);
    compress!(compress, zflat04_pdf, "paper-100k.pdf");
    compress!(compress, zflat05_html4, "html_x_4");
    compress!(compress, zflat06_txt1, "alice29.txt");
    compress!(compress, zflat07_txt2, "asyoulik.txt");
    compress!(compress, zflat08_txt3, "lcet10.txt");
    compress!(compress, zflat09_txt4, "plrabn12.txt");
    compress!(compress, zflat10_pb, "geo.protodata");
    compress!(compress, zflat11_gaviota, "kppkn.gtb");

    decompress!(decompress, uflat00_html, "html");
    decompress!(decompress, uflat01_urls, "urls.10K");
    decompress!(decompress, uflat02_jpg, "fireworks.jpeg");
    decompress!(decompress, uflat03_jpg_200, "fireworks.jpeg", 200);
    decompress!(decompress, uflat04_pdf, "paper-100k.pdf");
    decompress!(decompress, uflat05_html4, "html_x_4");
    decompress!(decompress, uflat06_txt1, "alice29.txt");
    decompress!(decompress, uflat07_txt2, "asyoulik.txt");
    decompress!(decompress, uflat08_txt3, "lcet10.txt");
    decompress!(decompress, uflat09_txt4, "plrabn12.txt");
    decompress!(decompress, uflat10_pb, "geo.protodata");
    decompress!(decompress, uflat11_gaviota, "kppkn.gtb");
}

#[cfg(feature = "cpp")]
mod cpp {
    use snappy_cpp::{compress, decompress};

    compress!(compress, zflat00_html, "html");
    compress!(compress, zflat01_urls, "urls.10K");
    compress!(compress, zflat02_jpg, "fireworks.jpeg");
    compress!(compress, zflat03_jpg_200, "fireworks.jpeg", 200);
    compress!(compress, zflat04_pdf, "paper-100k.pdf");
    compress!(compress, zflat05_html4, "html_x_4");
    compress!(compress, zflat06_txt1, "alice29.txt");
    compress!(compress, zflat07_txt2, "asyoulik.txt");
    compress!(compress, zflat08_txt3, "lcet10.txt");
    compress!(compress, zflat09_txt4, "plrabn12.txt");
    compress!(compress, zflat10_pb, "geo.protodata");
    compress!(compress, zflat11_gaviota, "kppkn.gtb");

    decompress!(decompress, uflat00_html, "html");
    decompress!(decompress, uflat01_urls, "urls.10K");
    decompress!(decompress, uflat02_jpg, "fireworks.jpeg");
    decompress!(decompress, uflat03_jpg_200, "fireworks.jpeg", 200);
    decompress!(decompress, uflat04_pdf, "paper-100k.pdf");
    decompress!(decompress, uflat05_html4, "html_x_4");
    decompress!(decompress, uflat06_txt1, "alice29.txt");
    decompress!(decompress, uflat07_txt2, "asyoulik.txt");
    decompress!(decompress, uflat08_txt3, "lcet10.txt");
    decompress!(decompress, uflat09_txt4, "plrabn12.txt");
    decompress!(decompress, uflat10_pb, "geo.protodata");
    decompress!(decompress, uflat11_gaviota, "kppkn.gtb");
}
