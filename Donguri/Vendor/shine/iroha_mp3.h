//
//  iroha_mp3.h
//  Donguri
//
//  MP3 encoding for Anki card audio, on shine (https://github.com/toots/shine,
//  LGPL-2.0, vendored in this folder). iOS has no MP3 encoder of its own.
//

#ifndef IROHA_MP3_H
#define IROHA_MP3_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Encodes mono 16-bit PCM as MP3. `samplerate` must be one MP3 supports
/// (44100, 48000, 32000, 22050, 24000, 16000…). Returns a buffer the caller
/// releases with iroha_mp3_free, its length in `out_size`; NULL on failure.
unsigned char *iroha_mp3_encode_mono(const int16_t *samples, long count, int samplerate,
                                     int bitrate, long *out_size);

void iroha_mp3_free(void *buffer);

#ifdef __cplusplus
}
#endif

#endif
