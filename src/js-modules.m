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
    // Handle internal dummy modules (e.g. LazyProperty init script)
    if ([idStr hasPrefix:@"file:///bare-internal/"]) {
      NSError *err = nil;
      JSScript *dummy = [JSScript scriptOfType:kJSScriptTypeModule
                                    withSource:@""
                                  andSourceURL:[NSURL URLWithString:idStr]
                              andBytecodeCache:nil
                              inVirtualMachine:context.virtualMachine
                                         error:&err];
      if (dummy) {
        [resolve callWithArguments:@[dummy]];
        return;
      }
    }
    NSLog(@"[libjsc] delegate: module NOT FOUND in registry: '%@'", idStr);
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
  // Log thread stack info — helps debug "Maximum call stack size exceeded"
  pthread_t self = pthread_self();
  size_t stack_size = pthread_get_stacksize_np(self);
  void *stack_addr = pthread_get_stackaddr_np(self);
  NSLog(@"[libjsc] Created Obj-C JSContext: %p, globalCtx: %p (thread stack: %p, %zu KB)",
        ctx, *out_ctx, stack_addr, stack_size / 1024);
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
// Direct provideFetch — pre-populate JSC's internal module fetch map
// -----------------------------------------------------------------------
// JSC's module loader has an internal registry keyed by module identifier.
// When `requestFetch(entry)` runs, it checks `entry.fetch` first — if
// already populated, it skips the delegate entirely and returns the cached
// source. The C++ method JSModuleLoader::provideFetch() populates this.
//
// Strategy:
//   1. Find provideFetch + JSLockHolder via nlist (local symbols in JSC)
//   2. Get the JSModuleLoader* from JSGlobalObject at a known offset
//      (0x2a8 on iOS 26 arm64, found by disassembling JSC::loadModule)
//   3. Extract the SourceCode from each JSScript via -[JSScript sourceCode]
//   4. Call provideFetch(moduleLoader, globalObject, key, &sourceCode)
//      for every dependency module BEFORE evaluating the root
//   5. evaluateJSScript: on the root — all imports resolve from the
//      pre-populated fetch map via microtask queue. No delegate calls,
//      no recursive stack buildup. Constant stack depth.

#include <pthread.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <objc/message.h>

typedef void (*js__lock_ctor_fn)(void *self, void *globalObject);
typedef void (*js__lock_dtor_fn)(void *self);

// provideFetch: JSModuleLoader::provideFetch(JSGlobalObject*, JSValue, SourceCode const&)
// ARM64 calling convention: x0=this, x1=globalObject, x2=JSValue(key), x3=&sourceCode
// Returns JSValue in x0.
typedef int64_t (*js__provide_fetch_fn)(void *self, void *globalObject,
                                        int64_t key, void *sourceCode);

static js__lock_ctor_fn s_lock_ctor = NULL;
static js__lock_dtor_fn s_lock_dtor = NULL;
static js__provide_fetch_fn s_provide_fetch = NULL;
static bool s_symbols_resolved = false;

// Offset of m_moduleLoader in JSGlobalObject (from disassembling
// JSC::loadModule on iOS 26 arm64 simulator — ldr x0, [x20, #0x2a8]).
#define JSC_MODULE_LOADER_OFFSET 0x2a8

// SourceCode struct layout — matches JSC::SourceCode exactly:
//   RefPtr<SourceProvider> m_provider  (8 bytes — raw pointer)
//   int m_startChar                    (4 bytes)
//   int m_endChar                      (4 bytes)
//   int m_firstLine                    (4 bytes)
//   int m_startColumn                  (4 bytes)
// Total: 24 bytes, 8-byte aligned.
typedef struct {
  void *provider;
  int start_char;
  int end_char;
  int first_line;
  int start_column;
} JSCSourceCode;

