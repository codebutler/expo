// Copyright 2016-present 650 Industries. All rights reserved.

#import <EXNotifications/EXAppIdProvider.h>
#import <EXNotifications/EXMessageUnscoper.h>
#import <EXNotifications/EXNotificationConverter.h>
#import <EXNotifications/EXNotifications.h>
#import <EXNotifications/EXScoper.h>
#import <EXNotifications/EXThreadSafeTokenDispatcher.h>
#import <EXNotifications/EXUserNotificationCenter.h>
#import <UMCore/UMEventEmitterService.h>

@interface EXNotifications ()

@property(strong, atomic) id<EXUserNotificationCenterProxy> userNotificationCenter;
@property(strong) NSString *appId;
@property(nonatomic, weak) UMModuleRegistry *moduleRegistry;
@property(nonatomic, weak) id<UMEventEmitterService> eventEmitter;
@property(nonatomic, weak) id<EXScoper> scoper;

@end

@implementation EXNotifications

UM_REGISTER_MODULE();

+ (const NSString *)exportedModuleName {
  return @"ExpoNotifications";
}

- (instancetype)init {
  if (self = [super init]) {
    self.userNotificationCenter = [EXUserNotificationCenter sharedInstance];
  }
  return self;
}

+ (const NSArray<Protocol *> *)exportedInterfaces {
  return @[ @protocol(UMEventEmitter) ];
}

- (void)setModuleRegistry:(UMModuleRegistry *)moduleRegistry {
  _moduleRegistry = moduleRegistry;
  _appId = [[_moduleRegistry getModuleImplementingProtocol:@protocol(EXAppIdProvider)] getAppId];
  _eventEmitter = [_moduleRegistry getModuleImplementingProtocol:@protocol(UMEventEmitterService)];
  _scoper = [_moduleRegistry getModuleImplementingProtocol:@protocol(EXScoper)];
}

UM_EXPORT_METHOD_AS(flushPendingUserInteractionsAsync,
                    flushPendingUserInteractionsAsync:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  [[EXThreadSafePostOffice sharedInstance]
      registerModuleAndFlushPendingUserIntercationsWithAppId:_appId
                                                     mailbox:self];
  resolve(nil);
}

UM_EXPORT_METHOD_AS(presentLocalNotificationAsync,
                    presentLocalNotificationAsync:(NSDictionary *)payload
                    resolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  if (!payload[@"data"]) {
    reject(@"E_NOTIF_NO_DATA", @"Attempted to send a local notification with no `data` property.",
           nil);
    return;
  }
  UNMutableNotificationContent *content = [self _localNotificationFromPayload:payload];

  NSMutableDictionary *userInfo = [content.userInfo mutableCopy];
  [userInfo setObject:@(YES) forKey:@"presentedByUser"];
  content.userInfo = userInfo;

  UNNotificationRequest *request =
      [UNNotificationRequest requestWithIdentifier:content.userInfo[@"id"]
                                           content:content
                                           trigger:nil];

  [self.userNotificationCenter
      addNotificationRequest:request
       withCompletionHandler:^(NSError *_Nullable error) {
         if (error) {
           reject(@"E_NOTIF",
                  [NSString stringWithFormat:@"Could not add a notification request: %@",
                                             error.localizedDescription],
                  error);
         } else {
           resolve(content.userInfo[@"id"]);
         }
       }];
}

UM_EXPORT_METHOD_AS(scheduleNotificationWithTimerAsync,
                    scheduleNotificationWithTimerAsync:(NSDictionary *)payload
                    withOptions:(NSDictionary *)options
                    resolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  if (!payload[@"data"]) {
    reject(@"E_NOTIF_NO_DATA", @"Attempted to send a local notification with no `data` property.",
           nil);
    return;
  }
  BOOL repeats = [options[@"repeat"] boolValue];
  int seconds = [options[@"interval"] intValue] / 1000;
  UNTimeIntervalNotificationTrigger *notificationTrigger =
      [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:seconds repeats:repeats];
  UNMutableNotificationContent *content = [self _localNotificationFromPayload:payload];
  UNNotificationRequest *request =
      [UNNotificationRequest requestWithIdentifier:content.userInfo[@"id"]
                                           content:content
                                           trigger:notificationTrigger];
  [_userNotificationCenter addNotificationRequest:request
                            withCompletionHandler:^(NSError *_Nullable error) {
                              if (error) {
                                reject(@"E_NOTIF_REQ", error.localizedDescription, error);
                              } else {
                                resolve(content.userInfo[@"id"]);
                              }
                            }];
}

