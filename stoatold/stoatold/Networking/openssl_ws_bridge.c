#include "openssl_ws_bridge.h"

#include <openssl/ssl.h>
#include <openssl/err.h>

#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>

struct OWSLContext {
    char             host[512];
    int              port;
    OWSL_read_cb     rcb;
    OWSL_event_cb    ecb;
    void            *userdata;

    int              sockfd;
    SSL_CTX         *ssl_ctx;
    SSL             *ssl;

    pthread_t        read_thread;
    int              read_thread_started;
    pthread_mutex_t  write_mutex;
    volatile int     closing;

    char             last_error[512];
};

/* One-time OpenSSL init (OpenSSL 3.x auto-inits but this is harmless) */
static pthread_once_t s_init_once = PTHREAD_ONCE_INIT;
static void owsl_global_init(void) {
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();
}

/* Background read loop — exits when closing=1 or SSL_read returns ≤0 */
static void *read_loop(void *arg) {
    OWSLContext *ctx = (OWSLContext *)arg;
    uint8_t buf[8192];

    while (!ctx->closing) {
        int n = SSL_read(ctx->ssl, buf, (int)sizeof(buf));
        if (n > 0) {
            ctx->rcb(buf, (size_t)n, ctx->userdata);
        } else {
            if (ctx->closing) break;
            int err = SSL_get_error(ctx->ssl, n);
            if (err == SSL_ERROR_ZERO_RETURN) {
                ctx->ecb(1, "eof", ctx->userdata);
            } else {
                char msg[256] = "ssl read error";
                unsigned long e = ERR_get_error();
                if (e != 0) ERR_error_string_n(e, msg, sizeof(msg));
                ctx->ecb(2, msg, ctx->userdata);
            }
            break;
        }
    }
    return NULL;
}

OWSLContext *owsl_create(const char *host, int port,
                          OWSL_read_cb rcb, OWSL_event_cb ecb, void *userdata) {
    pthread_once(&s_init_once, owsl_global_init);

    OWSLContext *ctx = (OWSLContext *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    strncpy(ctx->host, host, sizeof(ctx->host) - 1);
    ctx->port     = port;
    ctx->rcb      = rcb;
    ctx->ecb      = ecb;
    ctx->userdata = userdata;
    ctx->sockfd   = -1;
    pthread_mutex_init(&ctx->write_mutex, NULL);
    return ctx;
}

int owsl_connect(OWSLContext *ctx) {
    /* ── TCP ─────────────────────────────────────────────────────────────── */
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", ctx->port);

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    if (getaddrinfo(ctx->host, portStr, &hints, &res) != 0) {
        snprintf(ctx->last_error, sizeof(ctx->last_error),
                 "getaddrinfo failed for %s", ctx->host);
        return -1;
    }

    ctx->sockfd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (ctx->sockfd < 0) {
        freeaddrinfo(res);
        snprintf(ctx->last_error, sizeof(ctx->last_error), "socket() failed");
        return -2;
    }

    if (connect(ctx->sockfd, res->ai_addr, res->ai_addrlen) != 0) {
        freeaddrinfo(res);
        close(ctx->sockfd); ctx->sockfd = -1;
        snprintf(ctx->last_error, sizeof(ctx->last_error),
                 "connect() failed to %s:%d", ctx->host, ctx->port);
        return -3;
    }
    freeaddrinfo(res);

    /* ── TLS ─────────────────────────────────────────────────────────────── */
    ctx->ssl_ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx->ssl_ctx) {
        snprintf(ctx->last_error, sizeof(ctx->last_error), "SSL_CTX_new failed");
        return -4;
    }
    /* Skip cert validation — same as CFStream kCFStreamSSLValidatesCertificateChain=NO */
    SSL_CTX_set_verify(ctx->ssl_ctx, SSL_VERIFY_NONE, NULL);

    ctx->ssl = SSL_new(ctx->ssl_ctx);
    if (!ctx->ssl) {
        snprintf(ctx->last_error, sizeof(ctx->last_error), "SSL_new failed");
        return -5;
    }
    SSL_set_fd(ctx->ssl, ctx->sockfd);
    SSL_set_tlsext_host_name(ctx->ssl, ctx->host);  /* SNI */

    int ret = SSL_connect(ctx->ssl);
    if (ret != 1) {
        unsigned long e = ERR_get_error();
        if (e != 0)
            ERR_error_string_n(e, ctx->last_error, sizeof(ctx->last_error));
        else
            snprintf(ctx->last_error, sizeof(ctx->last_error),
                     "SSL_connect err=%d", SSL_get_error(ctx->ssl, ret));
        return -6;
    }
    return 0;
}

const char *owsl_last_error(OWSLContext *ctx) {
    return ctx ? ctx->last_error : "null context";
}

void owsl_start_reading(OWSLContext *ctx) {
    if (!ctx || ctx->read_thread_started) return;
    ctx->read_thread_started = 1;
    pthread_create(&ctx->read_thread, NULL, read_loop, ctx);
}

int owsl_write(OWSLContext *ctx, const uint8_t *data, size_t len) {
    if (!ctx || ctx->closing || !ctx->ssl) return -1;
    pthread_mutex_lock(&ctx->write_mutex);
    int n = -1;
    if (!ctx->closing && ctx->ssl)
        n = SSL_write(ctx->ssl, data, (int)len);
    pthread_mutex_unlock(&ctx->write_mutex);
    return n;
}

void owsl_close(OWSLContext *ctx) {
    if (!ctx) return;
    ctx->closing = 1;
    /* Hold write_mutex while shutting down so an in-flight SSL_write finishes first */
    pthread_mutex_lock(&ctx->write_mutex);
    if (ctx->ssl) SSL_shutdown(ctx->ssl);
    if (ctx->sockfd >= 0) {
        shutdown(ctx->sockfd, SHUT_RDWR);
        close(ctx->sockfd);
        ctx->sockfd = -1;
    }
    pthread_mutex_unlock(&ctx->write_mutex);
}

void owsl_destroy(OWSLContext *ctx) {
    if (!ctx) return;
    owsl_close(ctx);
    if (ctx->read_thread_started)
        pthread_join(ctx->read_thread, NULL);
    if (ctx->ssl)     { SSL_free(ctx->ssl);         ctx->ssl     = NULL; }
    if (ctx->ssl_ctx) { SSL_CTX_free(ctx->ssl_ctx); ctx->ssl_ctx = NULL; }
    pthread_mutex_destroy(&ctx->write_mutex);
    free(ctx);
}
