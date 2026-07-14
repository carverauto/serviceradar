use crate::InOutBuf;
use core::{marker::PhantomData, ops::Mul, ptr};
use hybrid_array::{Array, ArraySize, typenum::Prod};

/// Custom pointer type which contains one immutable (input) and one mutable
/// (output) pointer, which are either equal or non-overlapping.
pub struct InOut<'inp, 'out, T> {
    pub(crate) in_ptr: *const T,
    pub(crate) out_ptr: *mut T,
    pub(crate) _pd: PhantomData<(&'inp T, &'out mut T)>,
}

impl<'inp, 'out, T> InOut<'inp, 'out, T> {
    /// Reborrow `self`.
    #[inline(always)]
    pub fn reborrow(&mut self) -> InOut<'_, '_, T> {
        Self {
            in_ptr: self.in_ptr,
            out_ptr: self.out_ptr,
            _pd: PhantomData,
        }
    }

    /// Get immutable reference to the input value.
    #[inline(always)]
    pub fn get_in(&self) -> &T {
        unsafe { &*self.in_ptr }
    }

    /// Get mutable reference to the output value.
    #[inline(always)]
    pub fn get_out(&mut self) -> &mut T {
        unsafe { &mut *self.out_ptr }
    }

    /// Consume `self` and get mutable reference to the output value with lifetime `'out`
    /// and output value equal to the input value.
    ///
    /// In the case if the input and output references are the same, simply returns
    /// the output reference. Otherwise, copies data from the former to the latter
    /// before returning the output reference.
    pub fn into_out_with_copied_in(self) -> &'out mut T
    where
        T: Copy,
    {
        if !core::ptr::eq(self.in_ptr, self.out_ptr) {
            unsafe {
                ptr::copy(self.in_ptr, self.out_ptr, 1);
            }
        }
        unsafe { &mut *self.out_ptr }
    }

    /// Consume `self` and get mutable reference to the output value with lifetime `'out`.
    #[inline(always)]
    pub fn into_out(self) -> &'out mut T {
        unsafe { &mut *self.out_ptr }
    }

    /// Convert `self` to a pair of raw input and output pointers.
    #[inline(always)]
    pub fn into_raw(self) -> (*const T, *mut T) {
        (self.in_ptr, self.out_ptr)
    }

    /// Create `InOut` from raw input and output pointers.
    ///
    /// # Safety
    /// Behavior is undefined if any of the following conditions are violated:
    /// - `in_ptr` must point to a properly initialized value of type `T` and
    ///   must be valid for reads.
    /// - `out_ptr` must point to a properly initialized value of type `T` and
    ///   must be valid for both reads and writes.
    /// - `in_ptr` and `out_ptr` must be either equal or non-overlapping.
    /// - If `in_ptr` and `out_ptr` are equal, then the memory referenced by
    ///   them must not be accessed through any other pointer (not derived from
    ///   the return value) for the duration of lifetime 'a. Both read and write
    ///   accesses are forbidden.
    /// - If `in_ptr` and `out_ptr` are not equal, then the memory referenced by
    ///   `out_ptr` must not be accessed through any other pointer (not derived from
    ///   the return value) for the duration of lifetime `'a`. Both read and write
    ///   accesses are forbidden. The memory referenced by `in_ptr` must not be
    ///   mutated for the duration of lifetime `'a`, except inside an `UnsafeCell`.
    #[inline(always)]
    pub unsafe fn from_raw(in_ptr: *const T, out_ptr: *mut T) -> InOut<'inp, 'out, T> {
        Self {
            in_ptr,
            out_ptr,
            _pd: PhantomData,
        }
    }
}

impl<T: Clone> InOut<'_, '_, T> {
    /// Clone input value and return it.
    #[inline(always)]
    pub fn clone_in(&self) -> T {
        unsafe { (*self.in_ptr).clone() }
    }
}

