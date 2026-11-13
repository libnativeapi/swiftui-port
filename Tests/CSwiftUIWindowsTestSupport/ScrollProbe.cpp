#include "DrawingProbe.h"
#include "SwiftUIWindows.h"
#include <vector>
#include <windows.h>

namespace {
void Event(void *, int64_t, int) {}
HWND Window() {
  return CreateWindowExW(0, L"STATIC", L"Scroll pixel regression",
                         WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 420,
                         240, nullptr, nullptr, GetModuleHandleW(nullptr),
                         nullptr);
}
void Frame(void *surface, double offset, int revision, int backdrop,
           bool overlay) {
  sui_surface_begin(surface);
  sui_surface_shape(surface, 0, 0, 1000, 1000, 0, 0xFF102030, 0, 0);
  if (backdrop == 1) {
    const uint32_t colors[]{0xFF102030, 0xFF906040};
    sui_surface_gradient(surface, 20, 20, 180, 100, 0, 0, 0, 1, colors, 2);
  }
  sui_surface_clip(surface, 20, 20, 180, 100, 0);
  sui_surface_scroll_begin(surface, 1, revision, 20, 20, 180, 100, 20,
                           20 - offset);
  for (int y = 0; y < 400; y += 20) {
    sui_surface_shape(surface, 30, 20 + y - offset, 120, 14, 3,
                      backdrop == 4 && y == 40 ? 0x80CC00CC
                      : backdrop == 2          ? 0x80CC00CC
                      : revision == 1          ? 0x80208040
                                               : 0x80804020,
                      0xFFFFFFFF, 1);
    sui_surface_text(surface, 40, 20 + y - offset, 100, 14, "Scroll text",
                     "Segoe UI", 10, 400, 0, 0xFFFFFFFF);
  }
  sui_surface_shape(surface, 194, 20 + offset / 4, 4, 20, 2, 0xFF999999, 0, 0);
  if (backdrop == 3)
    sui_surface_shape(surface, 50, 50, 10, 10, 0, 0xFFCC8844, 0, 0);
  sui_surface_scroll_end(surface);
  sui_surface_restore(surface);
  if (overlay)
    sui_surface_shape(surface, 40, 40, 20, 20, 0, 0xFFCC8844, 0, 0);
  sui_surface_end(surface);
}
std::vector<uint32_t> Pixels(HWND window) {
  RECT rect;
  GetClientRect(window, &rect);
  HDC screen = GetDC(window), dc = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, rect.right, rect.bottom);
  auto old = SelectObject(dc, bitmap);
  SendMessageW(window, WM_PRINTCLIENT, reinterpret_cast<WPARAM>(dc),
               PRF_CLIENT);
  GdiFlush();
  SelectObject(dc, old);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = rect.right;
  info.bmiHeader.biHeight = -rect.bottom;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  std::vector<uint32_t> pixels(rect.right * rect.bottom);
  GetDIBits(dc, bitmap, 0, rect.bottom, pixels.data(), &info, DIB_RGB_COLORS);
  DeleteObject(bitmap);
  DeleteDC(dc);
  ReleaseDC(window, screen);
  return pixels;
}
} // namespace
scroll_probe_result scroll_probe(void) {
  scroll_probe_result result{};
  HWND actual = Window(), expected = Window();
  auto surface = sui_surface_create(actual, Event, nullptr, 0);
  auto check = [&](double offset, int revision, int backdrop, bool overlay,
                   bool reuse) {
    Frame(surface, offset, revision, backdrop, overlay);
    const auto pixels = Pixels(actual);
    const bool copied = sui_surface_reused_pixels(surface) > 0;
    if (copied)
      ++result.copies;
    if (copied != reuse)
      ++result.fallback_errors;
    auto fresh = sui_surface_create(expected, Event, nullptr, 0);
    Frame(fresh, offset, revision, backdrop, overlay);
    if (pixels != Pixels(expected))
      ++result.pixel_errors;
    sui_surface_destroy(fresh);
  };
  check(0, 1, 0, false, false);
  for (double offset : {4., 8., 4., 0.})
    check(offset, 1, 0, false, true);
  check(4, 2, 0, false, false); // Content changed.
  check(8, 2, 2, false, false); // Changed paint with the same caller revision.
  check(4, 2, 2, false, true);
  check(0, 2, 3, false, false);
  check(4, 2, 3, false,
        false); // A stationary element inside the scroll content.
  check(0, 2, 1, false, false);
  check(4, 2, 1, false, false); // Nonuniform background.
  check(0, 2, 0, true, false);
  check(4, 2, 0, true, false); // Stationary overlay.
  check(0, 2, 0, false, false);
  check(48. / GetDpiForWindow(actual), 2, 0, false,
        false);                   // Half a physical pixel.
  check(160, 2, 0, false, false); // No overlapping pixels.
  check(0, 2, 0, false, false);
  Frame(surface, 4, 2, 0,
        false); // Reuse must refer to the last painted frame, not this pending
                // one.
  check(8, 2, 0, false, true);
  Frame(surface, 12, 2, 0, false);
  check(16, 3, 4, false, true); // Pending scroll plus local hover ink change.
  check(20, 3, 0, false, true); // Removing the hover repaints its old ink.
  sui_surface_destroy(surface);
  DestroyWindow(actual);
  DestroyWindow(expected);
  return result;
}
