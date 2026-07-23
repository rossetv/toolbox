// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

#ifndef PDFTOOLBOX_NATIVE_H
#define PDFTOOLBOX_NATIVE_H

#include <stddef.h>
#include <stdint.h>

// The whole Swift-visible surface of the two bundled C/C++ libraries (leptonica, jbig2enc).
//
// It is deliberately this small. Leptonica's own header declares some two thousand functions
// and a dozen struct types; putting it in the bridging header would drop all of them into the
// app module's global Swift namespace. jbig2enc's header is C++ (`bool` parameters, default
// arguments), so Swift cannot see it at all. Both problems disappear behind one narrow C API
// implemented in `PDFToolboxNative.cpp`, which is the only translation unit that includes
// either library.

#ifdef __cplusplus
extern "C" {
#endif

/// A binarised page: one 1-bit-per-pixel leptonica image, owned by the caller.
///
/// Opaque because both encoders need the *same* pixels — CCITT G4 reads the packed rows in
/// Swift, JBIG2 needs the leptonica image itself — and reconstructing one from the other
/// would be a second chance to get the bit order wrong.
typedef struct PDFTBBilevelOpaque *PDFTBBilevelRef;

/// Binarise an 8-bit greyscale raster (adaptive Otsu). `grey` is `height` rows of
/// `greyBytesPerRow` bytes, of which the first `width` are the samples.
/// Returns NULL on failure — the caller then falls back to Rung 1.
PDFTBBilevelRef pdftb_bilevel_binarise(const uint8_t *grey, int width, int height,
                                       int greyBytesPerRow);

/// Release a bitmap returned by `pdftb_bilevel_binarise`. NULL-safe.
void pdftb_bilevel_release(PDFTBBilevelRef bitmap);

/// Copy the packed rows into `rows`: MSB-first, `(width + 7) / 8` bytes a row, **1 = black**
/// (leptonica's foreground convention). `capacity` must be at least
/// `height * ((width + 7) / 8)`. Returns 0 on success, non-zero on failure.
int pdftb_bilevel_copy_rows(PDFTBBilevelRef bitmap, uint8_t *rows, size_t capacity);

/// Encode as a **lossless** JBIG2 generic region, embeddable in a PDF `/JBIG2Decode` stream
/// (no file headers). Never the symbol/text-region mode: that mode is lossy by substituting
/// one glyph bitmap for a similar one, which is how JBIG2 became notorious for silently
/// changing digits in scanned documents (spec §5.1, Rung 2 gate).
///
/// Returns a malloc'd buffer the caller frees with `pdftb_free`, or NULL on failure.
uint8_t *pdftb_bilevel_encode_jbig2(PDFTBBilevelRef bitmap, int resolution, size_t *length);

/// Free a buffer returned by `pdftb_bilevel_encode_jbig2`. NULL-safe.
void pdftb_free(void *buffer);

#ifdef __cplusplus
}
#endif

#endif  // PDFTOOLBOX_NATIVE_H
