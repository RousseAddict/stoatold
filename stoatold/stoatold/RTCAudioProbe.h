#ifndef RTCAudioProbe_h
#define RTCAudioProbe_h
#import <Foundation/Foundation.h>

/// Touches WebRTC's RTCAudioSession singleton inside @try/@catch so an
/// unrecognized-selector NSException (an iOS 10+ AVAudioSession API missing on
/// iOS 6/7) becomes a readable string instead of a silent crash.
NSString * _Nullable RTCAudioProbeTouch(void);

#endif
