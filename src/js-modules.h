#ifndef JS_MODULES_H
#define JS_MODULES_H

#include <JavaScriptCore/JavaScriptCore.h>

typedef struct js_env_s js_env_t;

// Create a JSContext via Obj-C API (required for module loader support).
// Returns a retained void* (JSContext*). Sets *out_ctx to the underlying
// JSGlobalContextRef and *out_group to its JSContextGroupRef.
void *
js__objc_context_create(JSGlobalContextRef *out_ctx, JSContextGroupRef *out_group);

void
js__objc_context_release(void *objc_context);

// Module loader delegate — routes module fetches to the C resolve callback
// stored on the env's current_loading_module.
void *
js__module_delegate_create(js_env_t *env);

void
js__module_delegate_release(void *delegate);

void
js__module_delegate_set(void *objc_context, void *delegate);

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

#endif // JS_MODULES_H
