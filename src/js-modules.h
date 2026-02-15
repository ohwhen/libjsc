#ifndef JS_MODULES_H
#define JS_MODULES_H

#include <JavaScriptCore/JavaScriptCore.h>

typedef struct js_env_s js_env_t;
typedef struct js_module_s js_module_t;

// Create a JSContext via Obj-C API (required for module loader support).
// Returns a retained void* (JSContext*). Sets *out_ctx to the underlying
// JSGlobalContextRef and *out_group to its JSContextGroupRef.
void *
js__objc_context_create(JSGlobalContextRef *out_ctx, JSContextGroupRef *out_group);

void
js__objc_context_release(void *objc_context);

// Module loader delegate — maintains a registry of pre-resolved modules
// and provides them to JSC when requested during evaluation.
void *
js__module_delegate_create(js_env_t *env);

void
js__module_delegate_release(void *delegate);

void
js__module_delegate_set(void *objc_context, void *delegate);

// Register a module in the delegate's registry by URL.
// The URL should match what JSC will use when requesting the module.
void
js__module_delegate_register(void *delegate, const char *url, js_module_t *module);

// Look up a module in the delegate's registry by URL.
// Returns NULL if not found.
js_module_t *
js__module_delegate_lookup(void *delegate, const char *url);

// JSScript creation. Returns a retained void* (JSScript*).
// `source` is UTF-8, `url` is a URL string for module identity.
void *
js__module_script_create(void *objc_context, const char *source, const char *url);

void
js__module_script_release(void *script);

// Evaluate a module JSScript. Returns the JSValueRef of the evaluation promise.
JSValueRef
js__module_script_evaluate(void *objc_context, void *script);

// Set a property on globalThis via Obj-C context. Used to pass synthetic
// module export values before evaluation.
void
js__objc_set_global_property(void *objc_context, const char *key, JSValueRef value);

// Get JSGlobalContextRef from an Obj-C context.
JSGlobalContextRef
js__objc_get_context_ref(void *objc_context);

// Logging bridge — routes to NSLog so output appears in unified log
void
js__nslog(const char *msg);

// Process pending run loop sources. JSC's module loader dispatches
// dependency resolution via the run loop, not the microtask queue.
// Returns 1 if a source was handled, 0 otherwise.
int
js__drain_run_loop(void);

// Evaluate a JS expression via the Obj-C JSContext API and return the
// integer result. The Obj-C API may have different microtask drain
// behavior than the C API JSEvaluateScript.
int
js__objc_eval_int(void *objc_context, const char *expr);

#endif // JS_MODULES_H
