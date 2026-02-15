#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

#include <js.h>
#include <string.h>

#include "js-modules.h"

// Forward declarations for internal struct fields we access.
// These must match the layout in js.c.
typedef struct js_module_s js_module_t;

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
// Module loader delegate
// -----------------------------------------------------------------------

// We need access to the module struct internals and the env's
// current_loading_module. These are defined in js.c and we reference them
// through opaque pointers + helper functions declared in js-modules.h.
//
// The delegate stores a back-pointer to js_env_t and uses the public
// js.h API plus the module struct accessors to drive resolution.

@interface JSCModuleDelegate : NSObject {
  @public
  js_env_t *env;
}
@end

// These accessor functions are implemented in js.c and give us access to
// the module struct fields without exposing the full struct definition.
extern js_module_t *js__env_get_current_module(js_env_t *env);
extern void js__env_set_current_module(js_env_t *env, js_module_t *module);
extern const char *js__module_get_name(js_module_t *module);
extern const char *js__module_get_source(js_module_t *module);
extern bool js__module_is_synthetic(js_module_t *module);
extern void *js__module_get_script(js_module_t *module);
extern void js__module_set_script(js_module_t *module, void *script);
extern void *js__module_get_resolve_cb(js_module_t *module);
extern void *js__module_get_resolve_data(js_module_t *module);
extern void js__module_set_resolve_cb(js_module_t *module, void *cb, void *data);
extern void js__module_call_evaluate(js_env_t *env, js_module_t *module);
extern void *js__env_get_objc_context(js_env_t *env);
extern JSObjectRef js__module_get_pending_exports(js_module_t *module);

// URL prefix used for module identity
static NSString *const kModuleURLPrefix = @"file:///bare-modules/";

@implementation JSCModuleDelegate

