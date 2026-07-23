// PDF Toolbox
// Copyright (C) 2026 Vilmar Rosset (toolbox@rosset.ie)
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This file is part of PDF Toolbox, released under the GNU Affero General
// Public License v3.0 or later. See the LICENSE file in the project root.

#include "PDFToolboxNative.h"

#include <leptonica/allheaders.h>
#include <jbig2enc.h>

#include <stdlib.h>
#include <string.h>

struct PDFTBBilevelOpaque {
    PIX *pix;
};

namespace {

/// Otsu tile edge, in pixels. One inch at 300 dpi: small enough to follow the illumination
/// gradient across a photographed or badly-lit scan, large enough that a tile still holds both
/// ink and paper — a tile of pure paper has no bimodal histogram and Otsu turns its noise into
/// speckle.
const int kOtsuTile = 300;

/// Below this a tile is meaningless, and leptonica's tiled path is not defined for it.
const int kMinOtsuTile = 16;

/// Refuse rasters whose row count times row length would overflow, and anything past the
/// largest page this tool renders. 2^28 pixels is roughly A4 at 1200 dpi.
const long long kMaxPixels = 1LL << 28;

int clampTile(int extent) {
    if (extent < kMinOtsuTile) return kMinOtsuTile;
    return extent < kOtsuTile ? extent : kOtsuTile;
}

}  // namespace

PDFTBBilevelRef pdftb_bilevel_binarise(const uint8_t *grey, int width, int height,
                                       int greyBytesPerRow) {
    if (grey == NULL || width <= 0 || height <= 0 || greyBytesPerRow < width) return NULL;
    if ((long long)width * (long long)height > kMaxPixels) return NULL;

    PIX *grey8 = pixCreate(width, height, 8);
    if (grey8 == NULL) return NULL;

    l_uint32 *data = pixGetData(grey8);
    const l_int32 wpl = pixGetWpl(grey8);
    for (int y = 0; y < height; ++y) {
        l_uint32 *line = data + (size_t)y * (size_t)wpl;
        const uint8_t *src = grey + (size_t)y * (size_t)greyBytesPerRow;
        for (int x = 0; x < width; ++x) {
            SET_DATA_BYTE(line, x, src[x]);
        }
    }

    PIX *binary = NULL;
    if (pixOtsuAdaptiveThreshold(grey8, clampTile(width), clampTile(height), 2, 2, 0.1f,
                                 NULL, &binary) != 0) {
        binary = NULL;
    }
    if (binary == NULL) {
        // Degenerate geometry (a raster narrower than one tile) is the only way to get here on
        // an honest page. A fixed mid-grey threshold is worse than Otsu but still correct, and
        // a page that binarises poorly is caught downstream by the never-larger and validation
        // gates rather than being delivered.
        binary = pixThresholdToBinary(grey8, 128);
    }
    pixDestroy(&grey8);
    if (binary == NULL) return NULL;

    PDFTBBilevelRef bitmap = (PDFTBBilevelRef)calloc(1, sizeof(struct PDFTBBilevelOpaque));
    if (bitmap == NULL) {
        pixDestroy(&binary);
        return NULL;
    }
    bitmap->pix = binary;
    return bitmap;
}

void pdftb_bilevel_release(PDFTBBilevelRef bitmap) {
    if (bitmap == NULL) return;
    if (bitmap->pix != NULL) pixDestroy(&bitmap->pix);
    free(bitmap);
}

int pdftb_bilevel_copy_rows(PDFTBBilevelRef bitmap, uint8_t *rows, size_t capacity) {
    if (bitmap == NULL || bitmap->pix == NULL || rows == NULL) return 1;

    l_uint8 *packed = NULL;
    size_t packedBytes = 0;
    // Byte-packed, MSB first, one row padded to a byte boundary — leptonica's internal layout
    // is 32-bit words in host order, which is not what either encoder or a PDF wants.
    if (pixGetRasterData(bitmap->pix, &packed, &packedBytes) != 0 || packed == NULL) {
        if (packed != NULL) lept_free(packed);
        return 1;
    }
    if (packedBytes > capacity) {
        lept_free(packed);
        return 1;
    }
    memcpy(rows, packed, packedBytes);
    if (packedBytes < capacity) memset(rows + packedBytes, 0, capacity - packedBytes);
    lept_free(packed);
    return 0;
}

uint8_t *pdftb_bilevel_encode_jbig2(PDFTBBilevelRef bitmap, int resolution, size_t *length) {
    if (bitmap == NULL || bitmap->pix == NULL || length == NULL) return NULL;
    *length = 0;

    int encodedLength = 0;
    // full_headers = false → a bare generic region, which is what a PDF `/JBIG2Decode` stream
    // must contain (the file header and end-of-file segments belong to standalone .jb2 files).
    // duplicate_line_removal = false → jbig2enc's own header records that turning it on breaks
    // Ghostscript's decoder, and it saves nothing.
    uint8_t *encoded = jbig2_encode_generic(bitmap->pix, false, resolution, resolution,
                                            false, &encodedLength);
    if (encoded == NULL) return NULL;
    if (encodedLength <= 0) {
        free(encoded);
        return NULL;
    }
    *length = (size_t)encodedLength;
    return encoded;
}

void pdftb_free(void *buffer) {
    // jbig2enc hands back plain `malloc`ed memory, so this is `free`, not `lept_free`.
    if (buffer != NULL) free(buffer);
}
