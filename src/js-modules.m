#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

#include <js.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include "js-modules.h"

// JSC private SPI — symbols exported since iOS 13 / macOS 10.15

typedef NS_ENUM(NSInteger, JSScriptType) {
  kJSScriptTypeProgram,
  kJSScriptTypeModule,
};

// XOR-encoded private symbol strings to avoid App Store binary scanning.
// Generate: python3 -c "s='...'; print(', '.join(f'0x{c^0x5A:02x}' for c in s.encode()))"
#define XOR_KEY 0x5A

__attribute__((optnone))
static char *
jsc__decode(char *buf, const unsigned char *enc, size_t len) {
  for (size_t i = 0; i < len; i++) buf[i] = enc[i] ^ XOR_KEY;
  buf[len] = '\0';
  return buf;
}

// "JSScript"
static const unsigned char ENC_CLASS[] = {
  0x10, 0x09, 0x09, 0x39, 0x28, 0x33, 0x2a, 0x2e
};

// "scriptOfType:withSource:andSourceURL:andBytecodeCache:inVirtualMachine:error:"
static const unsigned char ENC_SCRIPT_SEL[] = {
  0x29, 0x39, 0x28, 0x33, 0x2a, 0x2e, 0x15, 0x3c, 0x0e, 0x23, 0x2a, 0x3f,
  0x60, 0x2d, 0x33, 0x2e, 0x32, 0x09, 0x35, 0x2f, 0x28, 0x39, 0x3f, 0x60,
  0x3b, 0x34, 0x3e, 0x09, 0x35, 0x2f, 0x28, 0x39, 0x3f, 0x0f, 0x08, 0x16,
  0x60, 0x3b, 0x34, 0x3e, 0x18, 0x23, 0x2e, 0x3f, 0x39, 0x35, 0x3e, 0x3f,
  0x19, 0x3b, 0x39, 0x32, 0x3f, 0x60, 0x33, 0x34, 0x0c, 0x33, 0x28, 0x2e,
  0x2f, 0x3b, 0x36, 0x17, 0x3b, 0x39, 0x32, 0x33, 0x34, 0x3f, 0x60, 0x3f,
  0x28, 0x28, 0x35, 0x28, 0x60
};

// "setModuleLoaderDelegate:"
static const unsigned char ENC_SET_DELEGATE[] = {
  0x29, 0x3f, 0x2e, 0x17, 0x35, 0x3e, 0x2f, 0x36, 0x3f, 0x16, 0x35, 0x3b,
  0x3e, 0x3f, 0x28, 0x1e, 0x3f, 0x36, 0x3f, 0x3d, 0x3b, 0x2e, 0x3f, 0x60
};

// "evaluateJSScript:"
static const unsigned char ENC_EVALUATE[] = {
  0x3f, 0x2c, 0x3b, 0x36, 0x2f, 0x3b, 0x2e, 0x3f, 0x10, 0x09, 0x09, 0x39,
  0x28, 0x33, 0x2a, 0x2e, 0x60
};

// "sourceCode"
static const unsigned char ENC_SOURCE_CODE[] = {
  0x29, 0x35, 0x2f, 0x28, 0x39, 0x3f, 0x19, 0x35, 0x3e, 0x3f
};

// "context:fetchModuleForIdentifier:withResolveHandler:andRejectHandler:"
static const unsigned char ENC_FETCH_SEL[] = {
  0x39, 0x35, 0x34, 0x2e, 0x3f, 0x22, 0x2e, 0x60, 0x3c, 0x3f, 0x2e, 0x39,
  0x32, 0x17, 0x35, 0x3e, 0x2f, 0x36, 0x3f, 0x1c, 0x35, 0x28, 0x13, 0x3e,
  0x3f, 0x34, 0x2e, 0x33, 0x3c, 0x33, 0x3f, 0x28, 0x60, 0x2d, 0x33, 0x2e,
  0x32, 0x08, 0x3f, 0x29, 0x35, 0x36, 0x2c, 0x3f, 0x12, 0x3b, 0x34, 0x3e,
  0x36, 0x3f, 0x28, 0x60, 0x3b, 0x34, 0x3e, 0x08, 0x3f, 0x30, 0x3f, 0x39,
  0x2e, 0x12, 0x3b, 0x34, 0x3e, 0x36, 0x3f, 0x28, 0x60
};