- (void)context:(JSContext *)context
    fetchModuleForIdentifier:(JSValue *)identifier
         withResolveHandler:(JSValue *)resolve
           andRejectHandler:(JSValue *)reject {

  NSString *idStr = [identifier toString];

  // Strip our URL prefix to get the module name / specifier
  NSString *specifier = idStr;
  if ([idStr hasPrefix:kModuleURLPrefix]) {
    specifier = [idStr substringFromIndex:kModuleURLPrefix.length];
  }

  js_module_t *current = js__env_get_current_module(env);

  NSLog(@"[libjsc] delegate: identifier='%@' specifier='%@' current=%p", idStr, specifier, (void *)current);

  // --- Root module fetch ---
  // If the fetched identifier matches the current module being evaluated,
  // provide its pre-created JSScript.
  if (current != NULL) {
    const char *currentName = js__module_get_name(current);
    NSLog(@"[libjsc] delegate: checking root match: specifier='%@' vs currentName='%s'", specifier, currentName);
    if (currentName && [specifier isEqualToString:@(currentName)]) {
      void *script = js__module_get_script(current);
      if (script) {
        [resolve callWithArguments:@[(__bridge JSScript *)script]];
        return;
      }
    }
  }

  // --- Dependency fetch ---
  // Call the C resolve callback to get the child module.
  if (current == NULL) {
    NSLog(@"JSCModuleDelegate: no current module for dependency %@", specifier);
    [reject callWithArguments:@[
      [JSValue valueWithNewErrorFromMessage:
        [NSString stringWithFormat:@"No current module context for: %@", specifier]
        inContext:context]
    ]];
    return;
  }

  // Get the resolve callback from the current (referrer) module
  js_module_resolve_cb resolve_cb =
    (js_module_resolve_cb)js__module_get_resolve_cb(current);
  void *resolve_data = js__module_get_resolve_data(current);

  if (resolve_cb == NULL) {
    [reject callWithArguments:@[
      [JSValue valueWithNewErrorFromMessage:
        [NSString stringWithFormat:@"No resolve callback for: %@", specifier]
        inContext:context]
    ]];
    return;
  }

  // Create a JS string value for the specifier
  JSGlobalContextRef ctx = context.JSGlobalContextRef;
  JSStringRef specStr = JSStringCreateWithUTF8CString(specifier.UTF8String);
  JSValueRef specVal = JSValueMakeString(ctx, specStr);
  JSStringRelease(specStr);

  // Assertions: pass undefined
  JSValueRef assertions = JSValueMakeUndefined(ctx);

  // Call the C resolve callback
  js_module_t *child = resolve_cb(
    env,
    (js_value_t *)specVal,
    (js_value_t *)assertions,
    current,
    resolve_data
  );

  if (child == NULL) {
    [reject callWithArguments:@[
      [JSValue valueWithNewErrorFromMessage:
        [NSString stringWithFormat:@"Module not found: %@", specifier]
        inContext:context]
    ]];
    return;
  }

  // Propagate resolve callback to child if it doesn't have one
  if (js__module_get_resolve_cb(child) == NULL) {
    js__module_set_resolve_cb(child, (void *)resolve_cb, resolve_data);
  }

  // Create JSScript for the child module if not already created
  void *childScript = js__module_get_script(child);
  if (childScript == NULL) {
    const char *childSource = js__module_get_source(child);
    const char *childName = js__module_get_name(child);

    if (childSource == NULL) {
      [reject callWithArguments:@[
        [JSValue valueWithNewErrorFromMessage:
          [NSString stringWithFormat:@"Module has no source: %@", @(childName)]
          inContext:context]
      ]];
      return;
    }

    // For synthetic modules: call the evaluate callback and set up
    // globalThis exports BEFORE creating/evaluating the script.
    if (js__module_is_synthetic(child)) {
      js__module_call_evaluate(env, child);

      // Set globalThis.__jsc_syn[name] = pending_exports
      JSObjectRef global = JSContextGetGlobalObject(ctx);

      JSStringRef synKey = JSStringCreateWithUTF8CString("__jsc_syn");
      JSValueRef synVal = JSObjectGetProperty(ctx, global, synKey, NULL);

      if (JSValueIsUndefined(ctx, synVal)) {
        JSObjectRef synObj = JSObjectMake(ctx, NULL, NULL);
        JSObjectSetProperty(ctx, global, synKey, (JSValueRef)synObj, 0, NULL);
        synVal = (JSValueRef)synObj;
      }
      JSStringRelease(synKey);

      JSObjectRef pendingExports = js__module_get_pending_exports(child);
      if (pendingExports) {
        JSStringRef nameKey = JSStringCreateWithUTF8CString(childName);
        JSObjectSetProperty(ctx, (JSObjectRef)synVal, nameKey,
                            (JSValueRef)pendingExports, 0, NULL);
        JSStringRelease(nameKey);
      }
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@%s",
                        kModuleURLPrefix, childName];
    childScript = js__module_script_create(
      js__env_get_objc_context(env), childSource, urlStr.UTF8String
    );
    js__module_set_script(child, childScript);
  }

  // Save / restore current_loading_module for recursive resolution
  js_module_t *saved = js__env_get_current_module(env);
  js__env_set_current_module(env, child);

  [resolve callWithArguments:@[(__bridge JSScript *)childScript]];

  js__env_set_current_module(env, saved);
}

@end

// -----------------------------------------------------------------------
// C-callable bridge functions
// -----------------------------------------------------------------------

void *
js__objc_context_create(JSGlobalContextRef *out_ctx, JSContextGroupRef *out_group) {
  JSContext *ctx = [[JSContext alloc] init];
  *out_ctx = ctx.JSGlobalContextRef;
  *out_group = JSContextGetGroup(*out_ctx);
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
    NSLog(@"js__module_script_create error: %@", error);
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

void
js__objc_set_global_property(void *objc_context, const char *key, JSValueRef value) {
  JSContext *ctx = (__bridge JSContext *)objc_context;
  JSGlobalContextRef cctx = ctx.JSGlobalContextRef;
  JSObjectRef global = JSContextGetGlobalObject(cctx);
  JSStringRef jsKey = JSStringCreateWithUTF8CString(key);
  JSObjectSetProperty(cctx, global, jsKey, value, 0, NULL);
  JSStringRelease(jsKey);
}
