#import "RTCAudioProbe.h"
#import <objc/message.h>
#import <objc/runtime.h>

NSString *RTCAudioProbeTouch(void) {
    @try {
        Class cls = NSClassFromString(@"RTCAudioSession");
        if (cls == Nil) {
            return @"RTCAudioSession class not found";
        }
        SEL shared = NSSelectorFromString(@"sharedInstance");
        if (![cls respondsToSelector:shared]) {
            return @"RTCAudioSession has no +sharedInstance";
        }
        id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id session = send((id)cls, shared);
        if (session == nil) {
            return @"+sharedInstance returned nil";
        }
        return [NSString stringWithFormat:@"OK: instantiated %@",
                NSStringFromClass(object_getClass(session))];
    }
    @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@ | %@", e.name, e.reason];
    }
    @catch (id other) {
        return @"non-NSException thrown (uncatchable hard crash class)";
    }
}
