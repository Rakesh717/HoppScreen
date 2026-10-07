#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Single receiver prototype; caller owns/free()s the answer or error string.
char *hopp_rtc_offer(const char *sdp, void (*request_keyframe)(void), bool *ok);
void hopp_rtc_frame(const uint8_t *avcc, size_t size, const uint8_t *config, size_t config_size,
                    int64_t pts_us, bool key);
#ifdef __cplusplus
}
#endif
