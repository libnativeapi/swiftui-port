#include <arkui/native_interface.h>
#include <arkui/native_node.h>
#include <arkui/native_node_napi.h>
#include <cstdint>
#include <napi/native_api.h>

using Visit = void (*)(void*, std::int32_t, std::intptr_t, const char*, double, double, double, double);
extern "C" void swift_visit_probe_controls(void* context, Visit visit);
extern "C" void swift_tap_probe_control(std::intptr_t id);

namespace {
// The single probe page owns this slot and calls Detach before it disappears.
struct {
  ArkUI_NativeNodeAPI_1* api = nullptr;
  ArkUI_NodeContentHandle content = nullptr;
  ArkUI_NodeHandle root = nullptr;
  ArkUI_NodeHandle label = nullptr;
  ArkUI_NodeHandle button = nullptr;
  std::intptr_t buttonId = 0;
  bool failed = false;
} page;

bool SetText(ArkUI_NodeHandle node, ArkUI_NodeAttributeType attribute, const char* text) {
  const ArkUI_AttributeItem item{nullptr, 0, text, nullptr};
  return page.api->setAttribute(node, attribute, &item) == 0;
}

bool SetGeometry(ArkUI_NodeHandle node, ArkUI_NodeAttributeType attribute, float x, float y = 0) {
  ArkUI_NumberValue values[2]{};
  values[0].f32 = x;
  values[1].f32 = y;
  const ArkUI_AttributeItem item{values, attribute == NODE_POSITION ? 2 : 1, nullptr, nullptr};
  return page.api->setAttribute(node, attribute, &item) == 0;
}

void OnClick(ArkUI_NodeEvent* event) {
  if (OH_ArkUI_NodeEvent_GetEventType(event) != NODE_ON_CLICK || page.buttonId == 0) return;
  swift_tap_probe_control(page.buttonId);
  swift_visit_probe_controls(nullptr, [](void*, std::int32_t kind, std::intptr_t, const char* text,
                                        double, double, double, double) {
    if (kind == 0 && page.label != nullptr) SetText(page.label, NODE_TEXT_CONTENT, text);
  });
}

void AddControl(void*, std::int32_t kind, std::intptr_t id, const char* text,
                double x, double y, double width, double height) {
  if (page.failed) return;
  auto& control = kind == 1 ? page.button : page.label;
  const auto node = page.api->createNode(kind == 1 ? ARKUI_NODE_BUTTON : ARKUI_NODE_TEXT);
  if (node == nullptr ||
      !SetText(node, kind == 1 ? NODE_BUTTON_LABEL : NODE_TEXT_CONTENT, text) ||
      !SetGeometry(node, NODE_WIDTH, width) ||
      !SetGeometry(node, NODE_HEIGHT, height) ||
      !SetGeometry(node, NODE_POSITION, x, y) ||
      page.api->addChild(page.root, node) != 0) {
    if (node != nullptr) page.api->disposeNode(node);
    page.failed = true;
    return;
  }
  control = node;
  if (kind == 1) {
    page.buttonId = id;
    page.failed = page.api->addNodeEventReceiver(node, OnClick) != 0 ||
                  page.api->registerNodeEvent(node, NODE_ON_CLICK, 1, nullptr) != 0;
  }
}

void Detach() {
  if (page.root == nullptr) return;
  if (page.content != nullptr) OH_ArkUI_NodeContent_RemoveNode(page.content, page.root);
  if (page.button != nullptr) {
    page.api->unregisterNodeEvent(page.button, NODE_ON_CLICK);
    page.api->removeNodeEventReceiver(page.button, OnClick);
    page.api->removeChild(page.root, page.button);
    page.api->disposeNode(page.button);
  }
  if (page.label != nullptr) {
    page.api->removeChild(page.root, page.label);
    page.api->disposeNode(page.label);
  }
  page.api->disposeNode(page.root);
  page = {};
}
}

napi_value AttachArkUI(napi_env env, napi_callback_info info) {
  napi_value argument;
  size_t count = 1;
  ArkUI_NodeContentHandle content = nullptr;
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok ||
      count != 1 || OH_ArkUI_GetNodeContentFromNapiValue(env, argument, &content) != 0 ||
      content == nullptr) {
    napi_throw_type_error(env, nullptr, "Expected an ArkUI NodeContent");
    return nullptr;
  }
  Detach();
  page.api = reinterpret_cast<ArkUI_NativeNodeAPI_1*>(
      OH_ArkUI_QueryModuleInterfaceByName(ARKUI_NATIVE_NODE, "ArkUI_NativeNodeAPI_1"));
  if (page.api != nullptr) page.root = page.api->createNode(ARKUI_NODE_STACK);
  if (page.root != nullptr && SetGeometry(page.root, NODE_WIDTH, 320) &&
      SetGeometry(page.root, NODE_HEIGHT, 200)) {
    swift_visit_probe_controls(nullptr, AddControl);
    if (!page.failed && page.label != nullptr && page.button != nullptr &&
        OH_ArkUI_NodeContent_AddNode(content, page.root) == 0) {
      page.content = content;
      napi_value undefined;
      return napi_get_undefined(env, &undefined) == napi_ok ? undefined : nullptr;
    }
  }
  Detach();
  napi_throw_error(env, nullptr, "Cannot attach the native Swift probe controls");
  return nullptr;
}

napi_value DetachArkUI(napi_env env, napi_callback_info) {
  Detach();
  napi_value undefined;
  return napi_get_undefined(env, &undefined) == napi_ok ? undefined : nullptr;
}
