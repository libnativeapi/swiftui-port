#include "DrawingProbe.h"
#include "SwiftUIWindows.h"
#include <windows.h>

#include <cmath>
#include <commctrl.h>

namespace {
struct Probe {
  drawing_probe_result result{};
  void *surface = nullptr;
  HWND host = nullptr, button = nullptr;
  bool track = false;
  int clicks = 0;
};
LRESULT CALLBACK Observe(HWND hwnd, UINT message, WPARAM wp, LPARAM lp,
                         UINT_PTR, DWORD_PTR data) {
  auto *probe = reinterpret_cast<Probe *>(data);
  if (message == WM_COMMAND && HIWORD(wp) == BN_CLICKED)
    ++probe->clicks;
  if (probe->track) {
    if (message == WM_WINDOWPOSCHANGED)
      ++probe->result.position_changes;
    if (message == WM_PAINT)
      ++probe->result.immediate_paints;
  }
  return DefSubclassProc(hwnd, message, wp, lp);
}
void Frame(Probe &p, bool hover, double clip_width = 80) {
  sui_surface_begin(p.surface);
  sui_surface_shape(p.surface, 0, 0, 1000, 1000, 0, 0xFF102030, 0, 0);
  sui_surface_shape(p.surface, 20, 20, 80, 30, 0,
                    hover ? 0xFF804020 : 0xFF208040, 0, 0);
  sui_surface_text(p.surface, 25, 20, 70, 30, "Hover", "Segoe UI", 14, 400, 0,
                   0xFFFFFFFF);
  sui_button_update(p.surface, p.button, 0, "", 0, 0, clip_width, 30);
  sui_surface_end(p.surface);
}
void Event(void *context, int64_t, int event) {
  auto &p = *static_cast<Probe *>(context);
  if (event == 1 || event == 2) {
    ++p.result.hover_events;
    Frame(p, event == 1);
  }
}
struct Capture {
  HDC dc;
  HBITMAP bitmap;
  HGDIOBJ old;
  Capture(HWND hwnd) {
    RECT rect;
    GetClientRect(hwnd, &rect);
    HDC screen = GetDC(hwnd);
    dc = CreateCompatibleDC(screen);
    bitmap = CreateCompatibleBitmap(screen, rect.right, rect.bottom);
    old = SelectObject(dc, bitmap);
    ReleaseDC(hwnd, screen);
    SendMessageW(hwnd, WM_PRINTCLIENT, reinterpret_cast<WPARAM>(dc),
                 PRF_CLIENT);
  }
  ~Capture() {
    SelectObject(dc, old);
    DeleteObject(bitmap);
    DeleteDC(dc);
  }
};
} // namespace
drawing_probe_result drawing_probe(void) {
  Probe p;
  p.host = CreateWindowExW(0, L"STATIC", L"SwiftUI drawing regression test",
                           WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT,
                           CW_USEDEFAULT, 420, 240, nullptr, nullptr,
                           GetModuleHandleW(nullptr), nullptr);
  p.result.dpi = int(GetDpiForWindow(p.host));
  p.result.aware =
      AreDpiAwarenessContextsEqual(GetWindowDpiAwarenessContext(p.host),
                                   DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  const double scale = p.result.dpi / 96.;
  auto px = [scale](double value) { return int(std::round(value * scale)); };
  p.surface = sui_surface_create(p.host, Event, &p, 0);
  p.button = CreateWindowExW(0, L"BUTTON", L"Hover",
                             WS_CHILD | WS_VISIBLE | WS_TABSTOP, px(20), px(20),
                             px(80), px(30), p.host, nullptr,
                             GetModuleHandleW(nullptr), nullptr);
  sui_surface_button(p.surface, p.button, 1, 1, 0);
  Frame(p, false);
  ShowWindow(p.host, SW_SHOWNOACTIVATE);
  UpdateWindow(p.host);
  UpdateWindow(p.button);
  ValidateRect(p.host, nullptr);
  ValidateRect(p.button, nullptr);
  SetWindowPos(p.host, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  const auto before_expose = sui_surface_total_paint_stats(p.surface).paints;
  RedrawWindow(p.host, nullptr, nullptr,
               RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
  if (sui_surface_total_paint_stats(p.surface).paints - before_expose != 1)
    ++p.result.expose_errors;
  // A styled control above a real native editor still needs its own paint:
  // the canvas deliberately leaves that editor's rectangle untouched.
  auto editor = sui_edit_create(p.surface, 9, 0, 0);
  SetWindowPos(static_cast<HWND>(editor), HWND_BOTTOM, px(20), px(20), px(80),
               px(30), SWP_NOACTIVATE);
  RedrawWindow(p.host, nullptr, nullptr,
               RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
  HDC visible = GetDC(p.host);
  if (GetPixel(visible, px(22), px(22)) != RGB(32, 128, 64))
    ++p.result.expose_errors;
  ReleaseDC(p.host, visible);
  sui_edit_destroy(p.surface, editor);
  SetWindowSubclass(p.button, Observe, 1, reinterpret_cast<DWORD_PTR>(&p));
  p.track = true;
  for (int i = 0; i < 20; ++i) {
    SendMessageW(p.button, WM_MOUSEMOVE, 0, MAKELPARAM(px(5), px(5)));
    SendMessageW(p.button, WM_MOUSELEAVE, 0, 0);
  }
  p.track = false;
  RECT damaged{}, surface{};
  GetUpdateRect(p.host, &damaged, FALSE);
  GetClientRect(p.host, &surface);
  p.result.damage_pixels =
      (damaged.right - damaged.left) * (damaged.bottom - damaged.top);
  p.result.surface_pixels = surface.right * surface.bottom;
  sui_surface_begin(p.surface);
  sui_surface_shape(p.surface, 0, 0, 1000, 1000, 0, 0xFFFF0000, 0, 0);
  {
    Capture previous(p.host);
    if (GetPixel(previous.dc, px(5), px(5)) != RGB(16, 32, 48))
      ++p.result.atomic_errors;
  }
  sui_surface_end(p.surface);
  {
    Capture published(p.host);
    if (GetPixel(published.dc, px(5), px(5)) != RGB(255, 0, 0))
      ++p.result.atomic_errors;
  }
  Frame(p, false);
  {
    Capture parent(p.host), child(p.button);
    // Exact colour boundaries must occur at logical coordinates * DPI scale.
    // This catches both bitmap virtualization and DrawImage's implicit scaling.
    for (int x = px(5); x < px(120); ++x) {
      const auto expected =
          x >= px(20) && x < px(100) ? RGB(32, 128, 64) : RGB(16, 32, 48);
      if (GetPixel(parent.dc, x, px(22)) != expected)
        ++p.result.pixel_errors;
    }
    for (int y = 0; y < px(30); ++y)
      for (int x = 0; x < px(80); ++x)
        if (GetPixel(child.dc, x, y) !=
            GetPixel(parent.dc, x + px(20), y + px(20)))
          ++p.result.child_pixel_errors;
  }
  Frame(p, false, 40);
  HRGN region = CreateRectRgn(0, 0, 0, 0);
  GetWindowRgn(p.button, region);
  if (!PtInRegion(region, px(10), px(10)) || PtInRegion(region, px(60), px(10)))
    ++p.result.clip_errors;
  Frame(p, false);
  GetWindowRgn(p.button, region);
  if (!PtInRegion(region, px(60), px(10)))
    ++p.result.clip_errors;
  DeleteObject(region);
  auto clippedFrame = [&](bool extra) {
    sui_surface_begin(p.surface);
    sui_surface_shape(p.surface, 0, 0, 1000, 1000, 0, 0xFF102030, 0, 0);
    sui_surface_clip(p.surface, 120, 80, 80, 40, 0);
    sui_surface_shape(p.surface, 100, 80, 140, 40, 0,
                      extra ? 0xFF804020 : 0xFF208040, 0, 0);
    if (extra)
      sui_surface_shape(p.surface, 130, 90, 20, 20, 0, 0xFFFFFFFF, 0, 0);
    sui_surface_restore(p.surface);
    sui_surface_end(p.surface);
  };
  clippedFrame(false);
  {
    Capture initial(p.host);
  }
  ValidateRect(p.host, nullptr);
  clippedFrame(true);
  RECT changed;
  GetUpdateRect(p.host, &changed, FALSE);
  if (changed.left < px(120) || changed.top < px(80) ||
      changed.right > px(200) || changed.bottom > px(120) ||
      IsRectEmpty(&changed))
    ++p.result.scope_errors;
  {
    Capture updated(p.host);
    if (GetPixel(updated.dc, px(125), px(85)) != RGB(128, 64, 32) ||
        GetPixel(updated.dc, px(140), px(100)) != RGB(255, 255, 255) ||
        GetPixel(updated.dc, px(110), px(85)) != RGB(16, 32, 48))
      ++p.result.scope_errors;
  }
  clippedFrame(false);
  {
    Capture removed(p.host);
    if (GetPixel(removed.dc, px(140), px(100)) != RGB(32, 128, 64))
      ++p.result.scope_errors;
  }
  const auto hover_positions = p.result.position_changes;
  p.track = true;
  sui_surface_begin(p.surface);
  sui_control_frame(p.surface, p.button, 30, 30, 80, 30);
  if (p.result.position_changes != hover_positions)
    ++p.result.scope_errors;
  sui_surface_end(p.surface);
  p.track = false;
  // Native layout must only queue damage; publication performs the paint.
  if (p.result.position_changes != hover_positions + 1)
    ++p.result.scope_errors;
  p.result.position_changes = hover_positions;
  HWND outside = CreateWindowExW(0, L"BUTTON", L"Outside",
                                 WS_CHILD | WS_VISIBLE | WS_TABSTOP, px(210),
                                 px(140), px(40), px(20), p.host, nullptr,
                                 GetModuleHandleW(nullptr), nullptr);
  sui_surface_button(p.surface, outside, 2, 1, 0);
  SetWindowSubclass(p.host, Observe, 2, reinterpret_cast<DWORD_PTR>(&p));
  auto grouped = [&](int outer, int inner) {
    sui_surface_begin(p.surface);
    sui_surface_shape(p.surface, 0, 0, 1000, 1000, 0, 0xFF102030, 0, 0);
    sui_surface_shape(p.surface, 30, 30 - outer - inner, 80, 30, 0, 0xFF208040,
                      0, 0);
    sui_controls_begin(p.surface);
    sui_controls_push(p.surface, 100, 10, 10 - outer, 250, 600, 10, 10, 250,
                      120);
    sui_controls_push(p.surface, 101, 20, 20 - outer - inner, 200, 400, 20,
                      20 - outer, 200, 90);
    sui_control_frame(p.surface, p.button, 30, 30 - outer - inner, 80, 30);
    sui_button_update(p.surface, p.button, 0, "", 0, 0, 80, 30);
    sui_controls_pop(p.surface);
    sui_controls_pop(p.surface);
    sui_control_frame(p.surface, outside, 210, 140, 40, 20);
    sui_button_update(p.surface, outside, 0, "", 0, 0, 40, 20);
    sui_surface_end(p.surface);
  };
  grouped(0, 0);
  const auto grouped_parent = GetParent(p.button);
  for (int i = 0; i < 12; ++i) {
    const int outer = i % 3 * 4, inner = i % 2 * 2;
    const auto positions = p.result.position_changes;
    p.track = true;
    grouped(outer, inner);
    p.track = false;
    // Parent translations must not issue position updates to each descendant.
    if (p.result.position_changes != positions ||
        GetParent(p.button) != grouped_parent)
      ++p.result.group_errors;
    RECT actual;
    GetWindowRect(p.button, &actual);
    MapWindowPoints(nullptr, p.host, reinterpret_cast<POINT *>(&actual), 2);
    if (actual.left != px(30) || actual.top != px(30 - outer - inner))
      ++p.result.group_errors;
    Capture parent(p.host), child(p.button);
    if (GetPixel(child.dc, px(5), px(5)) != RGB(32, 128, 64) ||
        GetPixel(parent.dc, px(35), px(35 - outer - inner)) != RGB(32, 128, 64))
      ++p.result.group_errors;
  }
  grouped(0, 0);
  sui_surface_focus_next(p.surface, nullptr, 0);
  if (GetFocus() != p.button)
    ++p.result.group_errors;
  sui_surface_focus_next(p.surface, p.button, 0);
  if (GetFocus() != outside)
    ++p.result.group_errors;
  sui_surface_focus_next(p.surface, outside, 1);
  if (GetFocus() != p.button)
    ++p.result.group_errors;
  sui_control_tab_visible(p.surface, p.button, 0);
  sui_surface_focus_next(p.surface, outside, 0);
  if (GetFocus() != outside)
    ++p.result.group_errors;
  sui_control_tab_visible(p.surface, p.button, 1);
  sui_button_activate(p.button);
  if (p.clicks != 1)
    ++p.result.group_errors;
  auto fractional = [&](double offset) {
    sui_surface_begin(p.surface);
    sui_surface_shape(p.surface, 0, 0, 1000, 1000, 0, 0xFF102030, 0, 0);
    sui_controls_push(p.surface, 100, 0, -offset, 250, 600, 0, 0, 250, 120);
    sui_control_frame(p.surface, p.button, 20, 0.5 / scale - offset, 80, 30);
    sui_button_update(p.surface, p.button, 0, "", 0, 0, 80, 30);
    sui_controls_pop(p.surface);
    sui_surface_end(p.surface);
  };
  fractional(0);
  const auto fractional_positions = p.result.position_changes;
  p.track = true;
  const double offsets[] = {48., 96., 48., 0., 48., 0.};
  for (double offset : offsets)
    fractional(offset);
  p.track = false;
  if (p.result.position_changes != fractional_positions)
    ++p.result.group_errors;
  RemoveWindowSubclass(p.host, Observe, 2);
  p.result.position_changes = hover_positions;
  RemoveWindowSubclass(p.button, Observe, 1);
  sui_surface_destroy(p.surface);
  DestroyWindow(p.host);
  return p.result;
}