// Walk the Mach-O nlist symbol table to find a local symbol by name.
// Returns the runtime address or NULL.
static void *
js__nlist_find(const struct mach_header_64 *header, uintptr_t slide,
               const char *target) {
  const uint8_t *ptr = (const uint8_t *)(header + 1);
  const struct symtab_command *symtab = NULL;

  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *cmd = (const struct load_command *)ptr;
    if (cmd->cmd == LC_SYMTAB) {
      symtab = (const struct symtab_command *)cmd;
      break;
    }
    ptr += cmd->cmdsize;
  }
  if (!symtab) return NULL;

  // Find __LINKEDIT base
  uintptr_t linkedit_base = 0;
  ptr = (const uint8_t *)(header + 1);
  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *cmd = (const struct load_command *)ptr;
    if (cmd->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
      if (strcmp(seg->segname, "__LINKEDIT") == 0) {
        linkedit_base = seg->vmaddr - seg->fileoff + slide;
        break;
      }
    }
    ptr += cmd->cmdsize;
  }
  if (!linkedit_base) return NULL;

  const struct nlist_64 *syms =
    (const struct nlist_64 *)(linkedit_base + symtab->symoff);
  const char *strtab = (const char *)(linkedit_base + symtab->stroff);

  for (uint32_t i = 0; i < symtab->nsyms; i++) {
    const char *name = strtab + syms[i].n_un.n_strx;
    if (strcmp(name, target) == 0) {
      return (void *)(syms[i].n_value + slide);
    }
  }
  return NULL;
}

