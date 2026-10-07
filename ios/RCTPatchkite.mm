#import <RNPatchkiteSpec/RNPatchkiteSpec.h>
#import <React/RCTReloadCommand.h>

#if __has_include(<PatchkiteReactNative/PatchkiteReactNative-Swift.h>)
#import <PatchkiteReactNative/PatchkiteReactNative-Swift.h>
#else
#import "PatchkiteReactNative-Swift.h"
#endif

// The interface is intentionally not exposed as a public header: C++ headers must not
// end up in the umbrella header of the `PatchkiteReactNative` Swift module.
@interface RCTPatchkite : NativePatchkiteSpecBase <NativePatchkiteSpec>
@end

@implementation RCTPatchkite

+ (NSString *)moduleName
{
  return @"Patchkite";
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativePatchkiteSpecJSI>(params);
}

static dispatch_queue_t patchkiteQueue(void)
{
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("dev.patchkite.queue", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

- (void)run:(id _Nullable (^)(NSError **error))block resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(patchkiteQueue(), ^{
    NSError *error = nil;
    id result = block(&error);
    if (error) {
      reject(@"PATCHKITE_ERROR", error.localizedDescription, error);
    } else {
      resolve(result ?: [NSNull null]);
    }
  });
}

- (void)getConfiguration:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) { return [PatchkiteCore.shared configuration]; } resolve:resolve reject:reject];
}

- (void)getUpdateMetadata:(NSInteger)updateState resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) { return [PatchkiteCore.shared updateMetadataWithState:updateState]; } resolve:resolve reject:reject];
}

- (void)downloadUpdate:(NSDictionary *)updatePackage resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  __weak RCTPatchkite *weakSelf = self;
  [self run:^id(NSError **e) {
    return [PatchkiteCore.shared downloadUpdate:updatePackage
                                     progress:^(double received, double total) {
                                       [weakSelf emitOnDownloadProgress:@{@"receivedBytes" : @(received), @"totalBytes" : @(total)}];
                                     }
                                        error:e];
  } resolve:resolve reject:reject];
}

- (void)installUpdate:(NSString *)packageHash installMode:(NSInteger)installMode resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) {
    [PatchkiteCore.shared installUpdate:packageHash error:e];
    return nil;
  } resolve:resolve reject:reject];
}

- (void)isFailedUpdate:(NSString *)packageHash resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) { return @([PatchkiteCore.shared isFailedUpdate:packageHash]); } resolve:resolve reject:reject];
}

- (void)isFirstRun:(NSString *)packageHash resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) { return @([PatchkiteCore.shared isFirstRun:packageHash]); } resolve:resolve reject:reject];
}

- (void)notifyApplicationReady:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) {
    [PatchkiteCore.shared notifyApplicationReady];
    return nil;
  } resolve:resolve reject:reject];
}

- (void)popRollbackReport:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) { return [PatchkiteCore.shared popRollbackReport]; } resolve:resolve reject:reject];
}

- (void)getValue:(NSString *)key resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) { return [PatchkiteCore.shared patchkiteValueForKey:key]; } resolve:resolve reject:reject];
}

- (void)setValue:(NSString *)key value:(NSString *)value resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [self run:^id(NSError **e) {
    [PatchkiteCore.shared setPatchkiteValue:value forKey:key];
    return nil;
  } resolve:resolve reject:reject];
}

- (void)restartApp
{
  dispatch_async(dispatch_get_main_queue(), ^{
    RCTTriggerReloadCommandListeners(@"Patchkite: update installed");
  });
}

- (void)clearUpdates
{
  [PatchkiteCore.shared clearUpdates];
}

@end
