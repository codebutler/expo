// Copyright 2019-present 650 Industries. All rights reserved.

#import <EXNotifications/EXBareAppIdProvider.h>

@implementation EXBareAppIdProvider

UM_REGISTER_MODULE()

- (NSString *)getAppId {
  NSString *appIdFromInfoPList = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"EXNotificationsAppId"];
  if (appIdFromInfoPList != nil) {
    return appIdFromInfoPList;
  }
  return [EXBareAppIdProvider defaultId];
}

+ (const NSArray<Protocol *> *)exportedInterfaces {
  return @[ @protocol(EXAppIdProvider) ];
}

+ (NSString *)defaultId {
  return @"defaultId";
}

@end
