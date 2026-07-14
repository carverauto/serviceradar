use hybrid_array::{
    Array,
    sizes::{U2, U4, U8},
};
use inout::{InOut, InOutBuf};

#[test]
fn test_split() {
    let mut buf = vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
    let inout: InOutBuf<'_, '_, u8> = buf.as_mut_slice().into();

    let expected: Vec<&[u8]> = vec![
        &[1, 2],
        &[3, 4],
        &[5, 6],
        &[7, 8],
        &[9, 10],
        &[11, 12],
        &[13, 14],
        &[15, 16],
    ];
    let mut expected = expected.into_iter();

    let (blocks, _tail) = inout.into_chunks::<U8>();
    for block in blocks.into_iter() {
        type SubBlock = Array<u8, U2>;

        let subblocks = Array::<InOut<'_, '_, SubBlock>, U4>::from(block);

        for subblock in subblocks {
            assert_eq!(Some(subblock.get_in().as_slice()), expected.next());
        }
    }
}
