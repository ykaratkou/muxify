#import <Foundation/Foundation.h>

// Only the private selectors used by Muxify. These protocols describe remote
// proxies, not classes formally adopting them: cast objects individually in Swift.
// Object results are nullable because a Device may disappear during a call.
@protocol MuxifySimDeviceType <NSObject>
@property (nonatomic, readonly, nullable) NSString *identifier;
@property (nonatomic, readonly) CGSize mainScreenSize;
@end

@protocol MuxifySimRuntime <NSObject>
@property (nonatomic, readonly, nullable) NSString *name;
@end

@protocol MuxifySimDevice <NSObject>
@property (nonatomic, readonly, nullable) NSUUID *UDID;
@property (nonatomic, readonly, nullable) NSString *name;
@property (nonatomic, readonly) NSUInteger state;
@property (nonatomic, readonly, nullable) NSString *stateString;
@property (nonatomic, readonly, nullable) id<MuxifySimDeviceType> deviceType;
@property (nonatomic, readonly, nullable) id<MuxifySimRuntime> runtime;
@property (nonatomic, readonly, nullable) NSString *runtimeIdentifier;
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly, nullable) id io;
- (unsigned int)lookup:(NSString *_Nonnull)service error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setHardwareKeyboardEnabled:(BOOL)enabled
                      keyboardType:(unsigned char)keyboardType
                             error:(NSError *_Nullable *_Nullable)error;
@end

@protocol MuxifySimDeviceSet <NSObject>
@property (nonatomic, readonly, nullable) NSArray *devices;
@end

@protocol MuxifySimDisplayDescriptorState <NSObject>
// 0 is built-in; 1 is an external display port.
@property (nonatomic, readonly) unsigned short displayClass;
@end

@protocol MuxifySimDisplayRenderable <NSObject>
@property (nonatomic, readonly) CGSize displaySize;
@end

@protocol MuxifySimDisplayIOSurfaceRenderable <NSObject>
// IOSurface, typed as id to avoid checked Swift bridging of a remote proxy.
@property (nonatomic, readonly, nullable) id framebufferSurface;
@end

@protocol MuxifySimScreen <NSObject>
- (void)registerScreenCallbacksWithUUID:(NSUUID *_Nonnull)uuid
                         callbackQueue:(dispatch_queue_t _Nonnull)queue
                         frameCallback:(void (^_Nonnull)(void))frameCallback
               surfacesChangedCallback:(void (^_Nonnull)(id _Nullable, id _Nullable))surfacesChangedCallback
             propertiesChangedCallback:(void (^_Nonnull)(id _Nullable))propertiesChangedCallback;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *_Nonnull)uuid;
@end

@protocol MuxifySimDeviceIOPortDescriptor <NSObject>
@property (nonatomic, readonly, nullable) id state;
@end

@protocol MuxifySimDeviceIOPort <NSObject>
@property (nonatomic, readonly, nullable) id descriptor;
@end

@protocol MuxifySimDeviceIO <NSObject>
@property (nonatomic, readonly, nullable) NSArray *ioPorts;
@end

@protocol MuxifySimServiceContext <NSObject>
- (nullable id<MuxifySimDeviceSet>)defaultDeviceSetWithError:(NSError *_Nullable *_Nullable)error;
@end

// The receiver is a class object; an instance method lets Swift call it through
// an existential without treating the selector as a static protocol requirement.
@protocol MuxifySimServiceContextClass <NSObject>
- (nullable id<MuxifySimServiceContext>)sharedServiceContextForDeveloperDir:(NSString *_Nonnull)developerDir
                                                                   error:(NSError *_Nullable *_Nullable)error;
@end
