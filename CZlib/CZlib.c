#include "CZlib.h"
#include <zlib.h>
#include <string.h>

int czlib_inflate(const uint8_t *src, size_t src_len,
                 uint8_t *out, size_t out_cap, size_t *out_len) {
    if (src == NULL || out == NULL || out_len == NULL) return -1;
    if (src_len > UINT32_MAX || out_cap > UINT32_MAX) return -1;

    z_stream strm;
    memset(&strm, 0, sizeof(strm));

    // 15 window bits: standard zlib-wrapped DEFLATE. (Passing `15 + 16` to
    // auto-detect zlib/gzip makes libz reject these PS streams with
    // Z_DATA_ERROR; plain 15 decodes them correctly.)
    int ret = inflateInit2(&strm, 15);
    if (ret != Z_OK) return ret;

    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)src_len;
    strm.next_out = out;
    strm.avail_out = (uInt)out_cap;

    ret = inflate(&strm, Z_FINISH);
    if (ret != Z_STREAM_END) {
        inflateEnd(&strm);
        return ret;  // Z_DATA_ERROR, Z_BUF_ERROR, etc.
    }

    *out_len = out_cap - strm.avail_out;
    inflateEnd(&strm);
    return 0;
}