UM_EXPORT_METHOD_AS(scheduleNotificationWithCalendarAsync,
                    scheduleNotificationWithCalendarAsync:(NSDictionary *)payload
                    withOptions:(NSDictionary *)options
                    resolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  if (!payload[@"data"]) {
    reject(@"E_NOTIF_NO_DATA", @"Attempted to send a local notification with no `data` property.",
           nil);
    return;
  }
  UNCalendarNotificationTrigger *notificationTrigger = [self calendarTriggerFrom:options];
  UNMutableNotificationContent *content = [self _localNotificationFromPayload:payload];
  UNNotificationRequest *request =
      [UNNotificationRequest requestWithIdentifier:content.userInfo[@"id"]
                                           content:content
                                           trigger:notificationTrigger];
  [_userNotificationCenter addNotificationRequest:request
                            withCompletionHandler:^(NSError *_Nullable error) {
                              if (error) {
                                reject(@"E_NOTIF_REQ", error.localizedDescription, error);
                              } else {
                                resolve(content.userInfo[@"id"]);
                              }
                            }];
}

UM_EXPORT_METHOD_AS(cancelScheduledNotificationAsync,
                    cancelScheduledNotificationAsync:(NSString *)uniqueId
                    withResolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  __weak id<EXUserNotificationCenterProxy> userNotificationCenter = _userNotificationCenter;
  [_userNotificationCenter getPendingNotificationRequestsWithCompletionHandler:^(
                               NSArray<UNNotificationRequest *> *_Nonnull requests) {
    for (UNNotificationRequest *request in requests) {
      if ([request.content.userInfo[@"id"] isEqualToString:uniqueId]) {
        [userNotificationCenter
            removePendingNotificationRequestsWithIdentifiers:@[ request.identifier ]];
        resolve(nil);
        return;
      }
    }
    reject(
        @"E_NO_NOTIF",
        [NSString
            stringWithFormat:@"Could not find pending notification request to cancel with id = %@",
                             uniqueId],
        nil);
  }];
}

UM_EXPORT_METHOD_AS(cancelAllScheduledNotificationsAsync,
                  cancelAllScheduledNotificationsAsyncWithResolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  __weak id<EXUserNotificationCenterProxy> userNotificationCenter = _userNotificationCenter;
  [_userNotificationCenter getPendingNotificationRequestsWithCompletionHandler:^(
                               NSArray<UNNotificationRequest *> *_Nonnull requests) {
    NSMutableArray<NSString *> *requestsToCancelIdentifiers = [NSMutableArray new];
    for (UNNotificationRequest *request in requests) {
      if ([request.content.userInfo[@"appId"] isEqualToString:self.appId]) {
        [requestsToCancelIdentifiers addObject:request.identifier];
      }
    }
    [userNotificationCenter
        removePendingNotificationRequestsWithIdentifiers:requestsToCancelIdentifiers];
    resolve(nil);
  }];
}

#pragma mark - Badges

// TODO: Make this read from the kernel instead of UIApplication for the main Exponent app

UM_EXPORT_METHOD_AS(getBadgeNumberAsync,
                    getBadgeNumberAsyncWithResolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  __block NSInteger badgeNumber;
  dispatch_async(dispatch_get_main_queue(), ^{
    badgeNumber = [UIApplication sharedApplication].applicationIconBadgeNumber;
  });

  resolve(@(badgeNumber));
}

UM_EXPORT_METHOD_AS(setBadgeNumberAsync,
                    setBadgeNumberAsync:(nonnull NSNumber *)number
                    resolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIApplication sharedApplication].applicationIconBadgeNumber = number.integerValue;
  });
  resolve(nil);
}

UM_EXPORT_METHOD_AS(registerForPushNotificationsAsync,
                    registerForPushNotificationsAsync:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  [[EXThreadSafeTokenDispatcher sharedInstance] registerForPushTokenWithAppId:_appId
                                                        onTokenChangeListener:self];
  resolve(nil);
}

#pragma mark - Categories

UM_EXPORT_METHOD_AS(createCategoryAsync,
                    createCategoryWithCategoryId:(NSString *)categoryId
                    actions:(NSArray *)actions
                    resolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  NSMutableArray<UNNotificationAction *> *actionsArray = [[NSMutableArray alloc] init];
  for (NSDictionary<NSString *, id> *actionParams in actions) {
    [actionsArray addObject:[self parseNotificationActionFromParams:actionParams]];
  }

  UNNotificationCategory *newCategory =
      [UNNotificationCategory categoryWithIdentifier:[self internalIdForIdentifier:categoryId]
                                             actions:actionsArray
                                   intentIdentifiers:@[]
                                             options:UNNotificationCategoryOptionNone];

  __weak id<EXUserNotificationCenterProxy> userNotificationCenter = _userNotificationCenter;
  [_userNotificationCenter getNotificationCategoriesWithCompletionHandler:^(
                               NSSet<UNNotificationCategory *> *categories) {
    NSMutableSet<UNNotificationCategory *> *newCategories = [categories mutableCopy];
    for (UNNotificationCategory *category in newCategories) {
      if ([category.identifier isEqualToString:newCategory.identifier]) {
        [newCategories removeObject:category];
        break;
      }
    }
    [newCategories addObject:newCategory];
    [userNotificationCenter setNotificationCategories:newCategories];
    resolve(nil);
  }];
}

