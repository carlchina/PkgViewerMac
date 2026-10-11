#ifndef CZLIB_H
#define CZLIB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Inflate a single, self-contained zlib stream (`src`, `src_len` bytes) into
/// `out`, which must be at least `out_cap` bytes. On success returns 0 and sets
/// `*out_len` to the number of bytes written. On failure returns a negative
/// zlib error code (e.g. Z_DATA_ERROR) and leaves `*out_len` untouched.
///
/// Uses `inflateInit2` with `15` window bits (standard zlib). Every PFSC block
/// is a complete zlib member, so a single `Z_FINISH` pass is enough.
int czlib_inflate(const uint8_t *src, size_t src_len,
                 uint8_t *out, size_t out_cap, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* CZLIB_H */
