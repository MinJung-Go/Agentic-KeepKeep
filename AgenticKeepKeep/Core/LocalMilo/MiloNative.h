#ifndef MILO_NATIVE_H
#define MILO_NATIVE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void * milo_cancel_create(void);
void milo_cancel_set(void * flag);
void milo_cancel_free(void * flag);
void * milo_engine_create(const char * model, const char * vision, void * flag);
void milo_engine_free(void * engine);
// Read on the same serial worker immediately after a failed create.
// -10 model, -11 context, -12 vision, -13 evaluation, -3 cancellation.
int milo_last_error_code(void);
// All engine functions run on one serial queue. Flag may be set from any thread.
// callback receives raw UTF-8 bytes, which may split a Unicode scalar.
typedef void (*milo_piece_callback)(const char *, size_t, void *);
int milo_generate(void * engine, const char * prompt, const uint8_t * image, size_t image_size,
                  int max_tokens, float temperature, void * flag,
                  milo_piece_callback callback, void * user, int * input_tokens, int * output_tokens);
// Same interface, JSON-object constrained decoding for recording/report Agents.
int milo_generate_json(void * engine, const char * prompt, const uint8_t * image, size_t image_size,
                  int max_tokens, float temperature, void * flag,
                  milo_piece_callback callback, void * user, int * input_tokens, int * output_tokens);
#ifdef __cplusplus
}
#endif
#endif
