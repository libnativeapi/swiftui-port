#include <cerrno>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <napi/native_api.h>
#include <native_drawing/drawing_font_collection.h>
#include <native_drawing/drawing_text_typography.h>
#include <uv.h>
#include <unistd.h>

using Update = void (*)(void*, const char*);
extern "C" void swift_mount_gallery(void* context, Update update, double width, double height,
                                    double pixelsPerPoint);
extern "C" void swift_resize_gallery(double width, double height);
extern "C" void swift_gallery_event(std::intptr_t id, std::int32_t event, const char* text);
extern "C" void swift_unmount_gallery();
extern "C" int _dispatch_get_main_queue_port_4CF();
extern "C" void _dispatch_main_queue_callback_4CF(void*);

namespace {
struct Gallery {
  napi_env env = nullptr;
  napi_ref callback = nullptr;
  uv_poll_t* mainQueue = nullptr;
} gallery;

struct MainQueueWatch {
  uv_poll_t poll{};
  int descriptor;
};

bool WatchMainQueue(napi_env env) {
  uv_loop_t* loop;
  const int descriptor = _dispatch_get_main_queue_port_4CF();
  if (descriptor < 0 || napi_get_uv_event_loop(env, &loop) != napi_ok) return false;
  auto* watch = new MainQueueWatch{{}, descriptor};
  if (uv_poll_init(loop, &watch->poll, descriptor) != 0) {
    delete watch;
    return false;
  }
  watch->poll.data = watch;
  gallery.mainQueue = &watch->poll;
  return uv_poll_start(&watch->poll, UV_READABLE, [](uv_poll_t* handle, int status, int events) {
    if (status != 0 || (events & UV_READABLE) == 0) return;
    const auto* watch = static_cast<MainQueueWatch*>(handle->data);
    std::uint64_t wakeup;
    ssize_t count;
    do { count = read(watch->descriptor, &wakeup, sizeof(wakeup)); } while (count < 0 && errno == EINTR);
    if (count == sizeof(wakeup)) _dispatch_main_queue_callback_4CF(nullptr);
  }) == 0;
}

void UpdateTree(void* context, const char* json) {
  auto& host = *static_cast<Gallery*>(context);
  napi_value callback, receiver, argument;
  if (napi_get_reference_value(host.env, host.callback, &callback) != napi_ok ||
      napi_get_undefined(host.env, &receiver) != napi_ok ||
      napi_create_string_utf8(host.env, json, NAPI_AUTO_LENGTH, &argument) != napi_ok) return;
  napi_call_function(host.env, receiver, callback, 1, &argument, nullptr);
}

napi_value Undefined(napi_env env) {
  napi_value result;
  return napi_get_undefined(env, &result) == napi_ok ? result : nullptr;
}

void Unmount(void*) {
  swift_unmount_gallery();
  if (gallery.mainQueue != nullptr) {
    uv_poll_stop(gallery.mainQueue);
    uv_close(reinterpret_cast<uv_handle_t*>(gallery.mainQueue), [](uv_handle_t* handle) {
      delete static_cast<MainQueueWatch*>(handle->data);
    });
  }
  if (gallery.callback != nullptr) napi_delete_reference(gallery.env, gallery.callback);
  gallery = {};
}

bool Dimensions(napi_env env, const napi_value* args, double& width, double& height) {
  return napi_get_value_double(env, args[0], &width) == napi_ok &&
         napi_get_value_double(env, args[1], &height) == napi_ok &&
         std::isfinite(width) && std::isfinite(height) && width > 0 && height > 0;
}
}

