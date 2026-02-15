#ifndef JS_MODULES_H
#define JS_MODULES_H

#include <JavaScriptCore/JavaScriptCore.h>

typedef struct js_env_s js_env_t;
typedef struct js_module_s js_module_t;

void *
js__objc_context_create(JSGlobalContextRef *out_ctx, JSContextGroupRef *out_group);

void
js__objc_context_release(void *objc_context);

void *
js__module_delegate_create(js_env_t *env);

void
js__module_delegate_release(void *delegate);

void
js__module_delegate_set(void *objc_context, void *delegate);

void
js__module_delegate_register(void *delegate, const char *url, js_module_t *module);

js_module_t *
js__module_delegate_lookup(void *delegate, const char *url);

int
js__module_delegate_drain_one(void *delegate);

int
js__drain_run_loop(void);

void *
js__module_script_create(void *objc_context, const char *source, const char *url);

void
js__module_script_release(void *script);

JSValueRef
js__module_script_evaluate(void *objc_context, void *script);

void
js__objc_set_global_property(void *objc_context, const char *key, JSValueRef value);

void
js__provide_fetch_modules(void *objc_context, void **scripts,
                          const char **urls, size_t count);

#endif // JS_MODULES_H
