// applepye.h
#ifndef APPLEPYE_H
#define APPLEPYE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize Python interpreter. Call once before first execute.
void applepye_initialize(void);

// Execute code and return a malloc'd C string containing captured output.
// Caller must free() the returned pointer. Never returns NULL (returns empty string if no output).
char* applepye_execute(const char* code);

// Finalize interpreter if desired (optional).
void applepye_finalize(void);

#ifdef __cplusplus
}
#endif

#endif // APPLEPYE_H