extern "C" bool harmony_measure_text(const char* text, const char* family, double fontSize,
                                     int weight, double* width, double* height) {
  auto* fonts = OH_Drawing_GetFontCollectionGlobalInstance();
  std::unique_ptr<OH_Drawing_TypographyStyle, decltype(&OH_Drawing_DestroyTypographyStyle)>
      paragraph(OH_Drawing_CreateTypographyStyle(), OH_Drawing_DestroyTypographyStyle);
  std::unique_ptr<OH_Drawing_TextStyle, decltype(&OH_Drawing_DestroyTextStyle)>
      style(OH_Drawing_CreateTextStyle(), OH_Drawing_DestroyTextStyle);
  if (!fonts || !paragraph || !style) return false;
  OH_Drawing_SetTypographyTextDirection(paragraph.get(), TEXT_DIRECTION_LTR);
  OH_Drawing_SetTextStyleFontSize(style.get(), fontSize);
  OH_Drawing_SetTextStyleFontWeight(style.get(), weight);
  if (*family != '\0') OH_Drawing_SetTextStyleFontFamilies(style.get(), 1, &family);
  std::unique_ptr<OH_Drawing_TypographyCreate, decltype(&OH_Drawing_DestroyTypographyHandler)>
      builder(OH_Drawing_CreateTypographyHandler(paragraph.get(), fonts), OH_Drawing_DestroyTypographyHandler);
  if (!builder) return false;
  OH_Drawing_TypographyHandlerPushTextStyle(builder.get(), style.get());
  OH_Drawing_TypographyHandlerAddText(builder.get(), *text == '\0' ? " " : text);
  OH_Drawing_TypographyHandlerPopTextStyle(builder.get());
  std::unique_ptr<OH_Drawing_Typography, decltype(&OH_Drawing_DestroyTypography)>
      layout(OH_Drawing_CreateTypography(builder.get()), OH_Drawing_DestroyTypography);
  if (!layout) return false;
  OH_Drawing_TypographyLayout(layout.get(), INFINITY);
  *width = *text == '\0' ? 0 : std::ceil(OH_Drawing_TypographyGetLongestLine(layout.get()));
  *height = std::ceil(OH_Drawing_TypographyGetHeight(layout.get()));
  return std::isfinite(*width) && std::isfinite(*height) && *height > 0;
}

napi_value MountGallery(napi_env env, napi_callback_info info) {
  napi_value args[4];
  size_t count = 4;
  double width, height, pixelsPerPoint;
  napi_valuetype type;
  if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 4 ||
      napi_typeof(env, args[0], &type) != napi_ok || type != napi_function ||
      !Dimensions(env, args + 1, width, height) ||
      napi_get_value_double(env, args[3], &pixelsPerPoint) != napi_ok ||
      !std::isfinite(pixelsPerPoint) || pixelsPerPoint <= 0) {
    napi_throw_type_error(env, nullptr, "Expected a Gallery callback, width, height and pixel density");
    return nullptr;
  }
  if (gallery.callback != nullptr) {
    napi_throw_error(env, nullptr, "Gallery is already mounted");
    return nullptr;
  }
  if (napi_create_reference(env, args[0], 1, &gallery.callback) != napi_ok) return nullptr;
  gallery.env = env;
  if (napi_add_env_cleanup_hook(env, Unmount, nullptr) != napi_ok) {
    Unmount(nullptr);
    return nullptr;
  }
  if (!WatchMainQueue(env)) {
    napi_remove_env_cleanup_hook(env, Unmount, nullptr);
    Unmount(nullptr);
    napi_throw_error(env, nullptr, "Cannot attach Swift's main queue to the UI loop");
    return nullptr;
  }
  swift_mount_gallery(&gallery, UpdateTree, width, height, pixelsPerPoint);
  return Undefined(env);
}

napi_value ResizeGallery(napi_env env, napi_callback_info info) {
  napi_value args[2];
  size_t count = 2;
  double width, height;
  if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok ||
      count != 2 || !Dimensions(env, args, width, height)) {
    napi_throw_type_error(env, nullptr, "Expected a positive Gallery size");
    return nullptr;
  }
  swift_resize_gallery(width, height);
  return Undefined(env);
}

napi_value GalleryEvent(napi_env env, napi_callback_info info) {
  napi_value args[3];
  size_t count = 3, length;
  std::int64_t id;
  std::int32_t event;
  if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 3 ||
      napi_get_value_int64(env, args[0], &id) != napi_ok ||
      napi_get_value_int32(env, args[1], &event) != napi_ok ||
      napi_get_value_string_utf8(env, args[2], nullptr, 0, &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Expected a Swift node ID, event and text");
    return nullptr;
  }
  std::string text(length + 1, '\0');
  if (napi_get_value_string_utf8(env, args[2], text.data(), text.size(), nullptr) != napi_ok) return nullptr;
  swift_gallery_event(id, event, text.c_str());
  return Undefined(env);
}

napi_value UnmountGallery(napi_env env, napi_callback_info) {
  if (gallery.callback != nullptr && gallery.env == env) {
    napi_remove_env_cleanup_hook(env, Unmount, nullptr);
    Unmount(nullptr);
  }
  return Undefined(env);
}
