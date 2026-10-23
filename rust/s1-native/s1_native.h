#ifndef S1_NATIVE_H
#define S1_NATIVE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* API v1: UTF-8 JSON input, owned UTF-8 JSON output. Never free with the caller's allocator. */
char *s1_process_json(const uint8_t *input, size_t length);
void s1_free_string(char *value);
#ifdef __cplusplus
}
#endif
#endif
