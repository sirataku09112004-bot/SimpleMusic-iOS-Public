#include "OpusBridge.h"
#include <vorbis/vorbisfile.h>
#include <stdlib.h>

void *SMVorbisOpen(const char *path, int64_t *frames, int *channels, int *rate, int *error) {
    OggVorbis_File *file = calloc(1, sizeof(*file));
    if (!file) { *error = -1004; return NULL; }
    *error = ov_fopen(path, file);
    if (*error) { free(file); return NULL; }
    vorbis_info *info = ov_info(file, 0);
    if (!info || ov_streams(file) != 1) *error = -1001;
    else {
        *channels = info->channels;
        *rate = (int)info->rate;
        *frames = ov_pcm_total(file, -1);
        if (*channels < 1 || *channels > 2) *error = -1002;
        if (*rate < 8000 || *rate > 192000 || *frames <= 0) *error = -1003;
    }
    if (*error) { ov_clear(file); free(file); return NULL; }
    return file;
}
int SMVorbisRead(void *decoder, float *pcm, int capacity) {
    OggVorbis_File *file = decoder;
    int channels = ov_info(file, 0)->channels, frames = 0;
    if (capacity < channels || capacity > 48000 * 2) return -1005;
    while (frames < capacity / channels) {
        float **planes = NULL;
        int link = 0;
        long result = ov_read_float(file, &planes, capacity / channels - frames, &link);
        if (result < 0) return (int)result;
        if (!result) break;
        if (link != 0) return -1001;
        for (long i = 0; i < result; i++)
            for (int ch = 0; ch < channels; ch++)
                pcm[(frames + i) * channels + ch] = planes[ch][i];
        frames += (int)result;
    }
    return frames;
}
int SMVorbisSeek(void *decoder, int64_t frame) { return ov_pcm_seek(decoder, frame); }
void SMVorbisClose(void *decoder) {
    if (decoder) { ov_clear(decoder); free(decoder); }
}
