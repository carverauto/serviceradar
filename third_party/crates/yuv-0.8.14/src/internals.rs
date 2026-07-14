/*
 * Copyright (c) Radzivon Bartoshyk, 10/2024. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1.  Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2.  Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3.  Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
use crate::yuv_support::{CbCrForwardTransform, CbCrInverseTransform, YuvChromaRange};

#[allow(dead_code)]
#[derive(Debug, Copy, Clone, Ord, PartialOrd, Eq, PartialEq)]
pub(crate) struct ProcessedOffset {
    pub(crate) cx: usize,
    pub(crate) ux: usize,
}

pub(crate) trait WideRowInversionHandler<V, K> {
    fn handle_row(
        &self,
        y_plane: &[V],
        u_plane: &[V],
        v_plane: &[V],
        rgba: &mut [V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait WideRowAlphaInversionHandler<V, T, K> {
    fn handle_row(
        &self,
        y_plane: &[V],
        u_plane: &[V],
        v_plane: &[V],
        a_plane: &[V],
        rgba: &mut [T],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
        use_premultiplied_alpha: bool,
    ) -> ProcessedOffset;
}

#[cfg(feature = "nightly_f16")]
pub(crate) trait WideDRowInversionHandler<V, T, K> {
    fn handle_row(
        &self,
        y_plane: &[V],
        u_plane: &[V],
        v_plane: &[V],
        rgba: &mut [T],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
    ) -> ProcessedOffset;
}

#[cfg(feature = "nightly_f16")]
pub(crate) trait WideDAlphaRowInversionHandler<V, T, K> {
    fn handle_row(
        &self,
        y_plane: &[V],
        u_plane: &[V],
        v_plane: &[V],
        a_plane: &[V],
        rgba: &mut [T],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait WideRow420InversionHandler<V, K> {
    fn handle_row(
        &self,
        y0_plane: &[V],
        y1_plane: &[V],
        u_plane: &[V],
        v_plane: &[V],
        rgba0: &mut [V],
        rgba1: &mut [V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait RowBiPlanarInversionHandler<V, K> {
    fn handle_row(
        &self,
        y_plane: &[V],
        uv_plane: &[V],
        rgba: &mut [V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait RowDBiPlanarInversionHandler<V, T, K> {
    fn handle_row(
        &self,
        y_plane: &[V],
        uv_plane: &[V],
        rgba: &mut [T],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait RowBiPlanarInversion420Handler<V, K> {
    fn handle_row(
        &self,
        y_plane0: &[V],
        y_plane1: &[V],
        uv_plane: &[V],
        rgba0: &mut [V],
        rgba1: &mut [V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrInverseTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait WideRowForwardHandler<V, K> {
    fn handle_row(
        &self,
        y_plane: &mut [V],
        u_plane: &mut [V],
        v_plane: &mut [V],
        rgba: &[V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrForwardTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait WideRowForward420Handler<V, K> {
    fn handle_row(
        &self,
        y_plane0: &mut [V],
        y_plane1: &mut [V],
        u_plane: &mut [V],
        v_plane: &mut [V],
        rgba0: &[V],
        rgba1: &[V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrForwardTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait WideRowForwardBiPlanar420Handler<V, K> {
    fn handle_rows(
        &self,
        rgba0: &[V],
        rgba1: &[V],
        y_plane0: &mut [V],
        y_plane1: &mut [V],
        uv_plane: &mut [V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrForwardTransform<K>,
    ) -> ProcessedOffset;
}

pub(crate) trait WideRowForwardBiPlanarHandler<V, K> {
    fn handle_row(
        &self,
        rgba: &[V],
        y_plane: &mut [V],
        uv_plane: &mut [V],
        width: u32,
        chroma: YuvChromaRange,
        transform: &CbCrForwardTransform<K>,
    ) -> ProcessedOffset;
}
