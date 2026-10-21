#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Direct accessory transport. All methods and callbacks run on the main queue.
@interface DirectAccessoryTransport : NSObject
@property(nonatomic, copy, nullable) void (^onData)(NSData *data);
- (BOOL)startWithIdentifier:(NSString *)identifier transportType:(NSUInteger)transportType error:(NSError **)error;
- (BOOL)sendData:(NSData *)data error:(NSError **)error;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
