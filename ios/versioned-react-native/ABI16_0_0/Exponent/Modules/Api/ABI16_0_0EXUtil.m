#import "ABI16_0_0EXUtil.h"
#import "ABI16_0_0EXUnversioned.h"
#import <ReactABI16_0_0/ABI16_0_0RCTUIManager.h>
#import <ReactABI16_0_0/ABI16_0_0RCTBridge.h>
#import <ReactABI16_0_0/ABI16_0_0RCTUtils.h>

@implementation ABI16_0_0EXUtil

ABI16_0_0RCT_EXPORT_MODULE(ExponentUtil);

@synthesize bridge = _bridge;

- (dispatch_queue_t)methodQueue
{
  return self.bridge.uiManager.methodQueue;
}

ABI16_0_0RCT_EXPORT_METHOD(reload)
{
  [[NSNotificationCenter defaultCenter] postNotificationName:@"EXKernelRefreshForegroundTaskNotification"
                                                      object:nil
                                                    userInfo:@{
                                                               @"bridge": self.bridge
                                                               }];
}

ABI16_0_0RCT_REMAP_METHOD(getCurrentLocaleAsync,
                 getCurrentLocaleWithResolver:(ABI16_0_0RCTPromiseResolveBlock)resolve
                 rejecter:(ABI16_0_0RCTPromiseRejectBlock)reject)
{
  NSArray<NSString *> *preferredLanguages = [NSLocale preferredLanguages];
  if (preferredLanguages.count > 0) {
    resolve(preferredLanguages[0]);
  } else {
    NSString *errMsg = @"This device does not indicate its locale";
    reject(@"E_NO_PREFERRED_LOCALE", errMsg, ABI16_0_0RCTErrorWithMessage(errMsg));
  }
}

@end