UM_EXPORT_METHOD_AS(deleteCategoryAsync,
                    deleteCategoryWithCategoryId:(NSString *)categoryId
                    resolver:(UMPromiseResolveBlock)resolve
                    rejecter:(UMPromiseRejectBlock)reject) {
  NSString *internalCategoryId = [self internalIdForIdentifier:categoryId];
  __weak id<EXUserNotificationCenterProxy> userNotificationCenter = _userNotificationCenter;
  [_userNotificationCenter getNotificationCategoriesWithCompletionHandler:^(
                               NSSet<UNNotificationCategory *> *categories) {
    NSMutableSet<UNNotificationCategory *> *newCategories = [categories mutableCopy];
    for (UNNotificationCategory *category in newCategories) {
      if ([category.identifier isEqualToString:internalCategoryId]) {
        [newCategories removeObject:category];
        break;
      }
    }
    [userNotificationCenter setNotificationCategories:newCategories];
    resolve(nil);
  }];
}

#pragma mark - internal

- (UNMutableNotificationContent *)_localNotificationFromPayload:(NSDictionary *)payload {
  NSMutableDictionary *mutablePayload = [payload mutableCopy];
  [mutablePayload setObject:self.appId forKey:@"appId"];

  if (mutablePayload[@"categoryId"]) {
    mutablePayload[@"categoryId"] = [self internalIdForIdentifier:mutablePayload[@"categoryId"]];
  }

  return [EXNotificationConverter convertToNotificationContent:mutablePayload];
}

- (NSString *)internalIdForIdentifier:(NSString *)identifier {
  return [_scoper getScopedString:identifier];
}

- (UNCalendarNotificationTrigger *)calendarTriggerFrom:(NSDictionary *)options {
  BOOL repeats = [options[@"repeat"] boolValue];

  NSDateComponents *date = [[NSDateComponents alloc] init];
  date.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];

  int weekDay = ([options[@"weekDay"] intValue] % 7) + 1;
  date.weekday = weekDay;
  
  NSArray *timeUnits = @[ @"year", @"day", @"month", @"hour", @"second", @"minute" ];
  
  for (NSString *timeUnit in timeUnits) {
    if (options[timeUnit]) {
      [date setValue:options[timeUnit] forKey:timeUnit];
    }
  }

  return [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:date repeats:repeats];
}

- (UNNotificationAction *)parseNotificationActionFromParams:(NSDictionary *)params {
  NSString *actionId = [self internalIdForIdentifier:params[@"actionId"]];
  NSString *buttonTitle = params[@"buttonTitle"];

  UNNotificationActionOptions options = UNNotificationActionOptionNone;
  if (![params[@"doNotOpenInForeground"] boolValue]) {
    options += UNNotificationActionOptionForeground;
  }
  if ([params[@"isDestructive"] boolValue]) {
    options += UNNotificationActionOptionDestructive;
  }
  if ([params[@"isAuthenticationRequired"] boolValue]) {
    options += UNNotificationActionOptionAuthenticationRequired;
  }

  if ([params[@"textInput"] isKindOfClass:[NSDictionary class]]) {
    return [UNTextInputNotificationAction
        actionWithIdentifier:actionId
                       title:buttonTitle
                     options:options
        textInputButtonTitle:params[@"textInput"][@"submitButtonTitle"]
        textInputPlaceholder:params[@"textInput"][@"placeholder"]];
  }

  return [UNNotificationAction actionWithIdentifier:actionId title:buttonTitle options:options];
}

- (void)dealloc {
  [[EXThreadSafePostOffice sharedInstance] unregisterModuleWithAppId:_appId];
  [[EXThreadSafeTokenDispatcher sharedInstance] unregisterWithAppId:_appId];
}

- (void)onForegroundNotification:(NSDictionary *)notification {
  notification = [EXMessageUnscoper getUnscopedMessage:notification scoper:_scoper];
  [_eventEmitter sendEventWithName:@"Expo.onForegroundNotification" body:notification];
}

- (void)onUserInteraction:(NSDictionary *)userInteraction {
  userInteraction = [EXMessageUnscoper getUnscopedMessage:userInteraction scoper:_scoper];
  [_eventEmitter sendEventWithName:@"Expo.onUserInteraction" body:userInteraction];
}

- (NSArray<NSString *> *)supportedEvents {
  return @[ @"Expo.onUserInteraction", @"Expo.onForegroundNotification", @"Expo.onTokenChange" ];
}

- (void)startObserving {
}
- (void)stopObserving {
}

- (void)onTokenChange:(NSString *)token {
  [_eventEmitter sendEventWithName:@"Expo.onTokenChange" body:@{@"token":token}];
}

@end
