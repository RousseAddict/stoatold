#ifndef CrashLogger_h
#define CrashLogger_h
#import <Foundation/Foundation.h>
void CrashLoggerInstall(void);
NSString * _Nullable CrashLoggerRead(void);
void CrashLoggerClear(void);
void CrashLoggerBreadcrumb(const char *msg);
NSString * _Nullable CrashLoggerReadBreadcrumbs(void);
void CrashLoggerClearBreadcrumbs(void);
#endif
