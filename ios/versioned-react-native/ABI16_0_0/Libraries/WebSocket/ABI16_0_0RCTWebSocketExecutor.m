/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ABI16_0_0RCTWebSocketExecutor.h"

#import <ReactABI16_0_0/ABI16_0_0RCTAssert.h>
#import <ReactABI16_0_0/ABI16_0_0RCTBridge.h>
#import <ReactABI16_0_0/ABI16_0_0RCTConvert.h>
#import <ReactABI16_0_0/ABI16_0_0RCTDefines.h>
#import <ReactABI16_0_0/ABI16_0_0RCTLog.h>
#import <ReactABI16_0_0/ABI16_0_0RCTUtils.h>

#import "ABI16_0_0RCTSRWebSocket.h"

#if ABI16_0_0RCT_DEV // Debug executors are only supported in dev mode

typedef void (^ABI16_0_0RCTWSMessageCallback)(NSError *error, NSDictionary<NSString *, id> *reply);

@interface ABI16_0_0RCTWebSocketExecutor () <ABI16_0_0RCTSRWebSocketDelegate>

@end

@implementation ABI16_0_0RCTWebSocketExecutor
{
  ABI16_0_0RCTSRWebSocket *_socket;
  dispatch_queue_t _jsQueue;
  NSMutableDictionary<NSNumber *, ABI16_0_0RCTWSMessageCallback> *_callbacks;
  dispatch_semaphore_t _socketOpenSemaphore;
  NSMutableDictionary<NSString *, NSString *> *_injectedObjects;
  NSURL *_url;
  NSError *_setupError;
}

ABI16_0_0RCT_EXPORT_MODULE()

@synthesize bridge = _bridge;

- (instancetype)initWithURL:(NSURL *)URL
{
  ABI16_0_0RCTAssertParam(URL);

  if ((self = [self init])) {
    _url = URL;
  }
  return self;
}

- (void)setUp
{
  if (!_url) {
    NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];

    // TODO t16297016: this seems to be unused, remove?
    NSInteger port = [standardDefaults integerForKey:@"websocket-executor-port"];
    if (!port) {
      port = [[[_bridge bundleURL] port] integerValue] ?: 8081;
    }

    NSString *host = [[_bridge bundleURL] host];
    if (!host) {
      host = @"localhost";
    }
    NSString *URLString = [NSString stringWithFormat:@"http://%@:%zd/debugger-proxy?role=client", host, port];
    _url = [ABI16_0_0RCTConvert NSURL:URLString];
  }

  _jsQueue = dispatch_queue_create("com.facebook.ReactABI16_0_0.WebSocketExecutor", DISPATCH_QUEUE_SERIAL);
  _socket = [[ABI16_0_0RCTSRWebSocket alloc] initWithURL:_url];
  _socket.delegate = self;
  _callbacks = [NSMutableDictionary new];
  _injectedObjects = [NSMutableDictionary new];
  [_socket setDelegateDispatchQueue:_jsQueue];

  NSURL *startDevToolsURL = [NSURL URLWithString:@"/launch-js-devtools" relativeToURL:_url];

  NSURLSession *session = [NSURLSession sharedSession];
  NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:[NSURLRequest requestWithURL:startDevToolsURL]
                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error){}];
  [dataTask resume];
  if (![self connectToProxy]) {
    [self invalidate];
    NSString *error = [NSString stringWithFormat:@"Connection to %@ timed out. Are you "
                       "running node proxy? If you are running on the device, check if "
                       "you have the right IP address in `ABI16_0_0RCTWebSocketExecutor.m`.", _url];
    _setupError = ABI16_0_0RCTErrorWithMessage(error);
    ABI16_0_0RCTFatal(_setupError);
    return;
  }

  NSInteger retries = 3;
  BOOL runtimeIsReady = [self prepareJSRuntime];
  while (!runtimeIsReady && retries > 0) {
    runtimeIsReady = [self prepareJSRuntime];
    retries--;
  }
  if (!runtimeIsReady) {
    [self invalidate];
    NSString *error = @"Runtime is not ready for debugging.\n "
                      "- Make sure Packager server is running.\n"
                      "- Make sure the JavaScript Debugger is running and not paused on a "
                      "breakpoint or exception and try reloading again.";
    _setupError = ABI16_0_0RCTErrorWithMessage(error);
    ABI16_0_0RCTFatal(_setupError);
    return;
  }
}

- (BOOL)connectToProxy
{
  _socketOpenSemaphore = dispatch_semaphore_create(0);
  [_socket open];
  long connected = dispatch_semaphore_wait(_socketOpenSemaphore, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 10));
  return connected == 0 && _socket.readyState == ABI16_0_0RCTSR_OPEN;
}

- (BOOL)prepareJSRuntime
{
  __block NSError *initError;
  dispatch_semaphore_t s = dispatch_semaphore_create(0);
  [self sendMessage:@{@"method": @"prepareJSRuntime"} onReply:^(NSError *error, NSDictionary<NSString *, id> *reply) {
    initError = error;
    dispatch_semaphore_signal(s);
  }];
  long runtimeIsReady = dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
  if (initError) {
    ABI16_0_0RCTLogInfo(@"Websocket runtime setup failed: %@", initError);
  }
  return runtimeIsReady == 0 && initError == nil;
}

