#ifndef openssl_ws_bridge_h
#define openssl_ws_bridge_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OWSLContext OWSLContext;

/* Called on background thread with received bytes */
typedef void (*OWSL_read_cb)(const uint8_t *buf, size_t len, void *userdata);

/* Called on background thread for lifecycle events:
   kind 1 = EOF (clean close), kind 2 = error
   msg is valid only during the callback */
typedef void (*OWSL_event_cb)(int kind, const char *msg, void *userdata);

/* Create context. Does not connect. */
OWSLContext *owsl_create(const char *host, int port,
                         OWSL_read_cb rcb, OWSL_event_cb ecb, void *userdata);

/* TCP connect + TLS handshake. Blocking — call from background thread.
   Returns 0 on success, negative error code on failure. */
int owsl_connect(OWSLContext *ctx);

/* Human-readable description of the last error. */
const char *owsl_last_error(OWSLContext *ctx);

/* Start background read loop. Call once after owsl_connect succeeds. */
void owsl_start_reading(OWSLContext *ctx);

/* Write bytes. Thread-safe with owsl_start_reading. Returns bytes written or -1. */
int owsl_write(OWSLContext *ctx, const uint8_t *data, size_t len);

/* Signal close: shutdown TLS, close socket, wake read thread. */
void owsl_close(OWSLContext *ctx);

/* Join read thread and free all resources. Must be called from a background thread. */
void owsl_destroy(OWSLContext *ctx);

#ifdef __cplusplus
}
#endif

#endif /* openssl_ws_bridge_h */
