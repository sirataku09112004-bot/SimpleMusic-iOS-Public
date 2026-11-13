#include "OpusBridge.h"
#include <opus/opusfile.h>
#include <string.h>
void *SMOpusOpen(const char *path, int64_t *frames, int *channels, int *error) {
    *error = 0;
    OggOpusFile *file = op_open_file(path, error);
    if (!file) return NULL;
    if (op_link_count(file) != 1) *error = -1001;
    *channels = op_channel_count(file, 0);
    if (*channels < 1 || *channels > 2) *error = -1002;
    *frames = op_pcm_total(file, -1);
    if (*frames <= 0) *error = -1003;
    if (*error) { op_free(file); return NULL; }
    return file;
}
int SMOpusRead(void *decoder, float *pcm, int capacity) {
    OggOpusFile *file = decoder;
    int channels = op_channel_count(file, 0), count = 0;
    if (capacity < channels || capacity > 48000 * 2) return -1005;
    while (capacity - count >= channels) {
        int link = 0;
        int result = op_read_float(file, pcm + count, capacity - count, &link);
        if (result < 0) return result;
        if (result == 0) break;
        if (link != 0) return -1001;
        count += result * channels;
    }
    return count / channels;
}
int SMOpusSeek(void *decoder, int64_t frame) { return op_pcm_seek(decoder, frame); }
int SMOpusArtist(void *decoder, char *utf8, int capacity) {
    const OpusTags *tags = op_tags(decoder, 0);
    if (!tags || capacity < 1) return 0;
    for (int i = 0; i < tags->comments; i++) {
        int size = tags->comment_lengths[i];
        const char *entry = tags->user_comments[i];
        if (size > 7 && opus_tagncompare("ARTIST", 6, entry) == 0) {
            int length = size - 7;
            if (length >= capacity) return -1006;
            memcpy(utf8, entry + 7, length);
            utf8[length] = 0;
            return length;
        }
    }
    utf8[0] = 0;
    return 0;
}
void SMOpusClose(void *decoder) { if (decoder) op_free(decoder); }