static void
js__resolve_symbols(void) {
  if (s_symbols_resolved) return;
  s_symbols_resolved = true;

  Dl_info info;
  if (!dladdr((void *)JSEvaluateScript, &info) || !info.dli_fname) {
    NSLog(@"[libjsc] provideFetch: dladdr failed");
    return;
  }
  NSLog(@"[libjsc] provideFetch: JSC image at %s", info.dli_fname);

  const struct mach_header_64 *header =
    (const struct mach_header_64 *)info.dli_fbase;

  // --- Get proper ASLR slide from dyld ---
  // CRITICAL: For shared cache images (like JSC on iOS simulator),
  // slide = actual_load_address - preferred_vmaddr, NOT just dli_fbase.
  // Using dli_fbase directly as slide causes linkedit_base to point to
  // garbage memory and crashes during nlist walk.
  intptr_t slide = 0;
  bool found_image = false;
  for (uint32_t img = 0; img < _dyld_image_count(); img++) {
    if (_dyld_get_image_header(img) == (const struct mach_header *)header) {
      slide = _dyld_get_image_vmaddr_slide(img);
      found_image = true;
      break;
    }
  }
  if (!found_image) {
    NSLog(@"[libjsc] provideFetch: JSC image not found in dyld image list");
    return;
  }
  NSLog(@"[libjsc] provideFetch: header=%p slide=0x%lx", header, (long)slide);

  // --- Try dlsym for exported symbols first ---
  void *jsc_handle = dlopen(info.dli_fname, RTLD_NOLOAD);
  if (!jsc_handle) jsc_handle = dlopen(info.dli_fname, RTLD_LAZY);
  NSLog(@"[libjsc] provideFetch: dlopen handle=%p", jsc_handle);

  const char *ctor_names[] = {
    "_ZN3JSC12JSLockHolderC1EPNS_14JSGlobalObjectE",
    "__ZN3JSC12JSLockHolderC1EPNS_14JSGlobalObjectE", NULL
  };
  const char *dtor_names[] = {
    "_ZN3JSC12JSLockHolderD1Ev",
    "__ZN3JSC12JSLockHolderD1Ev", NULL
  };

  if (jsc_handle) {
    for (int i = 0; ctor_names[i] && !s_lock_ctor; i++)
      s_lock_ctor = (js__lock_ctor_fn)dlsym(jsc_handle, ctor_names[i]);
    for (int i = 0; dtor_names[i] && !s_lock_dtor; i++)
      s_lock_dtor = (js__lock_dtor_fn)dlsym(jsc_handle, dtor_names[i]);
  }

  NSLog(@"[libjsc] provideFetch: after dlsym: ctor=%p dtor=%p",
        s_lock_ctor, s_lock_dtor);

  if (header->magic != MH_MAGIC_64) {
    NSLog(@"[libjsc] provideFetch: not MH_MAGIC_64 (magic=0x%x)", header->magic);
    return;
  }

  // Find LC_SYMTAB and __LINKEDIT segment command
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

  if (!symtab || !linkedit_fileoff) {
    NSLog(@"[libjsc] provideFetch: symtab=%p linkedit_fileoff=0x%llx — cannot walk nlist",
          symtab, linkedit_fileoff);
    return;
  }

  // Use getsegmentdata() to get __LINKEDIT's actual memory address.
  // This handles dyld shared cache correctly (where vmaddr-fileoff+slide fails).
  unsigned long linkedit_size = 0;
  uint8_t *linkedit_ptr = getsegmentdata(
    header, "__LINKEDIT", &linkedit_size);

  if (!linkedit_ptr) {
    NSLog(@"[libjsc] provideFetch: getsegmentdata(__LINKEDIT) returned NULL");
    return;
  }

  NSLog(@"[libjsc] provideFetch: __LINKEDIT at %p (size=%lu, fileoff=0x%llx)",
        linkedit_ptr, linkedit_size, linkedit_fileoff);

  // symtab->symoff and symtab->stroff are file offsets. Compute their
  // position within __LINKEDIT: (file_offset - linkedit_fileoff) bytes
  // from the start of the __LINKEDIT segment in memory.
  const struct nlist_64 *syms = (const struct nlist_64 *)(
    linkedit_ptr + (symtab->symoff - linkedit_fileoff));
  const char *strtab = (const char *)(
    linkedit_ptr + (symtab->stroff - linkedit_fileoff));

  NSLog(@"[libjsc] provideFetch: walking %u symbols...", symtab->nsyms);

  // Target symbols — search for all of them in a single pass
  int found = 0;
  const int NEED = 3; // ctor + dtor + provideFetch

  for (uint32_t i = 0; i < symtab->nsyms && found < NEED; i++) {
    uint32_t strx = syms[i].n_un.n_strx;
    if (strx == 0) continue;
    const char *name = strtab + strx;

    if (!s_lock_ctor &&
        strcmp(name, "__ZN3JSC12JSLockHolderC1EPNS_14JSGlobalObjectE") == 0) {
      s_lock_ctor = (js__lock_ctor_fn)(syms[i].n_value + slide);
      found++;
    } else if (!s_lock_dtor &&
        strcmp(name, "__ZN3JSC12JSLockHolderD1Ev") == 0) {
      s_lock_dtor = (js__lock_dtor_fn)(syms[i].n_value + slide);
      found++;
    } else if (!s_provide_fetch &&
        strcmp(name, "__ZN3JSC14JSModuleLoader12provideFetchEPNS_14JSGlobalObjectENS_7JSValueERKNS_10SourceCodeE") == 0) {
      s_provide_fetch = (js__provide_fetch_fn)(syms[i].n_value + slide);
      found++;
    }
  }

  // If not found with double underscore, try single underscore convention
  if (!s_lock_ctor || !s_lock_dtor || !s_provide_fetch) {
    for (uint32_t i = 0; i < symtab->nsyms && found < NEED; i++) {
      uint32_t strx = syms[i].n_un.n_strx;
      if (strx == 0) continue;
      const char *name = strtab + strx;

      if (!s_lock_ctor &&
          strcmp(name, "_ZN3JSC12JSLockHolderC1EPNS_14JSGlobalObjectE") == 0) {
        s_lock_ctor = (js__lock_ctor_fn)(syms[i].n_value + slide);
        found++;
      } else if (!s_lock_dtor &&
          strcmp(name, "_ZN3JSC12JSLockHolderD1Ev") == 0) {
        s_lock_dtor = (js__lock_dtor_fn)(syms[i].n_value + slide);
        found++;
      } else if (!s_provide_fetch &&
          strcmp(name, "_ZN3JSC14JSModuleLoader12provideFetchEPNS_14JSGlobalObjectENS_7JSValueERKNS_10SourceCodeE") == 0) {
        s_provide_fetch = (js__provide_fetch_fn)(syms[i].n_value + slide);
        found++;
      }
    }
  }

  NSLog(@"[libjsc] symbols: lock_ctor=%p lock_dtor=%p provideFetch=%p",
        s_lock_ctor, s_lock_dtor, s_provide_fetch);
}

