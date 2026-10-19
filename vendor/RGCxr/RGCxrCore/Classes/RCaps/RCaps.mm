//
//  RCaps.m
//  Caps
//
//  Created by Amos on 2024/12/9.
//

#import "RCaps.h"
#include "caps.h"

using namespace rokid;

static const uint32_t CAPS_BUFSIZE = 0x200000;

@interface RCaps() {
    Caps _caps;
    uint8_t* buffer;
    NSData *_data;
}

@end

@implementation RCaps

- (instancetype)initWithCaps:(const rokid::Caps&)caps {
    self = [super init];
    if (self) {
        buffer = new uint8_t[CAPS_BUFSIZE];
        _caps = caps;
    }
    return self;
}

- (rokid::Caps&)caps {
    return _caps;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        buffer = new uint8_t[CAPS_BUFSIZE];
    }
    return self;
}

- (void)dealloc
{
    if (buffer)
        delete[] buffer;
}

- (void)write_Int32:(int32_t) v {
    _caps.write((int32_t)v);
}

- (void)write_UInt32:(uint32_t) v {
    _caps.write((uint32_t)v);
}

- (void)write_Int64:(int64_t) v {
    _caps.write(v);
}

- (void)write_UInt64:(uint64_t) v {
    _caps.write(v);
}

- (void)write_Float:(float) v {
    _caps.write(v);
}

- (void)write_Double:(double) v {
    _caps.write(v);
}

- (void)write_String:(NSString *) v {
    _caps.write([v UTF8String]);
}

- (void)write_Binary:(NSData *) v {
    if (v == nil) {
        return;
    }
    const void *bytes = [v bytes];
    uint32_t len = (uint32_t)[v length];
    _caps.write(bytes, len);
}

- (void)write_Caps:(RCaps *) v {
    _caps.write(v->_caps);
}

- (int)size {
    return _caps.size();
}

- (NSString *)type:(int) idx {
    char type = _caps[idx].type();
    char ret[2]{ type, '\0'};
    return [NSString stringWithUTF8String: ret];
}

- (int32_t)read_Int32:(int) idx {
    try {
        int32_t v = _caps[idx];
        return v;
    } catch (std::exception& e) {
        return -999;
    }
}

- (uint32_t)read_UInt32:(int) idx {
    try {
        uint32_t v = _caps[idx];
        return v;
    } catch (std::exception& e) {
        return -999;
    }
}

- (int64_t)read_Int64:(int) idx {
    try {
        int64_t v = _caps[idx];
        return v;
    } catch (std::exception& e) {
        return -999;
    }
}

- (uint64_t)read_UInt64:(int) idx {
    try {
        uint64_t v = _caps[idx];
        return v;
    } catch (std::exception& e) {
        return -999;
    }
}

- (float)read_Float:(int) idx {
    try {
        float v = _caps[idx];
        return v;
    } catch (std::exception& e) {
        return -999;
    }
}

- (double)read_Double:(int) idx {
    try {
        double v = _caps[idx];
        return v;
    } catch (std::exception& e) {
        return -999;
    }
}

- (nullable NSString *)read_String:(int) idx {
    try {
        return [NSString stringWithUTF8String: _caps[idx]];
    } catch (std::exception& e) {
        return nil;
    }
}

- (nullable NSData *)read_Binary:(int) idx {
    uint32_t result;
    try {
        result = _caps[idx].read(buffer, CAPS_BUFSIZE);
    } catch (std::exception& e) {
        NSLog(@"exception: %s", e.what());
        return nil;
    }
    
    NSData *outData = [NSData dataWithBytes: buffer length: result];
    return outData;
}

- (nullable RCaps *)read_Caps:(int) idx {
    try {
        RCaps *caps = [RCaps new];
        caps->_caps = _caps[idx];
        return caps;
    } catch (std::exception& e) {
        return nil;
    }
}

- (nullable NSData *)serialize {
    uint32_t result;
    try {
        result = _caps.serialize(buffer, CAPS_BUFSIZE);
        if (result == 0) {
            NSLog(@"serialize failed");
            return nil;
        }
    } catch (std::exception& e) {
        NSLog(@"exception: %s", e.what());
        return nil;
    }
    
    NSData *outData = [NSData dataWithBytes: buffer length: result];
    return outData;
}

- (int)parse:(NSData*) data {
    _data = data;
    return _caps.parse2([data bytes], (uint32_t)[data length]);
}

- (NSData *)data {
    return  _data;
}

@end
