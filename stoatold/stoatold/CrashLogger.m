#import "CrashLogger.h"
#import <signal.h>
#import <execinfo.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <stdio.h>

static char gCrashFilePath[1024];

static void safeWrite(int fd, const char *s) {
    if (s) write(fd, s, strlen(s));
}

static void signalHandler(int signo, siginfo_t *info, void *ctx) {
    int fd = open(gCrashFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { signal(signo, SIG_DFL); raise(signo); return; }

    char buf[256];
    const char *name = "UNKNOWN";
    if (signo == SIGSEGV) name = "SIGSEGV (bad memory access)";
    else if (signo == SIGBUS)  name = "SIGBUS (bus error)";
    else if (signo == SIGABRT) name = "SIGABRT (abort)";
    else if (signo == SIGILL)  name = "SIGILL (illegal instruction)";
    else if (signo == SIGFPE)  name = "SIGFPE (float exception)";
    else if (signo == SIGTRAP) name = "SIGTRAP (Swift runtime trap / fatalError / nil-unwrap)";
    else if (signo == SIGSYS)  name = "SIGSYS (bad syscall)";

    snprintf(buf, sizeof(buf), "SIGNAL: %s\n\nBacktrace:\n", name);
    safeWrite(fd, buf);

    void *callstack[32];
    int frames = backtrace(callstack, 32);
    backtrace_symbols_fd(callstack, frames, fd);

    close(fd);
    signal(signo, SIG_DFL);
    raise(signo);
}

static void exceptionHandler(NSException *ex) {
    int fd = open(gCrashFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    safeWrite(fd, "EXCEPTION: ");
    safeWrite(fd, ex.name.UTF8String ?: "?");
    safeWrite(fd, "\nReason: ");
    safeWrite(fd, ex.reason.UTF8String ?: "?");
    safeWrite(fd, "\n\nStack:\n");
    for (NSString *sym in ex.callStackSymbols) {
        safeWrite(fd, sym.UTF8String ?: "?");
        safeWrite(fd, "\n");
    }
    close(fd);
}

void CrashLoggerInstall(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *path = [docs[0] stringByAppendingPathComponent:@"stoat_crash.txt"];
    strlcpy(gCrashFilePath, path.UTF8String, sizeof(gCrashFilePath));

    NSSetUncaughtExceptionHandler(exceptionHandler);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = signalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGSYS,  &sa, NULL);
}

NSString *CrashLoggerRead(void) {
    NSString *path = gCrashFilePath[0]
        ? [NSString stringWithUTF8String:gCrashFilePath]
        : [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
           stringByAppendingPathComponent:@"stoat_crash.txt"];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

void CrashLoggerClear(void) {
    NSString *path = gCrashFilePath[0]
        ? [NSString stringWithUTF8String:gCrashFilePath]
        : [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
           stringByAppendingPathComponent:@"stoat_crash.txt"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

static char gBreadcrumbPath[1024];

static void ensureBreadcrumbPath(void) {
    if (gBreadcrumbPath[0]) return;
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [docs[0] stringByAppendingPathComponent:@"stoat_breadcrumbs.txt"];
    strlcpy(gBreadcrumbPath, p.UTF8String, sizeof(gBreadcrumbPath));
}

void CrashLoggerBreadcrumb(const char *msg) {
    ensureBreadcrumbPath();
    int fd = open(gBreadcrumbPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    if (msg) write(fd, msg, strlen(msg));
    write(fd, "\n", 1);
    close(fd);
}

NSString *CrashLoggerReadBreadcrumbs(void) {
    ensureBreadcrumbPath();
    return [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:gBreadcrumbPath]
                                     encoding:NSUTF8StringEncoding error:nil];
}

void CrashLoggerClearBreadcrumbs(void) {
    ensureBreadcrumbPath();
    [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:gBreadcrumbPath] error:nil];
}