- (void)webSocket:(ABI16_0_0RCTSRWebSocket *)webSocket didReceiveMessage:(id)message
{
  NSError *error = nil;
  NSDictionary<NSString *, id> *reply = ABI16_0_0RCTJSONParse(message, &error);
  NSNumber *messageID = reply[@"replyID"];
  ABI16_0_0RCTWSMessageCallback callback = _callbacks[messageID];
  if (callback) {
    callback(error, reply);
    [_callbacks removeObjectForKey:messageID];
  }
}

- (void)webSocketDidOpen:(ABI16_0_0RCTSRWebSocket *)webSocket
{
  dispatch_semaphore_signal(_socketOpenSemaphore);
}

- (void)webSocket:(ABI16_0_0RCTSRWebSocket *)webSocket didFailWithError:(NSError *)error
{
  dispatch_semaphore_signal(_socketOpenSemaphore);
  ABI16_0_0RCTLogInfo(@"WebSocket connection failed with error %@", error);
}

- (void)sendMessage:(NSDictionary<NSString *, id> *)message onReply:(ABI16_0_0RCTWSMessageCallback)callback
{
  static NSUInteger lastID = 10000;

  if (_setupError) {
    callback(_setupError, nil);
    return;
  }

  dispatch_async(_jsQueue, ^{
    if (!self.valid) {
      NSError *error = [NSError errorWithDomain:@"WS" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"Runtime is not ready for debugging. Make sure Packager server is running."
      }];
      callback(error, nil);
      return;
    }

    NSNumber *expectedID = @(lastID++);
    self->_callbacks[expectedID] = [callback copy];
    NSMutableDictionary<NSString *, id> *messageWithID = [message mutableCopy];
    messageWithID[@"id"] = expectedID;
    [self->_socket send:ABI16_0_0RCTJSONStringify(messageWithID, NULL)];
  });
}

- (void)executeApplicationScript:(NSData *)script sourceURL:(NSURL *)URL onComplete:(ABI16_0_0RCTJavaScriptCompleteBlock)onComplete
{
  NSDictionary<NSString *, id> *message = @{
    @"method": @"executeApplicationScript",
    @"url": ABI16_0_0RCTNullIfNil(URL.absoluteString),
    @"inject": _injectedObjects,
  };
  [self sendMessage:message onReply:^(NSError *error, NSDictionary<NSString *, id> *reply) {
    onComplete(error);
  }];
}

- (void)flushedQueue:(ABI16_0_0RCTJavaScriptCallback)onComplete
{
  [self _executeJSCall:@"flushedQueue" arguments:@[] callback:onComplete];
}

- (void)callFunctionOnModule:(NSString *)module
                      method:(NSString *)method
                   arguments:(NSArray *)args
                    callback:(ABI16_0_0RCTJavaScriptCallback)onComplete
{
  [self _executeJSCall:@"callFunctionReturnFlushedQueue" arguments:@[module, method, args] callback:onComplete];
}

- (void)invokeCallbackID:(NSNumber *)cbID
               arguments:(NSArray *)args
                callback:(ABI16_0_0RCTJavaScriptCallback)onComplete
{
  [self _executeJSCall:@"invokeCallbackAndReturnFlushedQueue" arguments:@[cbID, args] callback:onComplete];
}

- (void)_executeJSCall:(NSString *)method arguments:(NSArray *)arguments callback:(ABI16_0_0RCTJavaScriptCallback)onComplete
{
  ABI16_0_0RCTAssert(onComplete != nil, @"callback was missing for exec JS call");
  NSDictionary<NSString *, id> *message = @{
    @"method": method,
    @"arguments": arguments
  };
  [self sendMessage:message onReply:^(NSError *socketError, NSDictionary<NSString *, id> *reply) {
    if (socketError) {
      onComplete(nil, socketError);
      return;
    }

    NSString *result = reply[@"result"];
    id objcValue = ABI16_0_0RCTJSONParse(result, NULL);
    onComplete(objcValue, nil);
  }];
}

- (void)injectJSONText:(NSString *)script asGlobalObjectNamed:(NSString *)objectName callback:(ABI16_0_0RCTJavaScriptCompleteBlock)onComplete
{
  dispatch_async(_jsQueue, ^{
    self->_injectedObjects[objectName] = script;
    onComplete(nil);
  });
}

- (void)executeBlockOnJavaScriptQueue:(dispatch_block_t)block
{
  ABI16_0_0RCTExecuteOnMainQueue(block);
}

- (void)executeAsyncBlockOnJavaScriptQueue:(dispatch_block_t)block
{
  dispatch_async(dispatch_get_main_queue(), block);
}

- (void)invalidate
{
  _socket.delegate = nil;
  [_socket closeWithCode:1000 reason:@"Invalidated"];
  _socket = nil;
}

- (BOOL)isValid
{
  return _socket != nil && _socket.readyState == ABI16_0_0RCTSR_OPEN;
}

- (void)dealloc
{
  ABI16_0_0RCTAssert(!self.valid, @"-invalidate must be called before -dealloc");
}

@end

#endif
