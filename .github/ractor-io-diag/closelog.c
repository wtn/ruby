/* Diagnostic interposer for the ractor-io-diag hammer: records every open(2)
 * and close(2) with thread id and backtrace in a ring buffer, and dumps the
 * history of an fd when close(2) on it fails with EBADF. Loaded only into the
 * hammer's ruby processes via DYLD_INSERT_LIBRARIES. */
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

enum { EV_OPEN = 0, EV_CLOSE = 1 };
struct ev {
    uint64_t seq;
    uint64_t tid;
    struct timeval tv;
    int kind;
    int fd;
    int ret;
    int err;
    int depth;
    void *bt[32];
};

#define RING 8192
static struct ev ring[RING];
static uint64_t ring_n;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static int dumped;

static void
record(int kind, int fd, int ret, int err)
{
    pthread_mutex_lock(&mu);
    struct ev *e = &ring[ring_n % RING];
    e->seq = ring_n++;
    pthread_threadid_np(NULL, &e->tid);
    gettimeofday(&e->tv, NULL);
    e->kind = kind;
    e->fd = fd;
    e->ret = ret;
    e->err = err;
    e->depth = backtrace(e->bt, 32);
    pthread_mutex_unlock(&mu);
}

static void
dump_fd(int fd, const char *why)
{
    const char *dir = getenv("CLOSELOG_DIR");
    char path[1024];
    snprintf(path, sizeof(path), "%s/closelog-%d.txt", dir ? dir : ".", (int)getpid());
    int out = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (out < 0) return;
    char head[256];
    int n = snprintf(head, sizeof(head), "==== pid %d: %s on fd %d; history of fd %d (newest last), then the last 40 events ====\n",
                     (int)getpid(), why, fd, fd);
    write(out, head, n);
    pthread_mutex_lock(&mu);
    uint64_t start = ring_n > RING ? ring_n - RING : 0;
    for (int pass = 0; pass < 2; pass++) {
        for (uint64_t i = start; i < ring_n; i++) {
            struct ev *e = &ring[i % RING];
            int want = pass == 0 ? (e->fd == fd) : (i + 40 >= ring_n);
            if (!want) continue;
            n = snprintf(head, sizeof(head), "-- seq %llu t=%ld.%06d tid %llu %s fd=%d ret=%d errno=%d\n",
                         (unsigned long long)e->seq, (long)e->tv.tv_sec, (int)e->tv.tv_usec,
                         (unsigned long long)e->tid, e->kind == EV_OPEN ? "open" : "close", e->fd, e->ret, e->err);
            write(out, head, n);
            backtrace_symbols_fd(e->bt, e->depth, out);
        }
        if (pass == 0) { n = snprintf(head, sizeof(head), "---- last 40 events of any fd ----\n"); write(out, head, n); }
    }
    pthread_mutex_unlock(&mu);
    close(out);
}

static int
my_close(int fd)
{
    int r = close(fd);
    int e = errno;
    record(EV_CLOSE, fd, r, r < 0 ? e : 0);
    if (r < 0 && e == EBADF && fd > 2 && !dumped) {
        dumped = 1;
        dump_fd(fd, "close returned EBADF");
    }
    errno = e;
    return r;
}

static int
my_open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    int r = open(path, flags, mode);
    int e = errno;
    record(EV_OPEN, r, r, r < 0 ? e : 0);
    errno = e;
    return r;
}

DYLD_INTERPOSE(my_close, close)
DYLD_INTERPOSE(my_open, open)