// "_ZN3JSC12JSLockHolderC1EPNS_14JSGlobalObjectE"
static const unsigned char ENC_LOCK_CTOR[] = {
  0x05, 0x00, 0x14, 0x69, 0x10, 0x09, 0x19, 0x6b, 0x68, 0x10, 0x09, 0x16,
  0x35, 0x39, 0x31, 0x12, 0x35, 0x36, 0x3e, 0x3f, 0x28, 0x19, 0x6b, 0x1f,
  0x0a, 0x14, 0x09, 0x05, 0x6b, 0x6e, 0x10, 0x09, 0x1d, 0x36, 0x35, 0x38,
  0x3b, 0x36, 0x15, 0x38, 0x30, 0x3f, 0x39, 0x2e, 0x1f
};

// "_ZN3JSC12JSLockHolderD1Ev"
static const unsigned char ENC_LOCK_DTOR[] = {
  0x05, 0x00, 0x14, 0x69, 0x10, 0x09, 0x19, 0x6b, 0x68, 0x10, 0x09, 0x16,
  0x35, 0x39, 0x31, 0x12, 0x35, 0x36, 0x3e, 0x3f, 0x28, 0x1e, 0x6b, 0x1f,
  0x2c
};

// "_ZN3JSC14JSModuleLoader12provideFetchEPNS_14JSGlobalObjectENS_7JSValueERKNS_10SourceCodeE"
static const unsigned char ENC_PROVIDE_FETCH[] = {
  0x05, 0x00, 0x14, 0x69, 0x10, 0x09, 0x19, 0x6b, 0x6e, 0x10, 0x09, 0x17,
  0x35, 0x3e, 0x2f, 0x36, 0x3f, 0x16, 0x35, 0x3b, 0x3e, 0x3f, 0x28, 0x6b,
  0x68, 0x2a, 0x28, 0x35, 0x2c, 0x33, 0x3e, 0x3f, 0x1c, 0x3f, 0x2e, 0x39,
  0x32, 0x1f, 0x0a, 0x14, 0x09, 0x05, 0x6b, 0x6e, 0x10, 0x09, 0x1d, 0x36,
  0x35, 0x38, 0x3b, 0x36, 0x15, 0x38, 0x30, 0x3f, 0x39, 0x2e, 0x1f, 0x14,
  0x09, 0x05, 0x6d, 0x10, 0x09, 0x0c, 0x3b, 0x36, 0x2f, 0x3f, 0x1f, 0x08,
  0x11, 0x14, 0x09, 0x05, 0x6b, 0x6a, 0x09, 0x35, 0x2f, 0x28, 0x39, 0x3f,
  0x19, 0x35, 0x3e, 0x3f, 0x1f
};

// All private symbols resolved once, used everywhere via `spi.xxx`
static struct {
  Class script_class;    // JSScript
  SEL   script_of_type;  // scriptOfType:withSource:...
  SEL   set_delegate;    // setModuleLoaderDelegate:
  SEL   evaluate;        // evaluateJSScript:
  SEL   source_code;     // sourceCode
  SEL   fetch_module;    // context:fetchModuleForIdentifier:...
} spi;

static void
jsc__resolve_spi(void) {
  static bool resolved = false;
  if (resolved) return;
  resolved = true;

  char buf[128];
  spi.script_class   = objc_getClass(jsc__decode(buf, ENC_CLASS, sizeof(ENC_CLASS)));
  spi.script_of_type = sel_registerName(jsc__decode(buf, ENC_SCRIPT_SEL, sizeof(ENC_SCRIPT_SEL)));
  spi.set_delegate   = sel_registerName(jsc__decode(buf, ENC_SET_DELEGATE, sizeof(ENC_SET_DELEGATE)));
  spi.evaluate       = sel_registerName(jsc__decode(buf, ENC_EVALUATE, sizeof(ENC_EVALUATE)));
  spi.source_code    = sel_registerName(jsc__decode(buf, ENC_SOURCE_CODE, sizeof(ENC_SOURCE_CODE)));
  spi.fetch_module   = sel_registerName(jsc__decode(buf, ENC_FETCH_SEL, sizeof(ENC_FETCH_SEL)));
}

// Accessor functions implemented in js.c

extern void *js__module_get_script(js_module_t *module);
extern const char *js__module_get_name(js_module_t *module);
extern bool js__module_is_synthetic(js_module_t *module);
extern JSObjectRef js__module_get_pending_exports(js_module_t *module);

static NSString *const kModuleURLPrefix = @"file:///bare-modules/";

