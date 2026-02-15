#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

#include <js.h>
#include <string.h>

#include "js-modules.h"

// Redeclare JSC private/SPI interfaces. Symbols are exported in the system
// framework since iOS 13 / macOS 10.15.
typedef NS_ENUM(NSInteger, JSScriptType) {
  kJSScriptTypeProgram,
  kJSScriptTypeModule,
};

@interface JSScript : NSObject
+ (nullable instancetype) scriptOfType:(JSScriptType)type
                            withSource:(NSString *)source
                          andSourceURL:(NSURL *)sourceURL
                      andBytecodeCache:(nullable NSURL *)cachePath
                      inVirtualMachine:(JSVirtualMachine *)vm
                                 error:(out NSError **)error;
@end

@interface JSContext (ModuleLoader)
@property (nonatomic, weak) id moduleLoaderDelegate;
- (JSValue *)evaluateJSScript:(JSScript *)script;
@end

// -----------------------------------------------------------------------
// Module loader delegate — registry-based
// -----------------------------------------------------------------------
// All modules are pre-resolved and registered during js_instantiate_module.
// The delegate simply looks them up by URL when JSC requests them.

// Accessor functions implemented in js.c
extern void *js__module_get_script(js_module_t *module);
extern const char *js__module_get_name(js_module_t *module);
extern bool js__module_is_synthetic(js_module_t *module);
extern JSObjectRef js__module_get_pending_exports(js_module_t *module);

// URL prefix used for module identity
static NSString *const kModuleURLPrefix = @"file:///bare-modules/";

@interface JSCModuleDelegate : NSObject {
  @public
  js_env_t *env;
  NSMutableDictionary<NSString *, NSValue *> *moduleRegistry;
  NSMutableArray *pendingResolutions;  // Queue of deferred resolve blocks
  BOOL isDraining;     // Prevents nested drain loops
}
@end

@implementation JSCModuleDelegate