impl<'a, T> From<&'a mut T> for InOut<'a, 'a, T> {
    #[inline(always)]
    fn from(val: &'a mut T) -> Self {
        let p = val as *mut T;
        Self {
            in_ptr: p,
            out_ptr: p,
            _pd: PhantomData,
        }
    }
}

impl<'inp, 'out, T> From<(&'inp T, &'out mut T)> for InOut<'inp, 'out, T> {
    #[inline(always)]
    fn from((in_val, out_val): (&'inp T, &'out mut T)) -> Self {
        Self {
            in_ptr: in_val as *const T,
            out_ptr: out_val as *mut T,
            _pd: Default::default(),
        }
    }
}

impl<'inp, 'out, T, N: ArraySize> InOut<'inp, 'out, Array<T, N>> {
    /// Returns `InOut` for the given position.
    ///
    /// # Panics
    /// If `pos` greater or equal to array length.
    #[inline(always)]
    pub fn get(&mut self, pos: usize) -> InOut<'_, '_, T> {
        assert!(pos < N::USIZE);
        unsafe {
            InOut {
                in_ptr: (self.in_ptr as *const T).add(pos),
                out_ptr: (self.out_ptr as *mut T).add(pos),
                _pd: PhantomData,
            }
        }
    }

    /// Convert `InOut` array to `InOutBuf`.
    #[inline(always)]
    pub fn into_buf(self) -> InOutBuf<'inp, 'out, T> {
        InOutBuf {
            in_ptr: self.in_ptr as *const T,
            out_ptr: self.out_ptr as *mut T,
            len: N::USIZE,
            _pd: PhantomData,
        }
    }
}

impl<'inp, 'out, T, N, M> From<InOut<'inp, 'out, Array<T, Prod<N, M>>>>
    for Array<InOut<'inp, 'out, Array<T, N>>, M>
where
    N: ArraySize,
    M: ArraySize,
    N: Mul<M>,
    Prod<N, M>: ArraySize,
{
    fn from(buf: InOut<'inp, 'out, Array<T, Prod<N, M>>>) -> Self {
        let in_ptr: *const Array<T, N> = buf.in_ptr.cast();
        let out_ptr: *mut Array<T, N> = buf.out_ptr.cast();

        Array::from_fn(|i| unsafe {
            InOut {
                in_ptr: in_ptr.add(i),
                out_ptr: out_ptr.add(i),
                _pd: PhantomData,
            }
        })
    }
}

impl<N: ArraySize> InOut<'_, '_, Array<u8, N>> {
    /// XOR `data` with values behind the input slice and write
    /// result to the output slice.
    ///
    /// # Panics
    /// If `data` length is not equal to the buffer length.
    #[inline(always)]
    #[allow(clippy::needless_range_loop)]
    pub fn xor_in2out(&mut self, data: &Array<u8, N>) {
        unsafe {
            let input = ptr::read(self.in_ptr);
            let mut temp = Array::<u8, N>::default();
            for i in 0..N::USIZE {
                temp[i] = input[i] ^ data[i];
            }
            ptr::write(self.out_ptr, temp);
        }
    }
}

impl<N, M> InOut<'_, '_, Array<Array<u8, N>, M>>
where
    N: ArraySize,
    M: ArraySize,
{
    /// XOR `data` with values behind the input slice and write
    /// result to the output slice.
    ///
    /// # Panics
    /// If `data` length is not equal to the buffer length.
    #[inline(always)]
    #[allow(clippy::needless_range_loop)]
    pub fn xor_in2out(&mut self, data: &Array<Array<u8, N>, M>) {
        unsafe {
            let input = ptr::read(self.in_ptr);
            let mut temp = Array::<Array<u8, N>, M>::default();
            for i in 0..M::USIZE {
                for j in 0..N::USIZE {
                    temp[i][j] = input[i][j] ^ data[i][j];
                }
            }
            ptr::write(self.out_ptr, temp);
        }
    }
}