void
js__provide_fetch_modules(void *objc_context, void **scripts,
                          const char **urls, size_t count) {
  if (count == 0) return;
  js__resolve_symbols();

  if (!s_provide_fetch) {
    NSLog(@"[libjsc] provideFetch: symbol not found — cannot pre-register");
    return;
  }
  if (!s_lock_ctor || !s_lock_dtor) {
    NSLog(@"[libjsc] provideFetch: JSLockHolder not found — cannot acquire lock");
    return;
  }

  JSContext *ctx = (__bridge JSContext *)objc_context;
  JSGlobalContextRef ctx_ref = ctx.JSGlobalContextRef;
  void *global_object = (void *)ctx_ref;

  // Read JSModuleLoader* from JSGlobalObject at known offset.
  // The module loader is stored as a LazyProperty — if bit 0 is set,
  // the property hasn't been initialized yet. Force initialization by
  // evaluating a dummy empty module (no imports = no delegate callbacks).
  uintptr_t ml_raw = *(uintptr_t *)((uint8_t *)global_object + JSC_MODULE_LOADER_OFFSET);
  NSLog(@"[libjsc] provideFetch: globalObject=%p moduleLoader raw=0x%lx (offset 0x%x)",
        global_object, (unsigned long)ml_raw, JSC_MODULE_LOADER_OFFSET);

  if (ml_raw & 1) {
    NSLog(@"[libjsc] provideFetch: LazyProperty bit 0 set — triggering module loader init");
    NSError *err = nil;
    JSScript *dummy = [JSScript scriptOfType:kJSScriptTypeModule
                                  withSource:@""
                                andSourceURL:[NSURL URLWithString:@"file:///bare-internal/__init__"]
                            andBytecodeCache:nil
                            inVirtualMachine:ctx.virtualMachine
                                       error:&err];
    if (dummy) {
      [ctx evaluateJSScript:dummy];
    } else {
      NSLog(@"[libjsc] provideFetch: dummy script creation failed: %@", err);
    }
    ml_raw = *(uintptr_t *)((uint8_t *)global_object + JSC_MODULE_LOADER_OFFSET);
    NSLog(@"[libjsc] provideFetch: after init, moduleLoader raw=0x%lx", (unsigned long)ml_raw);
  }

  if (ml_raw & 1) {
    NSLog(@"[libjsc] provideFetch: moduleLoader still uninitialized after dummy eval!");
    return;
  }

  void *module_loader = (void *)ml_raw;
  if (!module_loader) {
    NSLog(@"[libjsc] provideFetch: moduleLoader is NULL!");
    return;
  }

  // Acquire JSLockHolder — all provideFetch calls happen within the lock.
  // No microtask drain until we release.
  char lock_buf[16];
  memset(lock_buf, 0, sizeof(lock_buf));
  s_lock_ctor(lock_buf, global_object);

  // Get the -[JSScript(Internal) sourceCode] selector
  SEL sourceCodeSel = sel_registerName("sourceCode");

  NSLog(@"[libjsc] provideFetch: pre-registering %zu modules", count);

  for (size_t i = 0; i < count; i++) {
    JSScript *s = (__bridge JSScript *)scripts[i];
    const char *url = urls[i];

    // Extract SourceCode from JSScript via private Obj-C method.
    // Returns a 24-byte struct (JSCSourceCode) by value.
    // On ARM64, structs > 16 bytes use indirect return via x8 register.
    IMP imp = [s methodForSelector:sourceCodeSel];
    JSCSourceCode sc = ((JSCSourceCode (*)(id, SEL))imp)(s, sourceCodeSel);

    // Create JSValue key from module URL
    JSStringRef key_str = JSStringCreateWithUTF8CString(url);
    JSValueRef key_val = JSValueMakeString(ctx_ref, key_str);

    // Call provideFetch(this=moduleLoader, globalObject, key, &sourceCode)
    // On ARM64: JSValueRef IS EncodedJSValue (same bit pattern via reinterpret_cast)
    s_provide_fetch(module_loader, global_object, (int64_t)key_val, &sc);

    JSStringRelease(key_str);
  }

  NSLog(@"[libjsc] provideFetch: releasing lock (microtasks drain)");

  // Release lock — microtasks drain. Since all fetch entries are pre-populated,
  // the drain processes each module's promise chain iteratively (via microtask
  // queue), with constant stack depth. No delegate callbacks.
  s_lock_dtor(lock_buf);

  NSLog(@"[libjsc] provideFetch: complete (%zu modules registered)", count);
}

JSValueRef
js__batch_register_modules(void *objc_context, void **scripts, size_t count) {
  if (count == 0) return NULL;

  JSContext *ctx = (__bridge JSContext *)objc_context;
  JSValue *lastResult = nil;

  for (size_t i = 0; i < count; i++) {
    JSScript *s = (__bridge JSScript *)scripts[i];
    lastResult = [ctx evaluateJSScript:s];
  }

  if (lastResult == nil) return NULL;
  return lastResult.JSValueRef;
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
