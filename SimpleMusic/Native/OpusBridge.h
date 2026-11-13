#ifndef SM_OPUS_BRIDGE_H
#define SM_OPUS_BRIDGE_H
#include <stdint.h>
void *SMOpusOpen(const char *path, int64_t *frames, int *channels, int *error);
int SMOpusRead(void *decoder, float *pcm, int capacity);
int SMOpusSeek(void *decoder, int64_t frame);
int SMOpusArtist(void *decoder, char *utf8, int capacity);
void SMOpusClose(void *decoder);
void *SMVorbisOpen(const char *path, int64_t *frames, int *channels, int *rate, int *error);
int SMVorbisRead(void *decoder, float *pcm, int capacity);
int SMVorbisSeek(void *decoder, int64_t frame);
void SMVorbisClose(void *decoder);
#endif

