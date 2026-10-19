//
//  RCaps.h
//  Caps
//
//  Created by Amos on 2024/12/9.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCaps : NSObject

- (nullable NSData *)serialize;

- (void)write_Int32:(int32_t) v;
- (void)write_UInt32:(uint32_t) v;
- (void)write_Int64:(int64_t) v;
- (void)write_UInt64:(uint64_t) v;
- (void)write_Float:(float) v;
- (void)write_Double:(double) v;
- (void)write_String:(NSString *) v;
- (void)write_Binary:(NSData *) v;
- (void)write_Caps:(RCaps *) v;

- (int)parse:(NSData*) data;
- (NSData *)data;

- (int)size;
- (NSString *)type:(int) idx;
    
- (int32_t)read_Int32:(int) idx;
- (uint32_t)read_UInt32:(int) idx;
- (int64_t)read_Int64:(int) idx;
- (uint64_t)read_UInt64:(int) idx;
- (float)read_Float:(int) idx;
- (double)read_Double:(int) idx;
- (nullable NSString *)read_String:(int) idx;
- (nullable NSData *)read_Binary:(int) idx;
- (nullable RCaps *)read_Caps:(int) idx;

@end


NS_ASSUME_NONNULL_END