- (instancetype)init {
  self = [super init];
  if (self) {
    moduleRegistry = [[NSMutableDictionary alloc] init];
    pendingResolutions = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)context:(JSContext *)context
    fetchModuleForIdentifier:(JSValue *)identifier
         withResolveHandler:(JSValue *)resolve
           andRejectHandler:(JSValue *)reject {

  NSString *idStr = [identifier toString];
  NSLog(@"[libjsc] delegate: fetch '%@' (registry has %lu entries)",
        idStr, (unsigned long)moduleRegistry.count);

  // Look up in registry
  NSValue *entry = moduleRegistry[idStr];

  if (entry == nil) {
    // Try stripping any trailing whitespace or normalization differences
    // Also try without the prefix for backwards compatibility
    NSString *stripped = idStr;
    if ([idStr hasPrefix:kModuleURLPrefix]) {
      stripped = [idStr substringFromIndex:kModuleURLPrefix.length];
      NSString *altKey = [NSString stringWithFormat:@"%@%@",
                          kModuleURLPrefix, stripped];
      entry = moduleRegistry[altKey];
    }
  }

  if (entry == nil) {
    NSLog(@"[libjsc] delegate: module NOT FOUND in registry: '%@'", idStr);
    // Dump all registry keys for debugging
    NSLog(@"[libjsc] registry keys: %@", [moduleRegistry allKeys]);
    [reject callWithArguments:@[
      [JSValue valueWithNewErrorFromMessage:
        [NSString stringWithFormat:@"Module not found in registry: %@", idStr]
        inContext:context]
    ]];
    return;
  }

  js_module_t *module = (js_module_t *)[entry pointerValue];
  void *script = js__module_get_script(module);

  if (script == NULL) {
    NSLog(@"[libjsc] delegate: module has no JSScript: '%@'", idStr);
    [reject callWithArguments:@[
      [JSValue valueWithNewErrorFromMessage:
        [NSString stringWithFormat:@"Module has no script: %@", idStr]
        inContext:context]
    ]];
    return;
  }

  // For synthetic modules: ensure globalThis exports are set up
  if (js__module_is_synthetic(module)) {
    JSGlobalContextRef ctx = context.JSGlobalContextRef;
    JSObjectRef global = JSContextGetGlobalObject(ctx);

    JSStringRef synKey = JSStringCreateWithUTF8CString("__jsc_syn");
    JSValueRef synVal = JSObjectGetProperty(ctx, global, synKey, NULL);

    if (JSValueIsUndefined(ctx, synVal)) {
      JSObjectRef synObj = JSObjectMake(ctx, NULL, NULL);
      JSObjectSetProperty(ctx, global, synKey, (JSValueRef)synObj, 0, NULL);
      synVal = (JSValueRef)synObj;
    }
    JSStringRelease(synKey);

    JSObjectRef pendingExports = js__module_get_pending_exports(module);
    if (pendingExports) {
      const char *modName = js__module_get_name(module);
      JSStringRef nameKey = JSStringCreateWithUTF8CString(modName);
      JSObjectSetProperty(ctx, (JSObjectRef)synVal, nameKey,
                          (JSValueRef)pendingExports, 0, NULL);
      JSStringRelease(nameKey);
    }
  }

  // Always queue resolutions — never resolve synchronously within the
  // delegate. JSC evaluates resolved modules recursively: each synchronous
  // resolve triggers parsing + evaluation, which calls the delegate for
  // sub-imports. Even 10 nested levels overflows the JS stack on iOS.
  //
  // Instead, queue every resolution. The outermost delegate call enters a
  // while loop that pops and resolves one module at a time. Each resolve
  // triggers JSC evaluation, which calls the delegate for sub-imports —
  // those just queue (isDraining prevents re-entering the loop). The while
  // loop then picks them up iteratively. Stack depth: exactly 1 level of
  // delegate → resolve → JSC eval → delegate(queue) at all times.
  JSScript *s = (__bridge JSScript *)script;

  [pendingResolutions addObject:[^{
    [resolve callWithArguments:@[s]];
  } copy]];

  if (!isDraining) {
    isDraining = YES;
    while (pendingResolutions.count > 0) {
      void (^block)(void) = pendingResolutions[0];
      [pendingResolutions removeObjectAtIndex:0];
      block();
    }
    isDraining = NO;
  }
}

@end

// -----------------------------------------------------------------------
// C-callable bridge functions
// -----------------------------------------------------------------------

void
js__nslog(const char *msg) {
  NSLog(@"[libjsc] %s", msg);
}

int
js__drain_run_loop(void) {
  // Process one pending run loop source. JSC's module loader dispatches
  // dependency resolution callbacks via the run loop, so we must spin it
  // to trigger delegate calls during synchronous drain loops.
  BOOL handled = [[NSRunLoop currentRunLoop]
    runMode:NSDefaultRunLoopMode
    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
  return handled ? 1 : 0;
}

int
js__objc_eval_int(void *objc_context, const char *expr) {
  JSContext *ctx = (__bridge JSContext *)objc_context;
  NSString *script = [NSString stringWithUTF8String:expr];
  JSValue *result = [ctx evaluateScript:script];
  if (result == nil || [result isUndefined]) return 0;
  return [result toInt32];
}

void *
js__objc_context_create(JSGlobalContextRef *out_ctx, JSContextGroupRef *out_group) {
  JSContext *ctx = [[JSContext alloc] init];

  ctx.exceptionHandler = ^(JSContext *c, JSValue *exception) {
    NSLog(@"[libjsc] JSContext exception: %@", exception);
    NSLog(@"[libjsc] Exception stack: %@", [exception objectForKeyedSubscript:@"stack"]);
  };

  *out_ctx = ctx.JSGlobalContextRef;
  *out_group = JSContextGetGroup(*out_ctx);
  NSLog(@"[libjsc] Created Obj-C JSContext: %p, globalCtx: %p", ctx, *out_ctx);
  return (__bridge_retained void *)ctx;
}

void
js__objc_context_release(void *objc_context) {
  JSContext *ctx = (__bridge_transfer JSContext *)objc_context;
  (void)ctx; // ARC releases
}

JSGlobalContextRef
js__objc_get_context_ref(void *objc_context) {
  JSContext *ctx = (__bridge JSContext *)objc_context;
  return ctx.JSGlobalContextRef;
}

void *
js__module_delegate_create(js_env_t *env) {
  JSCModuleDelegate *d = [[JSCModuleDelegate alloc] init];
  d->env = env;
  return (__bridge_retained void *)d;
}

void
js__module_delegate_release(void *delegate) {
  JSCModuleDelegate *d = (__bridge_transfer JSCModuleDelegate *)delegate;
  (void)d;
}

void
js__module_delegate_set(void *objc_context, void *delegate) {
  JSContext *ctx = (__bridge JSContext *)objc_context;
  JSCModuleDelegate *d = (__bridge JSCModuleDelegate *)delegate;
  ctx.moduleLoaderDelegate = d;
}

void
js__module_delegate_register(void *delegate, const char *url, js_module_t *module) {
  JSCModuleDelegate *d = (__bridge JSCModuleDelegate *)delegate;
  NSString *key = [NSString stringWithUTF8String:url];
  d->moduleRegistry[key] = [NSValue valueWithPointer:module];
}

js_module_t *
js__module_delegate_lookup(void *delegate, const char *url) {
  JSCModuleDelegate *d = (__bridge JSCModuleDelegate *)delegate;
  NSString *key = [NSString stringWithUTF8String:url];
  NSValue *entry = d->moduleRegistry[key];
  if (entry == nil) return NULL;
  return (js_module_t *)[entry pointerValue];
}

int
js__module_delegate_drain_one(void *delegate) {
  if (delegate == NULL) return 0;
  JSCModuleDelegate *d = (__bridge JSCModuleDelegate *)delegate;
  if (d->pendingResolutions.count == 0) return 0;

  // Pop and resolve one queued module. The resolve may trigger further
  // delegate calls which queue more items. isDraining is set so nested
  // calls don't re-enter the while loop in the delegate.
  d->isDraining = YES;
  void (^block)(void) = d->pendingResolutions[0];
  [d->pendingResolutions removeObjectAtIndex:0];
  block();

  // Continue draining any items queued by the resolve
  while (d->pendingResolutions.count > 0) {
    block = d->pendingResolutions[0];
    [d->pendingResolutions removeObjectAtIndex:0];
    block();
  }
  d->isDraining = NO;

  return 1;
}

void *
js__module_script_create(void *objc_context, const char *source, const char *url) {
  JSContext *ctx = (__bridge JSContext *)objc_context;

  NSString *srcStr = [NSString stringWithUTF8String:source];
  NSURL *srcURL = [NSURL URLWithString:[NSString stringWithUTF8String:url]];

  NSError *error = nil;
  JSScript *script = [JSScript scriptOfType:kJSScriptTypeModule
                               withSource:srcStr
                             andSourceURL:srcURL
                         andBytecodeCache:nil
                         inVirtualMachine:ctx.virtualMachine
                                    error:&error];
  if (error) {
    NSLog(@"js__module_script_create error for '%s': %@", url, error);
    return NULL;
  }

  return (__bridge_retained void *)script;
}

void
js__module_script_release(void *script) {
  if (script == NULL) return;
  JSScript *s = (__bridge_transfer JSScript *)script;
  (void)s;
}

JSValueRef
js__module_script_evaluate(void *objc_context, void *script) {
  JSContext *ctx = (__bridge JSContext *)objc_context;
  JSScript *s = (__bridge JSScript *)script;

  JSValue *result = [ctx evaluateJSScript:s];
  if (result == nil) return NULL;

  return result.JSValueRef;
}

// -----------------------------------------------------------------------
// Batch module registration via provideFetch
// -----------------------------------------------------------------------
// Each [JSContext evaluateJSScript:] call internally invokes
// JSC::loadAndEvaluateModule which synchronously calls provideFetch —
// registering the module source in JSC's internal fetch map. However,
// evaluateJSScript also creates a JSLockHolder whose destructor calls
// willReleaseLock() → drainMicrotasks(). This means after EACH call,
// microtasks run and imports are resolved — triggering the delegate.
//
// By holding an OUTER JSLockHolder (obtained via dlsym), the inner lock
// in evaluateJSScript never drops to zero, so willReleaseLock/drainMicrotasks
// is suppressed. All provideFetch registrations happen synchronously.
// When we release the outer lock, drainMicrotasks runs once and ALL imports
// resolve from the pre-registered fetch map — zero delegate calls.

#include <dlfcn.h>

typedef void (*js__lock_ctor_fn)(void *self, void *globalObject);
typedef void (*js__lock_dtor_fn)(void *self);

static js__lock_ctor_fn s_lock_ctor = NULL;
static js__lock_dtor_fn s_lock_dtor = NULL;
static bool s_lock_resolved = false;

static void
js__resolve_lock_symbols(void) {
  if (s_lock_resolved) return;
  s_lock_resolved = true;

  // Find the actual loaded JavaScriptCore image. On the iOS simulator the
  // framework is loaded from the simulator runtime root, NOT from
  // /System/Library/Frameworks/..., so a hardcoded path won't work.
  //
  // Strategy: use dladdr() on a known public JSC symbol (JSEvaluateScript)
  // to discover the actual image path, then dlopen() that path.
  Dl_info info;
  if (!dladdr((void *)JSEvaluateScript, &info) || !info.dli_fname) {
    NSLog(@"[libjsc] provideFetch: dladdr failed for JSEvaluateScript");
    return;
  }

  NSLog(@"[libjsc] provideFetch: JSC image at %s", info.dli_fname);

  void *jsc_handle = dlopen(info.dli_fname, RTLD_NOLOAD);

  if (!jsc_handle) {
    NSLog(@"[libjsc] provideFetch: dlopen JSC failed: %s", dlerror());
    return;
  }

  // JSC::JSLockHolder::JSLockHolder(JSC::JSGlobalObject*)
  s_lock_ctor = (js__lock_ctor_fn)dlsym(jsc_handle,
    "__ZN3JSC12JSLockHolderC1EPNS_14JSGlobalObjectE");

  // JSC::JSLockHolder::~JSLockHolder()
  s_lock_dtor = (js__lock_dtor_fn)dlsym(jsc_handle,
    "__ZN3JSC12JSLockHolderD1Ev");

  if (s_lock_ctor && s_lock_dtor) {
    NSLog(@"[libjsc] provideFetch: JSLockHolder resolved via dlsym");
  } else {
    NSLog(@"[libjsc] provideFetch: JSLockHolder NOT found (ctor=%p dtor=%p, err=%s)",
          s_lock_ctor, s_lock_dtor, dlerror());
  }
}

void
js__batch_register_modules(void *objc_context, void **scripts, size_t count) {
  if (count == 0) return;

  js__resolve_lock_symbols();

  JSContext *ctx = (__bridge JSContext *)objc_context;

  if (s_lock_ctor && s_lock_dtor) {
    JSGlobalContextRef ctx_ref = ctx.JSGlobalContextRef;

    // JSLockHolder layout: { RefPtr<JSLock> m_lock; } = 8 bytes
    // Use 16 bytes for safety/alignment.
    char lock_buf[16];
    memset(lock_buf, 0, sizeof(lock_buf));

    // Acquire outer lock — prevents willReleaseLock()/drainMicrotasks()
    // from firing inside evaluateJSScript's nested JSLockHolder.
    // JSGlobalContextRef == JSGlobalObject* (direct reinterpret_cast in JSC).
    s_lock_ctor(lock_buf, (void *)ctx_ref);

    NSLog(@"[libjsc] provideFetch: registering %zu modules within lock",
          (unsigned long)count);

    for (size_t i = 0; i < count; i++) {
      JSScript *s = (__bridge JSScript *)scripts[i];
      // evaluateJSScript → loadAndEvaluateModule → provideFetch (synchronous)
      // The returned promise is not drained yet (outer lock held).
      [ctx evaluateJSScript:s];
    }

    NSLog(@"[libjsc] provideFetch: releasing lock — draining microtasks");

    // Release outer lock → lock count drops to 0 → willReleaseLock() →
    // drainMicrotasks(). All imports resolve from the provideFetch map.
    s_lock_dtor(lock_buf);

    NSLog(@"[libjsc] provideFetch: batch registration complete");
  } else {
    // Fallback: sequential evaluation without lock holding.
    // The delegate WILL be called for each import (may stack overflow).
    NSLog(@"[libjsc] provideFetch: FALLBACK — sequential eval for %zu modules",
          (unsigned long)count);
    for (size_t i = 0; i < count; i++) {
      JSScript *s = (__bridge JSScript *)scripts[i];
      [ctx evaluateJSScript:s];
    }
  }
}

void
js__objc_set_global_property(void *objc_context, const char *key, JSValueRef value) {
  JSContext *ctx = (__bridge JSContext *)objc_context;
  JSGlobalContextRef cctx = ctx.JSGlobalContextRef;
  JSObjectRef global = JSContextGetGlobalObject(cctx);
  JSStringRef jsKey = JSStringCreateWithUTF8CString(key);
  JSObjectSetProperty(cctx, global, jsKey, value, 0, NULL);
  JSStringRelease(jsKey);
}
