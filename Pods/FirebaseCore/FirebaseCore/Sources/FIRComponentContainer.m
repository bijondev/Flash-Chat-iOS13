/*
 * Copyright 2018 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FirebaseCore/Extension/FIRComponentContainer.h"

#import "FirebaseCore/Extension/FIRAppInternal.h"
#import "FirebaseCore/Extension/FIRComponent.h"
#import "FirebaseCore/Extension/FIRLibrary.h"
#import "FirebaseCore/Extension/FIRLogger.h"
#import "FirebaseCore/Sources/FIROptionsInternal.h"
#import "FirebaseCore/Sources/Public/FirebaseCore/FIROptions.h"

NS_ASSUME_NONNULL_BEGIN

@interface FIRComponentContainer ()

/// The dictionary of components that are registered for a particular app. The key is an `NSString`
/// of the protocol.
@property(nonatomic, strong) NSMutableDictionary<NSString *, FIRComponentCreationBlock> *components;

/// Cached instances of components that requested to be cached.
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *cachedInstances;

/// Protocols of components that have requested to be eagerly instantiated.
@property(nonatomic, strong, nullable) NSMutableArray<Protocol *> *eagerProtocolsToInstantiate;

@end

@implementation FIRComponentContainer

// Collection of all classes that register to provide components.
static NSMutableSet<Class> *sFIRComponentRegistrants;

#pragma mark - Public Registration

+ (void)registerAsComponentRegistrant:(Class<FIRLibrary>)klass {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sFIRComponentRegistrants = [[NSMutableSet<Class> alloc] init];
  });

  [self registerAsComponentRegistrant:klass inSet:sFIRComponentRegistrants];
}

+ (void)registerAsComponentRegistrant:(Class<FIRLibrary>)klass
                                inSet:(NSMutableSet<Class> *)allRegistrants {
  [allRegistrants addObject:klass];
}

#pragma mark - Internal Initialization

- (instancetype)initWithApp:(FIRApp *)app {
  NSMutableSet<Class> *componentRegistrants = sFIRComponentRegistrants;
  // If the app being created is for the ARCore SDK, remove the App Check
  // component (if it exists) since it does not support App Check.
  if ([self isAppForARCore:app]) {
    Class klass = NSClassFromString(@"FIRAppCheckComponent");
    if (klass && [sFIRComponentRegistrants containsObject:klass]) {
      componentRegistrants = [componentRegistrants mutableCopy];
      [componentRegistrants removeObject:klass];
    }
  }

  return [self initWithApp:app registrants:componentRegistrants];
}

- (instancetype)initWithApp:(FIRApp *)app registrants:(NSMutableSet<Class> *)allRegistrants {
  self = [super init];
  if (self) {
    _app = app;
    _cachedInstances = [NSMutableDictionary<NSString *, id> dictionary];
    _components = [NSMutableDictionary<NSString *, FIRComponentCreationBlock> dictionary];

    [self populateComponentsFromRegisteredClasses:allRegistrants forApp:app];
  }
  return self;
}

- (void)populateComponentsFromRegisteredClasses:(NSSet<Class> *)classes forApp:(FIRApp *)app {
  // Keep track of any components that need to eagerly instantiate after all components are added.
  self.eagerProtocolsToInstantiate = [[NSMutableArray alloc] init];

  // Loop through the verified component registrants and populate the components array.
  for (Class<FIRLibrary> klass in classes) {
    // Loop through all the components being registered and store them as appropriate.
    // Classes which do not provide functionality should use a dummy FIRComponentRegistrant
    // protocol.
    for (FIRComponent *component in [klass componentsToRegister]) {
      // Check if the component has been registered before, and error out if so.
      NSString *protocolName = NSStringFromProtocol(component.protocol);
      if (self.components[protocolName]) {
        FIRLogError(kFIRLoggerCore, @"I-COR000029",
                    @"Attempted to register protocol %@, but it already has an implementation.",
                    protocolName);
        continue;
      }

      // Store the creation block for later usage.
      self.components[protocolName] = component.creationBlock;

      // Queue any protocols that should be eagerly instantiated. Don't instantiate them yet
      // because they could depend on other components that haven't been added to the components
      // array yet.
      BOOL shouldInstantiateEager =
          (component.instantiationTiming == FIRInstantiationTimingAlwaysEager);
      BOOL shouldInstantiateDefaultEager =
          (component.instantiationTiming == FIRInstantiationTimingEagerInDefaultApp &&
           [app isDefaultApp]);
      if (shouldInstantiateEager || shouldInstantiateDefaultEager) {
        [self.eagerProtocolsToInstantiate addObject:component.protocol];
      }
    }
  }
}

#pragma mark - Instance Creation

- (void)instantiateEagerComponents {
  // After all components are registered, instantiate the ones that are requesting eager
  // instantiation.
  @synchronized(self) {
    for (Protocol *protocol in self.eagerProtocolsToInstantiate) {
      // Get an instance for the protocol, which will instantiate it since it couldn't have been
      // cached yet. Ignore the instance coming back since we don't need it.
      __unused id unusedInstance = [self instanceForProtocol:protocol];
    }

    // All eager instantiation is complete, clear the stored property now.
    self.eagerProtocolsToInstantiate = nil;
  }
}

/// Instantiate an instance of a class that conforms to the specified protocol.
/// This will:
///   - Call the block to create an instance if possible,
///   - Validate that the instance returned conforms to the protocol it claims to,
///   - Cache the instance if the block requests it
///
/// Note that this method assumes the caller already has @synchronized on self.
- (nullable id)instantiateInstanceForProtocol:(Protocol *)protocol
                                    withBlock:(FIRComponentCreationBlock)creationBlock {
  if (!creationBlock) {
    return nil;
  }

  // Create an instance using the creation block.
  BOOL shouldCache = NO;
  id instance = creationBlock(self, &shouldCache);
  if (!instance) {
    return nil;
  }

  // An instance was created, validate that it conforms to the protocol it claims to.
  NSString *protocolName = NSStringFromProtocol(protocol);
  if (![instance conformsToProtocol:protocol]) {
    FIRLogError(kFIRLoggerCore, @"I-COR000030",
                @"An instance conforming to %@ was requested, but the instance provided does not "
                @"conform to the protocol",
                protocolName);
  }

  // The instance is ready to be returned, but check if it should be cached first before returning.
  if (shouldCache) {
    self.cachedInstances[protocolName] = instance;
  }

  return instance;
}

#pragma mark - Internal Retrieval

// Redirected for Swift users.
- (nullable id)__instanceForProtocol:(Protocol *)protocol {
  return [self instanceForProtocol:protocol];
}

- (nullable id)instanceForProtocol:(Protocol *)protocol {
  // Check if there is a cached instance, and return it if so.
  NSString *protocolName = NSStringFromProtocol(protocol);

  id cachedInstance;
  @synchronized(self) {
    cachedInstance = self.cachedInstances[protocolName];
    if (!cachedInstance) {
      // Use the creation block to instantiate an instance and return it.
      FIRComponentCreationBlock creationBlock = self.components[protocolName];
      cachedInstance = [self instantiateInstanceForProtocol:protocol withBlock:creationBlock];
    }
  }
  return cachedInstance;
}

#pragma mark - Lifecycle

- (void)removeAllCachedInstances {
  @synchronized(self) {
    // Loop through the cache and notify each instance that is a maintainer to clean up after
    // itself.
    for (id instance in self.cachedInstances.allValues) {
      if ([instance conformsToProtocol:@protocol(FIRComponentLifecycleMaintainer)] &&
          [instance respondsToSelector:@selector(appWillBeDeleted:)]) {
        [instance appWillBeDeleted:self.app];
      }
    }

    // Empty the cache.
    [self.cachedInstances removeAllObjects];
  }
}

- (void)removeAllComponents {
  @synchronized(self) {
    [self.components removeAllObjects];
  }
}

#pragma mark - Helpers

- (BOOL)isAppForARCore:(FIRApp *)app {
  // First, check if the app name matches that of the one used by ARCore.
  if ([app.name isEqualToString:@"ARCoreFIRApp"]) {
    // Second, check if the app's gcmSenderID matches that of ARCore. This
    // prevents false positives in the unlikely event a 3P Firebase app is
    // named `ARCoreFIRApp`.
    const char *p1 = "406756";
    const char *p2 = "893798";
    const char gcmSenderIDKey[27] = {p1[0],  p2[0],  p1[1],  p2[1],  p1[2],  p2[2], p1[3],
                                     p2[3],  p1[4],  p2[4],  p1[5],  p2[5],  p1[6], p2[6],
                                     p1[7],  p2[7],  p1[8],  p2[8],  p1[9],  p2[9], p1[10],
                                     p2[10], p1[11], p2[11], p1[12], p2[12], '\0'};
    NSString *gcmSenderID = [NSString stringWithUTF8String:gcmSenderIDKey];
    return [app.options.GCMSenderID isEqualToString:gcmSenderID];
  }
  return NO;
}

@end

NS_ASSUME_NONNULL_END