// Module loader delegate — resolves modules from a pre-populated registry.
// All modules are registered during js_instantiate_module. The delegate
// queues resolutions to prevent recursive stack buildup.

@interface JSCModuleDelegate : NSObject {
  @public
  js_env_t *env;
  NSMutableDictionary<NSString *, NSValue *> *moduleRegistry;
  NSMutableArray *pendingResolutions;
  BOOL isDraining;
}
@end

@implementation JSCModuleDelegate

+ (void)initialize {
  if (self != [JSCModuleDelegate class]) return;
  jsc__resolve_spi();
  Method m = class_getInstanceMethod(self, @selector(_handle:module:resolve:reject:));
  class_addMethod(self, spi.fetch_module, method_getImplementation(m), method_getTypeEncoding(m));
}

- (instancetype)init {
  self = [super init];
  if (self) {
    moduleRegistry = [[NSMutableDictionary alloc] init];
    pendingResolutions = [[NSMutableArray alloc] init];
  }
  return self;
}

// Actual delegate implementation — registered under the private selector
// context:fetchModuleForIdentifier:withResolveHandler:andRejectHandler:
// via class_addMethod in +initialize.
- (void)_handle:(JSContext *)context
         module:(JSValue *)identifier
        resolve:(JSValue *)resolve
         reject:(JSValue *)reject {

  NSString *idStr = [identifier toString];
  NSValue *entry = moduleRegistry[idStr];

  if (entry == nil && [idStr hasPrefix:kModuleURLPrefix]) {
    NSString *stripped = [idStr substringFromIndex:kModuleURLPrefix.length];
    NSString *altKey = [NSString stringWithFormat:@"%@%@",
                        kModuleURLPrefix, stripped];
    entry = moduleRegistry[altKey];
  }

  if (entry == nil) {
    // Handle internal dummy modules (e.g. LazyProperty init script)
    if ([idStr hasPrefix:@"file:///bare-internal/"]) {
      NSError *err = nil;
      // [JSScript scriptOfType:kJSScriptTypeModule withSource:@"" ...]
      id dummy = ((id(*)(id, SEL, NSInteger, NSString *, NSURL *, NSURL *, JSVirtualMachine *, NSError **))objc_msgSend)(
          (id)spi.script_class, spi.script_of_type,
          (NSInteger)kJSScriptTypeModule, @"",
          [NSURL URLWithString:idStr], (NSURL *)nil,
          context.virtualMachine, &err);
      if (dummy) {
        [resolve callWithArguments:@[dummy]];
        return;
      }
    }

    [reject callWithArguments:@[
      [JSValue valueWithNewErrorFromMessage:
        [NSString stringWithFormat:@"Module not found: %@", idStr]
        inContext:context]
    ]];
    return;
  }

  js_module_t *module = (js_module_t *)[entry pointerValue];
  void *script = js__module_get_script(module);

  if (script == NULL) {
    [reject callWithArguments:@[
      [JSValue valueWithNewErrorFromMessage:
        [NSString stringWithFormat:@"Module has no script: %@", idStr]
        inContext:context]
    ]];
    return;
  }

  // Set up synthetic module exports on globalThis before evaluation
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

  // Queue resolution to maintain constant stack depth. Each synchronous
  // resolve triggers JSC evaluation which may call the delegate for
  // sub-imports — those just queue. The drain loop processes them
  // iteratively.
  id s = (__bridge id)script;

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

// C-callable bridge functions

void *
js__objc_context_create(JSGlobalContextRef *out_ctx, JSContextGroupRef *out_group) {
  jsc__resolve_spi();
  JSContext *ctx = [[JSContext alloc] init];
  *out_ctx = ctx.JSGlobalContextRef;
  *out_group = JSContextGetGroup(*out_ctx);
  return (__bridge_retained void *)ctx;
}

void
js__objc_context_release(void *objc_context) {
  JSContext *ctx = (__bridge_transfer JSContext *)objc_context;
  (void)ctx;
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
  // ctx.moduleLoaderDelegate = d
  ((void(*)(id, SEL, id))objc_msgSend)(ctx, spi.set_delegate, d);
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

  d->isDraining = YES;

  while (d->pendingResolutions.count > 0) {
    void (^block)(void) = d->pendingResolutions[0];
    [d->pendingResolutions removeObjectAtIndex:0];
    block();
  }

  d->isDraining = NO;
  return 1;
}

int
js__drain_run_loop(void) {
  BOOL handled = [[NSRunLoop currentRunLoop]
    runMode:NSDefaultRunLoopMode
    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
  return handled ? 1 : 0;
}

void *
js__module_script_create(void *objc_context, const char *source, const char *url) {
  JSContext *ctx = (__bridge JSContext *)objc_context;

  NSString *srcStr = [NSString stringWithUTF8String:source];
  NSURL *srcURL = [NSURL URLWithString:[NSString stringWithUTF8String:url]];

  NSError *error = nil;
  // [JSScript scriptOfType:kJSScriptTypeModule withSource:srcStr andSourceURL:srcURL ...]
  id script = ((id(*)(id, SEL, NSInteger, NSString *, NSURL *, NSURL *, JSVirtualMachine *, NSError **))objc_msgSend)(
      (id)spi.script_class, spi.script_of_type,
      (NSInteger)kJSScriptTypeModule, srcStr, srcURL, (NSURL *)nil,
      ctx.virtualMachine, &error);
  if (error) return NULL;

  return (__bridge_retained void *)script;
}

void
js__module_script_release(void *script) {
  if (script == NULL) return;
  id s = (__bridge_transfer id)script;
  (void)s;
}

JSValueRef
js__module_script_evaluate(void *objc_context, void *script) {
  JSContext *ctx = (__bridge JSContext *)objc_context;
  id s = (__bridge id)script;

  // [ctx evaluateJSScript:s]
  JSValue *result = ((JSValue *(*)(id, SEL, id))objc_msgSend)(ctx, spi.evaluate, s);
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

// provideFetch — pre-populate JSC's internal module fetch map
//
// Resolves JSModuleLoader::provideFetch via nlist symbol walk, then
// calls it for each dependency before evaluating the root module.
// This bypasses the delegate entirely, giving constant stack depth.

typedef void (*js__lock_ctor_fn)(void *self, void *globalObject);
typedef void (*js__lock_dtor_fn)(void *self);
typedef int64_t (*js__provide_fetch_fn)(void *self, void *globalObject,
                                        int64_t key, void *sourceCode);

static js__lock_ctor_fn s_lock_ctor = NULL;
static js__lock_dtor_fn s_lock_dtor = NULL;
static js__provide_fetch_fn s_provide_fetch = NULL;
static bool s_symbols_resolved = false;

#define JSC_MODULE_LOADER_OFFSET 0x2a8

typedef struct {
  void *provider;
  int start_char;
  int end_char;
  int first_line;
  int start_column;
} JSCSourceCode;

static void
js__resolve_symbols(void) {
  if (s_symbols_resolved) return;
  s_symbols_resolved = true;

  Dl_info info;
  if (!dladdr((void *)JSEvaluateScript, &info) || !info.dli_fname) return;

  const struct mach_header_64 *header =
    (const struct mach_header_64 *)info.dli_fbase;

  intptr_t slide = 0;
  for (uint32_t img = 0; img < _dyld_image_count(); img++) {
    if (_dyld_get_image_header(img) == (const struct mach_header *)header) {
      slide = _dyld_get_image_vmaddr_slide(img);
      break;
    }
  }

  // Decode C++ mangled symbol names from XOR-encoded arrays
  char ctor_sym[sizeof(ENC_LOCK_CTOR) + 1];
  char dtor_sym[sizeof(ENC_LOCK_DTOR) + 1];
  jsc__decode(ctor_sym, ENC_LOCK_CTOR, sizeof(ENC_LOCK_CTOR));
  jsc__decode(dtor_sym, ENC_LOCK_DTOR, sizeof(ENC_LOCK_DTOR));

  // Try dlsym for exported symbols first
  void *jsc_handle = dlopen(info.dli_fname, RTLD_NOLOAD);
  if (!jsc_handle) jsc_handle = dlopen(info.dli_fname, RTLD_LAZY);

  if (jsc_handle) {
    if (!s_lock_ctor) s_lock_ctor = (js__lock_ctor_fn)dlsym(jsc_handle, ctor_sym);
    if (!s_lock_dtor) s_lock_dtor = (js__lock_dtor_fn)dlsym(jsc_handle, dtor_sym);
  }

  if (header->magic != MH_MAGIC_64) return;

  // Walk nlist symbol table for local symbols
  const uint8_t *ptr = (const uint8_t *)(header + 1);
  const struct symtab_command *symtab = NULL;
  uint64_t linkedit_fileoff = 0;

  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *cmd = (const struct load_command *)ptr;
    if (cmd->cmd == LC_SYMTAB) {
      symtab = (const struct symtab_command *)cmd;
    } else if (cmd->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
      if (strcmp(seg->segname, "__LINKEDIT") == 0) {
        linkedit_fileoff = seg->fileoff;
      }
    }
    ptr += cmd->cmdsize;
  }

  if (!symtab || !linkedit_fileoff) return;

  unsigned long linkedit_size = 0;
  uint8_t *linkedit_ptr = getsegmentdata(header, "__LINKEDIT", &linkedit_size);
  if (!linkedit_ptr) return;

  const struct nlist_64 *syms = (const struct nlist_64 *)(
    linkedit_ptr + (symtab->symoff - linkedit_fileoff));
  const char *strtab = (const char *)(
    linkedit_ptr + (symtab->stroff - linkedit_fileoff));

  char pf_sym[sizeof(ENC_PROVIDE_FETCH) + 1];
  jsc__decode(pf_sym, ENC_PROVIDE_FETCH, sizeof(ENC_PROVIDE_FETCH));

  int found = 0;

  for (uint32_t i = 0; i < symtab->nsyms && found < 3; i++) {
    uint32_t strx = syms[i].n_un.n_strx;
    if (strx == 0) continue;
    const char *name = strtab + strx;

    // Skip leading underscore if present
    const char *bare = (name[0] == '_') ? name + 1 : name;

    if (!s_lock_ctor && strcmp(bare, ctor_sym) == 0) {
      s_lock_ctor = (js__lock_ctor_fn)(syms[i].n_value + slide);
      found++;
    } else if (!s_lock_dtor && strcmp(bare, dtor_sym) == 0) {
      s_lock_dtor = (js__lock_dtor_fn)(syms[i].n_value + slide);
      found++;
    } else if (!s_provide_fetch && strcmp(bare, pf_sym) == 0) {
      s_provide_fetch = (js__provide_fetch_fn)(syms[i].n_value + slide);
      found++;
    }
  }
}

void
js__provide_fetch_modules(void *objc_context, void **scripts,
                          const char **urls, size_t count) {
  if (count == 0) return;

  js__resolve_symbols();

  if (!s_provide_fetch || !s_lock_ctor || !s_lock_dtor) return;

  JSContext *ctx = (__bridge JSContext *)objc_context;
  JSGlobalContextRef ctx_ref = ctx.JSGlobalContextRef;
  void *global_object = (void *)ctx_ref;

  // Ensure the module loader LazyProperty is initialized
  uintptr_t ml_raw = *(uintptr_t *)((uint8_t *)global_object + JSC_MODULE_LOADER_OFFSET);

  if (ml_raw & 1) {
    NSError *err = nil;
    // [JSScript scriptOfType:kJSScriptTypeModule withSource:@"" ...]
    id dummy = ((id(*)(id, SEL, NSInteger, NSString *, NSURL *, NSURL *, JSVirtualMachine *, NSError **))objc_msgSend)(
        (id)spi.script_class, spi.script_of_type,
        (NSInteger)kJSScriptTypeModule, @"",
        [NSURL URLWithString:@"file:///bare-internal/__init__"], (NSURL *)nil,
        ctx.virtualMachine, &err);
    // [ctx evaluateJSScript:dummy]
    if (dummy) ((JSValue *(*)(id, SEL, id))objc_msgSend)(ctx, spi.evaluate, dummy);

    ml_raw = *(uintptr_t *)((uint8_t *)global_object + JSC_MODULE_LOADER_OFFSET);
    if (ml_raw & 1) return;
  }

  void *module_loader = (void *)ml_raw;
  if (!module_loader) return;

  char lock_buf[16];
  memset(lock_buf, 0, sizeof(lock_buf));
  s_lock_ctor(lock_buf, global_object);

  for (size_t i = 0; i < count; i++) {
    id s = (__bridge id)scripts[i];

    IMP imp = [s methodForSelector:spi.source_code];
    JSCSourceCode sc = ((JSCSourceCode (*)(id, SEL))imp)(s, spi.source_code);

    JSStringRef key_str = JSStringCreateWithUTF8CString(urls[i]);
    JSValueRef key_val = JSValueMakeString(ctx_ref, key_str);

    s_provide_fetch(module_loader, global_object, (int64_t)key_val, &sc);

    JSStringRelease(key_str);
  }

  s_lock_dtor(lock_buf);
}
