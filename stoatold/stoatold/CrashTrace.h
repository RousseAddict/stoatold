#ifndef CrashTrace_h
#define CrashTrace_h
#import <Foundation/Foundation.h>

/// Async-signal-safe crash backtrace logger.
/// Install() opens a log fd + installs signal handlers; on a fatal signal the
/// handler writes the signal number and a backtrace via backtrace_symbols_fd
/// (no Foundation/malloc in the handler). Read() returns the previous run's
/// trace; call it BEFORE Install() (Install truncates the file for this run).
void CrashTraceInstall(void);
NSString * _Nullable CrashTraceRead(void);
void CrashTraceClear(void);

/// Trivial sanity check that calling our Objective-C functions from Swift works.
NSString * _Nullable ProbePing(void);

#endif
