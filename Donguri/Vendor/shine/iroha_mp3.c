//
//  iroha_mp3.c
//  Donguri
//

#include "iroha_mp3.h"
#include "layer3.h"
#include <stdlib.h>
#include <string.h>

static int append(unsigned char **out, long *size, long *capacity, const unsigned char *data, int length) {
    if (length <= 0 || data == NULL) { return 1; }
    if (*size + length > *capacity) {
        long next = (*capacity) * 2;
        while (next < *size + length) { next *= 2; }
        unsigned char *grown = realloc(*out, (size_t)next);
        if (grown == NULL) { return 0; }
        *out = grown;
        *capacity = next;
    }
    memcpy(*out + *size, data, (size_t)length);
    *size += length;
    return 1;
}

unsigned char *iroha_mp3_encode_mono(const int16_t *samples, long count, int samplerate,
                                     int bitrate, long *out_size) {
    *out_size = 0;
    if (shine_check_config(samplerate, bitrate) < 0) { return NULL; }

    shine_config_t config;
    memset(&config, 0, sizeof(config));
    shine_set_config_mpeg_defaults(&config.mpeg);
    config.wave.channels = PCM_MONO;
    config.wave.samplerate = samplerate;
    config.mpeg.mode = MONO;
    config.mpeg.bitr = bitrate;

    shine_t encoder = shine_initialise(&config);
    if (encoder == NULL) { return NULL; }
    int per_pass = shine_samples_per_pass(encoder);

    long capacity = 64 * 1024, size = 0;
    unsigned char *out = malloc((size_t)capacity);
    int16_t *frame = malloc(sizeof(int16_t) * (size_t)per_pass);
    if (out == NULL || frame == NULL) {
        free(out); free(frame); shine_close(encoder);
        return NULL;
    }

    for (long position = 0; position < count; position += per_pass) {
        long take = count - position < per_pass ? count - position : per_pass;
        memcpy(frame, samples + position, sizeof(int16_t) * (size_t)take);
        if (take < per_pass) { memset(frame + take, 0, sizeof(int16_t) * (size_t)(per_pass - take)); }
        int written = 0;
        unsigned char *data = shine_encode_buffer_interleaved(encoder, frame, &written);
        if (!append(&out, &size, &capacity, data, written)) { size = -1; break; }
    }
    if (size >= 0) {
        int written = 0;
        unsigned char *data = shine_flush(encoder, &written);
        if (!append(&out, &size, &capacity, data, written)) { size = -1; }
    }
    shine_close(encoder);
    free(frame);
    if (size <= 0) { free(out); return NULL; }
    *out_size = size;
    return out;
}

void iroha_mp3_free(void *buffer) {
    free(buffer);
}
