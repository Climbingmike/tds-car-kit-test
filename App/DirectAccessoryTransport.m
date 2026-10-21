#import "DirectAccessoryTransport.h"
#import <TargetConditionals.h>
#import <objc/message.h>

@interface DirectAccessoryTransport ()
@property(nonatomic, strong) id client;
@property(nonatomic, copy) NSString *connection;
@property(nonatomic, copy) NSString *endpoint;
@property(nonatomic, strong) NSUUID *generation;
@end

@implementation DirectAccessoryTransport
static BOOL Failed(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"TDSCarKit.DirectTransport" code:1
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL HasMethod(id object, NSString *name, NSUInteger arguments) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] &&
           [object methodSignatureForSelector:selector].numberOfArguments == arguments + 2;
}
- (BOOL)startWithIdentifier:(NSString *)identifier transportType:(NSUInteger)transportType error:(NSError **)error {
    [self stop];
    if (transportType != 2 && transportType != 8) return Failed(error, @"Unsupported local transport type.");
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    return Failed(error, @"This transport test requires a physical iPhone; Catalyst and Simulator are not supported.");
#else
    @try {
        Class cls = NSClassFromString(@"ACCTransportClient");
        if (!cls) {
            [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/CoreAccessories.framework"] load];
            cls = NSClassFromString(@"ACCTransportClient");
        }
        if (!cls || !HasMethod(cls, @"sharedClient", 0))
            return Failed(error, @"CoreAccessories ACCTransportClient is unavailable on this iOS build.");
        self.client = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedClient"));
        NSString *create = @"createConnectionWithType:andIdentifier:";
        NSString *endpoint = @"createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:";
        if (!HasMethod(self.client, create, 2) || !HasMethod(self.client, endpoint, 6) ||
            !HasMethod(self.client, @"processIncomingData:forEndpointWithUUID:", 2) ||
            !HasMethod(self.client, @"destroyEndpointWithUUID:", 1) ||
            !HasMethod(self.client, @"destroyConnectionWithUUID:", 1)) {
            [self stop];
            return Failed(error, @"CoreAccessories transport methods are unavailable or have changed.");
        }
        // Try connection type 2, then 1; the Wi-Fi endpoint uses transport type 2.
        id connection = ((id (*)(id, SEL, NSUInteger, id))objc_msgSend)(self.client, NSSelectorFromString(create), 2, identifier);
        if (!connection) connection = ((id (*)(id, SEL, NSUInteger, id))objc_msgSend)(self.client, NSSelectorFromString(create), 1, identifier);
        if (![connection isKindOfClass:NSString.class]) {
            [self stop];
            return Failed(error, @"CoreAccessories refused the connection. This signed app may lack access to the private transport.");
        }
        self.connection = connection;
        self.generation = NSUUID.UUID;
        NSUUID *generation = self.generation;
        __weak DirectAccessoryTransport *weakSelf = self;
        // Transport callback signature: v32@?0@\"NSString\"8@\"NSString\"16@\"NSData\"24.
        void (^handler)(NSString *, NSString *, NSData *) = ^(NSString *a, NSString *b, NSData *data) {
            if (![data isKindOfClass:NSData.class] || data.length > 65536) return;
            NSData *copy = [data copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                DirectAccessoryTransport *strongSelf = weakSelf;
                if ([strongSelf.generation isEqual:generation] && strongSelf.onData) strongSelf.onData(copy);
            });
        };
        id result = ((id (*)(id, SEL, NSUInteger, NSUInteger, id, id, id, BOOL))objc_msgSend)(
            self.client, NSSelectorFromString(endpoint), transportType, 4, nil, handler, self.connection, YES);
        if (![result isKindOfClass:NSString.class]) {
            [self stop];
            return Failed(error, @"CoreAccessories refused to publish an iAP2 endpoint.");
        }
        self.endpoint = result;
        return YES;
    } @catch (NSException *exception) {
        [self stop];
        return Failed(error, [NSString stringWithFormat:@"CoreAccessories exception: %@", exception.name]);
    }
#endif
}
- (BOOL)sendData:(NSData *)data error:(NSError **)error {
    if (!self.endpoint || !self.client) return Failed(error, @"Direct transport is not open.");
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(self.client,
            NSSelectorFromString(@"processIncomingData:forEndpointWithUUID:"), data, self.endpoint);
        return YES;
    } @catch (NSException *exception) {
        return Failed(error, [NSString stringWithFormat:@"CoreAccessories write exception: %@", exception.name]);
    }
}
- (void)stop {
    self.generation = nil;
    @try {
        if (self.endpoint && HasMethod(self.client, @"destroyEndpointWithUUID:", 1))
            ((void (*)(id, SEL, id))objc_msgSend)(self.client, NSSelectorFromString(@"destroyEndpointWithUUID:"), self.endpoint);
    } @catch (NSException *exception) { /* Continue cleaning up the connection. */ }
    @try {
        if (self.connection && HasMethod(self.client, @"destroyConnectionWithUUID:", 1))
            ((void (*)(id, SEL, id))objc_msgSend)(self.client, NSSelectorFromString(@"destroyConnectionWithUUID:"), self.connection);
    } @catch (NSException *exception) { /* State is cleared even when the OS refuses cleanup. */ }
    self.endpoint = nil; self.connection = nil; self.client = nil;
}
- (void)dealloc { [self stop]; }
@end
