#import "CrashTrace.h"
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>

static int  gFd = -1;

// async-signal-safe integer writer (no snprintf)
static void write_int(int fd, long v) {
    char buf[24];
    int i = (int)sizeof(buf);
    buf[--i] = '\n';
    if (v == 0) {
        buf[--i] = '0';
    } else {
        int neg = v < 0;
        unsigned long x = neg ? (unsigned long)(-v) : (unsigned long)v;
        while (x > 0 && i > 0) { buf[--i] = (char)('0' + (x % 10)); x /= 10; }
        if (neg && i > 0) buf[--i] = '-';
    }
    write(fd, buf + i, (size_t)((int)sizeof(buf) - i));
}

static void crash_handler(int sig) {
    if (gFd >= 0) {
        const char *m = "SIG ";
        write(gFd, m, 4);
        write_int(gFd, sig);
        void *frames[64];
        int cnt = backtrace(frames, 64);
        backtrace_symbols_fd(frames, cnt, gFd);
        fsync(gFd);
        close(gFd);
        gFd = -1;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static NSString *tracePath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[dirs firstObject] stringByAppendingPathComponent:@"stoat_trace.txt"];
}

void CrashTraceInstall(void) {
    const char *path = [tracePath() fileSystemRepresentation];
    gFd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE };
    for (int i = 0; i < 6; i++) signal(sigs[i], crash_handler);
}

NSString *CrashTraceRead(void) {
    NSData *d = [NSData dataWithContentsOfFile:tracePath()];
    if (d.length == 0) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

void CrashTraceClear(void) {
    [[NSFileManager defaultManager] removeItemAtPath:tracePath() error:nil];
}

NSString *ProbePing(void) { return @"pong"; }
