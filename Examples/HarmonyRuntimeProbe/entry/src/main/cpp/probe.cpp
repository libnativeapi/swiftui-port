#include <cerrno>
#include <cstdint>
#include <spawn.h>
#include <napi/native_api.h>

extern "C" std::int32_t swift_runtime_probe(std::int32_t seed);
extern "C" std::int32_t swift_foundation_probe();
extern "C" std::int32_t swift_render_probe(bool tap);
extern "C" void swift_concurrency_probe(void* context, void (*callback)(void*, std::int32_t));

napi_value AttachArkUI(napi_env env, napi_callback_info info);
napi_value DetachArkUI(napi_env env, napi_callback_info info);
napi_value MountGallery(napi_env env, napi_callback_info info);
napi_value ResizeGallery(napi_env env, napi_callback_info info);
napi_value GalleryEvent(napi_env env, napi_callback_info info);
napi_value UnmountGallery(napi_env env, napi_callback_info info);

// Foundation's Linux archive references this musl extension. The OHOS NDK
// does not export it, and this fixture has a fixed process name.
extern "C" {
static char probeProcessName[] = "dev.swiftuiport.runtimeprobe";
__attribute__((visibility("hidden"))) char* program_invocation_short_name = probeProcessName;

// The probe does not spawn subprocesses. Report the unavailable Foundation
// operation if it is ever called instead of silently ignoring the directory.
__attribute__((visibility("hidden")))
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t*, const char*) {
  return ENOTSUP;
}
}

static napi_value Number(napi_env env, std::int32_t value) {
  napi_value result;
  if (napi_create_int32(env, value, &result) != napi_ok) {
    napi_throw_error(env, nullptr, "Cannot return the Swift result");
    return nullptr;
  }
  return result;
}

static napi_value Run(napi_env env, napi_callback_info info) {
  napi_value argument;
  size_t count = 1;
  std::int32_t seed;
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok ||
      count != 1 || napi_get_value_int32(env, argument, &seed) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Expected an integer seed");
    return nullptr;
  }
  return Number(env, swift_runtime_probe(seed));
}

static napi_value Foundation(napi_env env, napi_callback_info) {
  return Number(env, swift_foundation_probe());
}

static napi_value Render(napi_env env, napi_callback_info) {
  return Number(env, swift_render_probe(false));
}

static napi_value Tap(napi_env env, napi_callback_info) {
  return Number(env, swift_render_probe(true));
}

static napi_value Concurrency(napi_env env, napi_callback_info info) {
  napi_value callback;
  size_t count = 1;
  napi_valuetype type;
  if (napi_get_cb_info(env, info, &count, &callback, nullptr, nullptr) != napi_ok ||
      count != 1 || napi_typeof(env, callback, &type) != napi_ok || type != napi_function) {
    napi_throw_type_error(env, nullptr, "Expected a callback");
    return nullptr;
  }
  napi_threadsafe_function completion;
  napi_value name;
  if (napi_create_string_utf8(env, "Swift concurrency probe", NAPI_AUTO_LENGTH, &name) != napi_ok ||
      napi_create_threadsafe_function(
          env, callback, nullptr, name, 1, 1, nullptr, nullptr, nullptr,
          [](napi_env callEnv, napi_value function, void*, void* data) {
            if (callEnv == nullptr || function == nullptr) return;
            napi_value receiver;
            if (napi_get_undefined(callEnv, &receiver) != napi_ok) return;
            napi_value value = Number(callEnv, static_cast<std::int32_t>(reinterpret_cast<std::intptr_t>(data)));
            if (value != nullptr) napi_call_function(callEnv, receiver, function, 1, &value, nullptr);
          },
          &completion) != napi_ok) {
    napi_throw_error(env, nullptr, "Cannot create the concurrency callback");
    return nullptr;
  }
  swift_concurrency_probe(completion, [](void* context, std::int32_t value) {
    const auto function = static_cast<napi_threadsafe_function>(context);
    napi_call_threadsafe_function(function,
        reinterpret_cast<void*>(static_cast<std::intptr_t>(value)), napi_tsfn_nonblocking);
    napi_release_threadsafe_function(function, napi_tsfn_release);
  });
  napi_value undefined;
  return napi_get_undefined(env, &undefined) == napi_ok ? undefined : nullptr;
}

static napi_value Init(napi_env env, napi_value exports) {
  const napi_property_descriptor properties[] = {
      {"run", nullptr, Run, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"foundation", nullptr, Foundation, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"concurrency", nullptr, Concurrency, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"render", nullptr, Render, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"tap", nullptr, Tap, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"attach", nullptr, AttachArkUI, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"detach", nullptr, DetachArkUI, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"mountGallery", nullptr, MountGallery, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"resizeGallery", nullptr, ResizeGallery, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"galleryEvent", nullptr, GalleryEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"unmountGallery", nullptr, UnmountGallery, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  if (napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) return nullptr;
  return exports;
}

static napi_module module = {1, 0, nullptr, Init, "swiftprobe", nullptr, {0}};

__attribute__((constructor)) static void Register() {
  napi_module_register(&module);
}
