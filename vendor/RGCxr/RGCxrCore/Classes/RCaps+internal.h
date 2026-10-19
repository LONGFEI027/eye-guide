//
//  RCaps+RCaps_internal.h
//  RGCxrKit
//
//  Created by Ginger on 2025/4/7.
//

#import "RCaps.h"
#import "caps.h"

NS_ASSUME_NONNULL_BEGIN

@interface RCaps (Internal)

- (instancetype)initWithCaps:(const rokid::Caps&)caps;

- (rokid::Caps&)caps;


@end

NS_ASSUME_NONNULL_END
