#include "SwiftUIWindows.h"
#include <nativeapi.h>
#include <windows.h>

#include <algorithm>
#include <commctrl.h>
#include <windowsx.h>
using std::max;
using std::min;
#include <cmath>
#include <gdiplus.h>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "FrameTrace.h"

namespace {
using namespace Gdiplus;
constexpr UINT_PTR subclass_id = 0x53554950;
constexpr UINT deferred_input = WM_APP + 581;
struct Command {
  int kind = 0; // shape, text, clip, restore
  RectF rect;
  float radius = 0, stroke_width = 0, size = 14, weight = 400, line_spacing = 0;
  uint32_t fill = 0, stroke = 0;
  std::wstring text, family;
  std::vector<double> path;
  std::vector<uint32_t> colors;
  PointF start, end;
  size_t clip_end = 0;
  bool operator==(const Command &c) const {
    return kind == c.kind && rect.Equals(c.rect) && radius == c.radius &&
           stroke_width == c.stroke_width && size == c.size &&
           weight == c.weight && line_spacing == c.line_spacing &&
           fill == c.fill && stroke == c.stroke && text == c.text &&
           family == c.family && path == c.path && colors == c.colors &&
           start.X == c.start.X && start.Y == c.start.Y && end.X == c.end.X &&
           end.Y == c.end.Y;
  }
};
struct ButtonHook {
  int64_t id;
  bool custom_draw;
  bool hovered = false;
  std::wstring help;
  RECT clip{};
  int clip_width = -1, clip_height = -1, clip_radius = -1;
  bool tab_visible = true;
};
struct EditHook {
  int64_t id;
  HFONT font = nullptr;
  HBRUSH brush = nullptr;
  COLORREF foreground = 0, background = RGB(255, 255, 255);
  bool updating = false;
  std::wstring fontKey;
};
struct Framebuffer {
  UINT width, height;
  HDC dc = CreateCompatibleDC(nullptr);
  HBITMAP dib = nullptr;
  HGDIOBJ previous = nullptr;
  std::unique_ptr<Bitmap> bitmap;
  Framebuffer(UINT w, UINT h) : width(w), height(h) {
    void *pixels = nullptr;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = LONG(w);
    info.bmiHeader.biHeight = -LONG(h);
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    dib = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    previous = SelectObject(dc, dib);
    bitmap = std::make_unique<Bitmap>(w, h, INT(w * 4), PixelFormat32bppPARGB,
                                      static_cast<BYTE *>(pixels));
  }
  ~Framebuffer() {
    bitmap.reset();
    SelectObject(dc, previous);
    DeleteObject(dib);
    DeleteDC(dc);
  }
};
struct TextFont {
  FontFamily family;
  Font font;
  TextFont(const Command &c)
      : family(c.family.c_str()),
        font(family.GetLastStatus() == Ok ? &family
                                          : FontFamily::GenericSansSerif(),
             c.size, c.weight >= 600 ? FontStyleBold : FontStyleRegular,
             UnitPixel) {}
};
struct ControlContext {
  HWND parent;
  double origin_x, origin_y;
  int x, y;
};
struct ControlGroup {
  HWND viewport, window;
};
struct ScrollDrawing {
  int64_t id, revision;
  RectF viewport;
  double x, y;
  size_t begin, end = 0;
};
struct ScrollCopy {
  RECT destination{};
  int dx = 0, dy = 0;
  RECT repaint{};
};
struct Surface {
  HWND host;
  sui_event_callback callback;
  void *context;
  std::vector<Command> commands;
  std::vector<Command> pending;
  std::unique_ptr<Framebuffer> buffer;
  bool buffer_dirty = true;
  RECT damage{};
  UINT buffer_dpi = 0;
  std::vector<ControlContext> control_contexts;
  std::unordered_map<int64_t, ControlGroup> control_groups;
  std::unordered_set<int64_t> live_groups;
  std::vector<HWND> control_order, focus_order;
  bool controls_updated = false;
  std::unordered_map<HWND, ButtonHook> buttons;
  HWND tooltip = nullptr;
  sui_input_callback input = nullptr;
  std::unordered_map<HWND, EditHook> edits;
  std::unordered_map<std::wstring, std::unique_ptr<TextFont>> fonts;
  std::unordered_map<HWND, native_view_t> native_views;
  std::unordered_map<HWND, HWND> native_parents;
  bool updating_views = false;
  bool native_state_changed = true;
  std::vector<ScrollDrawing> scrolls, pending_scrolls;
  // The immutable frame actually present in the DIB while later publications
  // are waiting for WM_PAINT. Never copy pixels relative to an unpainted frame.
  std::vector<Command> painted_commands;
  std::vector<ScrollDrawing> painted_scrolls;
  std::vector<size_t> scroll_stack;
  ScrollCopy scroll_copy;
  int64_t reused_pixels = 0;
  sui_paint_stats paint_stats{};
  sui_paint_stats total_paint_stats{};
  double publish_times[6]{};
  bool host_clipped_children = false;
  FrameTrace trace;
};
double ClockMilliseconds() {
  static const double frequency = [] {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return double(f.QuadPart) / 1000.;
  }();
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  return now.QuadPart / frequency;
}
void InitializeGraphics() {
  static ULONG_PTR token = [] {
    ULONG_PTR result = 0;
    GdiplusStartupInput input;
    GdiplusStartup(&result, &input, nullptr);
    return result;
  }();
  (void)token;
}
std::wstring Wide(const char *text) {
  if (!text || !*text)
    return {};
  int count = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
  std::wstring result(count, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text, -1, result.data(), count);
  result.pop_back();
  return result;
}
void RoundedPath(GraphicsPath &path, RectF r, float radius) {
  float d = max(0.f, min(radius * 2, min(r.Width, r.Height)));
  if (d < 0.01f) {
    path.AddRectangle(r);
    return;
  }
  path.AddArc(r.X, r.Y, d, d, 180, 90);
  path.AddArc(r.GetRight() - d, r.Y, d, d, 270, 90);
  path.AddArc(r.GetRight() - d, r.GetBottom() - d, d, d, 0, 90);
  path.AddArc(r.X, r.GetBottom() - d, d, d, 90, 90);
  path.CloseFigure();
}
void DrawTextCommand(Surface *s, Graphics &g, const Command &c) {
  const auto key = c.family + L"\n" + std::to_wstring(c.size) + L":" +
                   (c.weight >= 600 ? L"bold" : L"regular");
  auto found = s->fonts.find(key);
  if (found == s->fonts.end()) {
    if (s->fonts.size() >= 256)
      s->fonts.clear();
    found = s->fonts.emplace(key, std::make_unique<TextFont>(c)).first;
  }
  auto &font = found->second->font;
  StringFormat format(StringFormat::GenericTypographic());
  format.SetFormatFlags(StringFormatFlagsNoWrap |
                        StringFormatFlagsMeasureTrailingSpaces);
  SolidBrush brush(Color(c.fill));
  // Explicit newlines and line spacing, without inventing a wrapping policy.
  const float line_height = font.GetHeight(&g);
  size_t start = 0;
  int lines = 1 + int(std::count(c.text.begin(), c.text.end(), L'\n'));
  float y = c.rect.Y + (c.rect.Height -
                        (line_height * lines + c.line_spacing * (lines - 1))) /
                           2;
  while (start <= c.text.size()) {
    auto end = c.text.find(L'\n', start);
    auto line =
        c.text.substr(start, end == std::wstring::npos ? end : end - start);
    g.DrawString(line.c_str(), int(line.size()), &font, PointF(c.rect.X, y),
                 &format, &brush);
    if (end == std::wstring::npos)
      break;
    start = end + 1;
    y += line_height + c.line_spacing;
  }
}
void VectorPath(GraphicsPath &path, const std::vector<double> &commands) {
  PointF current;
  for (size_t i = 0; i < commands.size();) {
    const int op = int(commands[i++]);
    if (op == 3) {
      path.CloseFigure();
      continue;
    }
    if (i + (op == 2 ? 6 : 2) > commands.size())
      break;
    PointF p{float(commands[i]), float(commands[i + 1])};
    i += 2;
    if (op == 0) {
      path.StartFigure();
      current = p;
    } else if (op == 1) {
      path.AddLine(current, p);
      current = p;
    } else if (op == 2) {
      PointF c2{float(commands[i]), float(commands[i + 1])},
          end{float(commands[i + 2]), float(commands[i + 3])};
      i += 4;
      path.AddBezier(current, p, c2, end);
      current = end;
    }
  }
}
// A Bezier curve is contained by the convex hull of its control points. These
// conservative bounds avoid allocating GDI+ paths merely to reject invisible
// ink.
RectF PathBounds(const std::vector<double> &commands) {
  double left = 0, top = 0, right = 0, bottom = 0;
  bool first = true;
  for (size_t i = 0; i < commands.size();) {
    const int op = int(commands[i++]);
    const size_t count = op == 3 ? 0 : op == 2 ? 6 : 2;
    if (i + count > commands.size())
      break;
    for (size_t end = i + count; i < end; i += 2) {
      const auto x = commands[i], y = commands[i + 1];
      if (first) {
        left = right = x;
        top = bottom = y;
        first = false;
      } else {
        left = min(left, x);
        top = min(top, y);
        right = max(right, x);
        bottom = max(bottom, y);
      }
    }
  }
  return RectF(float(left), float(top), float(right - left),
               float(bottom - top));
}
void RenderFrame(Surface *s) {
  RECT client;
  GetClientRect(s->host, &client);
  const auto dpi = GetDpiForWindow(s->host);
  const auto width = UINT(max(1L, client.right));
  const auto height = UINT(max(1L, client.bottom));
  const bool same_size =
      s->buffer && s->buffer->width == width && s->buffer->height == height;
  if (same_size && s->buffer_dpi == dpi && !s->buffer_dirty)
    return;
  FrameTrace::Span raster_trace(s->trace, 6, 0, s->host);
  const double started = ClockMilliseconds();
  if (!same_size)
    s->buffer = std::make_unique<Framebuffer>(width, height);
  const bool full = !same_size || s->buffer_dpi != dpi;
  s->buffer_dpi = dpi;
  s->buffer_dirty = false;
  RECT copied{};
  RECT repaint = s->scroll_copy.repaint;
  if (!full) {
    const auto &copy = s->scroll_copy;
    if (!IsRectEmpty(&copy.destination)) {
      const auto &r = copy.destination;
      GdiFlush();
      if (BitBlt(s->buffer->dc, r.left, r.top, r.right - r.left,
                 r.bottom - r.top, s->buffer->dc, r.left - copy.dx,
                 r.top - copy.dy, SRCCOPY)) {
        GdiFlush();
        copied = r;
        s->reused_pixels = int64_t(r.right - r.left) * (r.bottom - r.top);
      }
    }
  }
  s->scroll_copy = {};
  // Complete GDI access before opening GDI+ over the same DIB storage.
  Graphics g(s->buffer->bitmap.get());
  if (!full) {
    Region dirty(Rect(s->damage.left, s->damage.top,
                      s->damage.right - s->damage.left,
                      s->damage.bottom - s->damage.top));
    if (!IsRectEmpty(&copied))
      dirty.Exclude(Rect(copied.left, copied.top, copied.right - copied.left,
                         copied.bottom - copied.top));
    if (!IsRectEmpty(&repaint))
      dirty.Union(Rect(repaint.left, repaint.top, repaint.right - repaint.left,
                       repaint.bottom - repaint.top));
    g.SetClip(&dirty);
  }
  SolidBrush clear(Color(255, 255, 255, 255));
  g.FillRectangle(&clear, 0, 0, INT(width), INT(height));
  s->damage = {};
  g.SetSmoothingMode(SmoothingModeAntiAlias);
  g.SetPixelOffsetMode(PixelOffsetModeHalf);
  g.SetTextRenderingHint(TextRenderingHintClearTypeGridFit);
  float scale = dpi / 96.f;
  g.ScaleTransform(scale, scale);
  std::vector<GraphicsState> clips;
  for (size_t i = 0; i < s->commands.size(); ++i) {
    const auto &c = s->commands[i];
    if ((c.kind == 2 || c.kind == 5) && c.clip_end > i) {
      auto bounds = c.rect;
      bounds.Inflate(1, 1);
      if (!g.IsVisible(bounds)) {
        i = c.clip_end;
        continue;
      }
    }
    if (c.kind == 3) {
      if (!clips.empty()) {
        g.Restore(clips.back());
        clips.pop_back();
      }
    } else if (c.kind == 4 || c.kind == 5) {
      auto bounds = c.rect;
      bounds.Inflate(1 + c.stroke_width / 2, 1 + c.stroke_width / 2);
      if (c.kind == 4 && !g.IsVisible(bounds))
        continue;
      GraphicsPath path;
      VectorPath(path, c.path);
      if (c.kind == 5) {
        clips.push_back(g.Save());
        g.SetClip(&path, CombineModeIntersect);
      } else {
        if (c.fill >> 24) {
          SolidBrush brush(Color(c.fill));
          g.FillPath(&brush, &path);
        }
        if (c.stroke_width > 0 && c.stroke >> 24) {
          Pen pen(Color(c.stroke), c.stroke_width);
          g.DrawPath(&pen, &path);
        }
      }
    } else if (c.kind == 6) {
      clips.push_back(g.Save());
      g.TranslateTransform(c.rect.X, c.rect.Y);
      g.RotateTransform(c.radius);
      g.ScaleTransform(c.size, c.weight);
      g.TranslateTransform(-c.rect.X, -c.rect.Y);
    } else if (c.kind == 7 && c.colors.size() >= 2) {
      if (!g.IsVisible(c.rect))
        continue;
      LinearGradientBrush brush(c.start, c.end, Color(c.colors.front()),
                                Color(c.colors.back()));
      std::vector<Color> colors;
      std::vector<REAL> stops;
      for (size_t i = 0; i < c.colors.size(); ++i) {
        colors.emplace_back(c.colors[i]);
        stops.push_back(REAL(i) / REAL(c.colors.size() - 1));
      }
      brush.SetInterpolationColors(colors.data(), stops.data(),
                                   int(colors.size()));
      g.FillRectangle(&brush, c.rect);
    } else if (c.kind == 9) {
      clips.push_back(g.Save());
      g.TranslateTransform(c.rect.X, c.rect.Y);
    } else if (c.kind == 8) {
      if (!g.IsVisible(c.rect))
        continue;
      Image bitmap(c.text.c_str());
      g.DrawImage(&bitmap, c.rect);
    } else if (c.kind == 2) {
      clips.push_back(g.Save());
      GraphicsPath path;
      RoundedPath(path, c.rect, c.radius);
      g.SetClip(&path, CombineModeIntersect);
    } else if (c.rect.Width > 0 && c.rect.Height > 0 && g.IsVisible(c.rect)) {
      if (c.kind == 1) {
        DrawTextCommand(s, g, c);
        continue;
      }
      GraphicsPath fill;
      RoundedPath(fill, c.rect, c.radius);
      if (c.fill >> 24) {
        SolidBrush brush(Color(c.fill));
        g.FillPath(&brush, &fill);
      }
      if (c.stroke_width > 0 && c.stroke >> 24) {
        auto r = c.rect;
        r.Inflate(-c.stroke_width / 2, -c.stroke_width / 2);
        if (r.Width > 0 && r.Height > 0) {
          GraphicsPath edge;
          RoundedPath(edge, r, max(0.f, c.radius - c.stroke_width / 2));
          Pen pen(Color(c.stroke), c.stroke_width);
          g.DrawPath(&pen, &edge);
        }
      }
    }
  }
  const double elapsed = ClockMilliseconds() - started;
  s->paint_stats.raster_ms += elapsed;
  s->total_paint_stats.raster_ms += elapsed;
  raster_trace.tag = uint64_t(s->reused_pixels);
  s->painted_commands.clear();
  s->painted_scrolls.clear();
}
void Draw(Surface *s, HWND target, HDC dc) {
  RenderFrame(s);
  FrameTrace::Span blit_trace(s->trace, 7, target == s->host, target);
  const double started = ClockMilliseconds();
  ++s->paint_stats.paints;
  ++s->total_paint_stats.paints;
  RECT client;
  GetClientRect(target, &client);
  POINT offset = {0, 0};
  MapWindowPoints(target, s->host, &offset, 1);
  // The framebuffer is already opaque and in physical pixels. BitBlt avoids
  // re-locking/converting the full GDI+ image for every child HWND's paint.
  RECT clip;
  if (GetClipBox(dc, &clip) == NULLREGION)
    return;
  const int saved = SaveDC(dc);
  if (target == s->host) {
    // Styled controls are input/accessibility HWNDs over this shared canvas.
    // Preserve native EDIT and unstyled BUTTON pixels; layered edits compose
    // themselves over the canvas and must retain its background underneath.
    auto exclude = [&](HWND hwnd) {
      if (!IsWindowVisible(hwnd) ||
          (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_LAYERED))
        return;
      RECT r;
      GetWindowRect(hwnd, &r);
      MapWindowPoints(nullptr, s->host, reinterpret_cast<POINT *>(&r), 2);
      ExcludeClipRect(dc, r.left, r.top, r.right, r.bottom);
    };
    for (const auto &entry : s->edits)
      exclude(entry.first);
    for (const auto &entry : s->buttons)
      if (!entry.second.custom_draw)
        exclude(entry.first);
  }
  IntersectRect(&client, &client, &clip);
  RECT source{-offset.x, -offset.y, LONG(s->buffer->width) - offset.x,
              LONG(s->buffer->height) - offset.y};
  IntersectRect(&client, &client, &source);
  if (!IsRectEmpty(&client))
    BitBlt(dc, client.left, client.top, client.right - client.left,
           client.bottom - client.top, s->buffer->dc, client.left + offset.x,
           client.top + offset.y, SRCCOPY);
  RestoreDC(dc, saved);
  const double elapsed = ClockMilliseconds() - started;
  s->paint_stats.blit_ms += elapsed;
  s->total_paint_stats.blit_ms += elapsed;
}
LRESULT Paint(Surface *s, HWND hwnd, UINT msg, WPARAM wp) {
  if (msg == WM_ERASEBKGND)
    return 1;
  if (msg == WM_PRINTCLIENT) {
    Draw(s, hwnd, reinterpret_cast<HDC>(wp));
    return 0;
  }
  PAINTSTRUCT ps;
  FrameTrace::Span traced(s->trace, 4, hwnd == s->host ? 1 : 0, hwnd);
  HDC dc = BeginPaint(hwnd, &ps);
  Draw(s, hwnd, dc);
  if (hwnd == s->host) {
    RECT clip{}, client{};
    GetClientRect(hwnd, &client);
    // An OS-wide expose/theme repaint can invalidate every input HWND after
    // publication. A full canvas paint already covered these styled buttons;
    // acknowledge that damage instead of copying the same pixels per control.
    // Partial/complex paints and overlaps with native widgets remain separate.
    if (GetClipBox(dc, &clip) == SIMPLEREGION && EqualRect(&clip, &client)) {
      std::vector<RECT> native;
      auto bounds = [&](HWND child) {
        RECT r{};
        GetWindowRect(child, &r);
        MapWindowPoints(nullptr, s->host, reinterpret_cast<POINT *>(&r), 2);
        return r;
      };
      for (const auto &entry : s->edits)
        if (IsWindowVisible(entry.first)) native.push_back(bounds(entry.first));
      for (const auto &entry : s->buttons)
        if (!entry.second.custom_draw && IsWindowVisible(entry.first))
          native.push_back(bounds(entry.first));
      for (const auto &entry : s->buttons) {
        if (!entry.second.custom_draw) continue;
        const auto r = bounds(entry.first);
        RECT covered{};
        if (!IntersectRect(&covered, &r, &clip) || !EqualRect(&covered, &r)) continue;
        bool overlap = false;
        for (const auto &area : native) {
          RECT intersection{};
          overlap |= IntersectRect(&intersection, &r, &area) != FALSE;
        }
        if (!overlap) ValidateRect(entry.first, nullptr);
      }
    }
  }
  EndPaint(hwnd, &ps);
  if (hwnd == s->host) {
    FrameTrace::Span marker_trace(s->trace, 8, 0, hwnd);
    s->trace.Marker(hwnd);
  }
  return 0;
}
int Modifiers() {
  return ((GetKeyState(VK_SHIFT) & 0x8000) ? 1 : 0) |
         ((GetKeyState(VK_CONTROL) & 0x8000) ? 2 : 0) |
         ((GetKeyState(VK_MENU) & 0x8000) ? 4 : 0) |
         (((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) ? 8 : 0);
}
int Input(Surface *s, HWND hwnd, int64_t id, UINT msg, WPARAM wp, LPARAM lp) {
  if (!s->input)
    return 0;
  int event = 0, value = 0;
  POINT point = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
  switch (msg) {
  case WM_MOUSEMOVE:
    event = 1;
    break;
  case WM_LBUTTONDOWN:
    event = 2;
    break;
  case WM_LBUTTONUP:
    event = 3;
    break;
  case WM_LBUTTONDBLCLK:
    event = 4;
    break;
  case WM_MOUSEHWHEEL:
  case WM_MOUSEWHEEL:
    event = 5;
    value = GET_WHEEL_DELTA_WPARAM(wp);
    ScreenToClient(hwnd, &point);
    break;
  case WM_KEYDOWN:
  case WM_SYSKEYDOWN:
    event = 6;
    value = int(wp);
    point = {0, 0};
    break;
  case WM_RBUTTONDOWN:
    event = 9;
    break;
  case WM_MOUSELEAVE:
    event = 10;
    break;
  }
  if (!event)
    return 0;
  if (event != 6)
    MapWindowPoints(hwnd, s->host, &point, 1);
  double scale = GetDpiForWindow(s->host) / 96.;
  return s->input(s->context, id, event, point.x / scale, point.y / scale,
                  msg == WM_MOUSEHWHEEL ? -value : value,
                  Modifiers() | (msg == WM_MOUSEHWHEEL ? 1 : 0));
}
LRESULT CALLBACK EditProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR,
                          DWORD_PTR data) {
  auto *s = reinterpret_cast<Surface *>(data);
  auto found = s->edits.find(hwnd);
  if (found == s->edits.end())
    return DefSubclassProc(hwnd, msg, wp, lp);
  auto id = found->second.id;
  if (msg == WM_KEYDOWN && wp == VK_TAB) {
    sui_surface_focus_next(s, hwnd, (Modifiers() & 1) != 0);
    return 0;
  }
  if (msg == WM_SETFOCUS || msg == WM_KILLFOCUS)
    s->callback(s->context, id, msg == WM_SETFOCUS ? 5 : 6);
  if ((msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN || msg == WM_MOUSEWHEEL) &&
      Input(s, hwnd, id, msg, wp, lp))
    return 0;
  return DefSubclassProc(hwnd, msg, wp, lp);
}
LRESULT CALLBACK HostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR,
                          DWORD_PTR data) {
  auto *s = reinterpret_cast<Surface *>(data);
  FrameTrace::Span traced(s->trace,
      msg == WM_MOUSEMOVE || msg == WM_MOUSEWHEEL || msg == WM_MOUSEHWHEEL ? 1 :
      msg == deferred_input ? 2 : msg == WM_TIMER ? 5 : 0, int(msg), hwnd);
  if (msg == WM_NCDESTROY && hwnd == s->host) s->trace.Finish();
  // NativeAPI observes notifications on its content HWND. Scroll grouping is
  // an implementation detail and must not interrupt BUTTON/EDIT notifications.
  if (hwnd != s->host && msg == WM_COMMAND)
    return SendMessageW(s->host, msg, wp, lp);
  if (msg == WM_DPICHANGED || msg == WM_DPICHANGED_AFTERPARENT) {
    // NativeAPI first applies the suggested bounds. Logical dimensions may
    // stay identical, but retained control frames still need the new DPI.
    const auto result = DefSubclassProc(hwnd, msg, wp, lp);
    if (hwnd == s->host && s->input)
      s->input(s->context, 0, 12, 0, 0, 0, 0);
    return result;
  }
  if (msg == deferred_input) {
    if (s->input)
      s->input(s->context, static_cast<int64_t>(wp), wp ? 7 : 11, 0, 0, 0, 0);
    return 0;
  }
  if (msg == WM_PAINT || msg == WM_PRINTCLIENT || msg == WM_ERASEBKGND)
    return Paint(s, hwnd, msg, wp);
  if (msg == WM_TIMER &&
      wp == subclass_id) { // NativeAPI owns GetMessage; Swift's main queue must
                           // also be serviced.
    using Pump = void (*)(void *);
    static auto pump = reinterpret_cast<Pump>(
        GetProcAddress(GetModuleHandleW(L"dispatch.dll"),
                       "_dispatch_main_queue_callback_4CF"));
    if (pump)
      pump(nullptr);
    if (s->input)
      s->input(s->context, 0, 8, 0, 0, 0, 0);
    return 0;
  }
  if (msg == WM_DRAWITEM && lp) {
    auto *item = reinterpret_cast<DRAWITEMSTRUCT *>(lp);
    auto found = s->buttons.find(item->hwndItem);
    if (found != s->buttons.end() && found->second.custom_draw) {
      Draw(s, item->hwndItem, item->hDC);
      return TRUE;
    }
  }
  if (msg == WM_COMMAND && HIWORD(wp) == EN_CHANGE) {
    auto found = s->edits.find(reinterpret_cast<HWND>(lp));
    if (found != s->edits.end() && !found->second.updating)
      PostMessageW(s->host, deferred_input,
                   static_cast<WPARAM>(found->second.id), 0);
  }

  if (msg == WM_CTLCOLOREDIT || msg == WM_CTLCOLORSTATIC) {
    auto found = s->edits.find(reinterpret_cast<HWND>(lp));
    if (found != s->edits.end()) {
      SetTextColor(reinterpret_cast<HDC>(wp), found->second.foreground);
      SetBkColor(reinterpret_cast<HDC>(wp), found->second.background);
      return reinterpret_cast<LRESULT>(found->second.brush);
    }
  }
  if (msg == WM_LBUTTONDOWN) {
    SetCapture(hwnd);
    SetFocus(hwnd);
  }
  if (msg == WM_LBUTTONUP && GetCapture() == hwnd)
    ReleaseCapture();
  if (msg == WM_MOUSEMOVE) {
    TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, hwnd, 0};
    TrackMouseEvent(&track);
  }
  if (Input(s, hwnd, 0, msg, wp, lp))
    return 0;
  if (msg == WM_KEYDOWN && wp == VK_TAB) {
    sui_surface_focus_next(s, nullptr, (GetKeyState(VK_SHIFT) & 0x8000) != 0);
    return 0;
  }
  return DefSubclassProc(hwnd, msg, wp, lp);
}
LRESULT CALLBACK ButtonProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR,
                            DWORD_PTR data) {
  auto *s = reinterpret_cast<Surface *>(data);
  FrameTrace::Span traced(s->trace,
      msg == WM_MOUSEMOVE || msg == WM_MOUSEWHEEL || msg == WM_MOUSEHWHEEL ? 1 : 0,
      int(msg), hwnd);
  auto found = s->buttons.find(hwnd);
  if (found == s->buttons.end())
    return DefSubclassProc(hwnd, msg, wp, lp);
  // Scrolling only moves the clipping parent with redraw suppressed. Native
  // button state changes can still schedule their own paint, which the next
  // canvas publication must absorb. Do not scan every HWND on every scroll.
  switch (msg) {
  case WM_MOUSEMOVE:
  case WM_MOUSELEAVE:
  case BM_SETSTATE:
  case WM_SETFOCUS:
  case WM_KILLFOCUS:
  case WM_SETTEXT:
  case WM_SETFONT:
  case WM_ENABLE:
  case WM_STYLECHANGED:
  case WM_WINDOWPOSCHANGED:
    s->native_state_changed = true;
    break;
  }
  const int64_t id = found->second.id;
  if ((msg == WM_MOUSEWHEEL || msg == WM_MOUSEHWHEEL || msg == WM_RBUTTONDOWN ||
       msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) &&
      Input(s, hwnd, id, msg, wp, lp))
    return 0;
  if (found->second.custom_draw &&
      (msg == WM_PAINT || msg == WM_PRINTCLIENT || msg == WM_ERASEBKGND))
    return Paint(s, hwnd, msg, wp);
  if (msg == WM_KEYDOWN && wp == VK_TAB) {
    sui_surface_focus_next(s, hwnd, (GetKeyState(VK_SHIFT) & 0x8000) != 0);
    return 0;
  }
  if (msg == WM_KEYDOWN && wp == VK_RETURN && !(lp & (1L << 30))) {
    sui_button_activate(hwnd);
    return 0;
  }
  int event = 0;
  if (msg == WM_MOUSEMOVE && !found->second.hovered) {
    found->second.hovered = true;
    TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, hwnd, 0};
    TrackMouseEvent(&track);
    event = 1;
  } else if (msg == WM_MOUSELEAVE && found->second.hovered) {
    found->second.hovered = false;
    event = 2;
  } else if (msg == BM_SETSTATE)
    event = wp ? 3 : 4;
  else if (msg == WM_SETFOCUS)
    event = 5;
  else if (msg == WM_KILLFOCUS)
    event = 6;
  // Capture, keyboard activation, focus and BN_CLICKED remain the BUTTON's.
  if (event)
    s->callback(s->context, id, event);
  return DefSubclassProc(hwnd, msg, wp, lp);
}
Command Box(int kind, double x, double y, double w, double h, double radius) {
  Command c;
  c.kind = kind;
  c.rect = RectF(float(x), float(y), float(w), float(h));
  c.radius = float(std::isfinite(radius) ? radius : min(w, h) / 2);
  return c;
}
void OrderControl(Surface *s, HWND hwnd) {
  if (!s->controls_updated)
    sui_controls_begin(s);
  s->control_order.push_back(hwnd);
  if (s->buttons.count(hwnd) || s->edits.count(hwnd))
    s->focus_order.push_back(hwnd);
}
ControlContext CurrentControls(Surface *s) {
  return s->control_contexts.empty() ? ControlContext{s->host, 0, 0, 0, 0}
                                     : s->control_contexts.back();
}
int ControlPixel(double value, double scale) {
  return int(std::floor(value * scale + 0.5 + 1e-8));
}
ControlContext ChildControls(Surface *s, HWND parent, double x, double y,
                             double scale) {
  const auto ancestor = CurrentControls(s);
  return {parent, x, y, ancestor.x + ControlPixel(x - ancestor.origin_x, scale),
          ancestor.y + ControlPixel(y - ancestor.origin_y, scale)};
}
native_view_t NativeView(Surface *s, HWND hwnd) {
  auto found = s->native_views.find(hwnd);
  if (found != s->native_views.end())
    return found->second;
  auto view = native_view_create_with_native_view(hwnd);
  // An existing native control already has explicit geometry. Preserve it
  // when enrolling the borrowed view in NativeAPI's absolute layout tree.
  native_view_set_frame(view, native_view_get_frame(view));
  s->native_views.emplace(hwnd, view);
  return view;
}
void ReleaseControl(Surface *s, HWND hwnd) {
  auto found = s->native_views.find(hwnd);
  if (found == s->native_views.end())
    return;
  auto parent = s->native_parents.find(hwnd);
  if (parent != s->native_parents.end()) {
    auto host = s->native_views.find(parent->second);
    if (host != s->native_views.end())
      native_view_remove_subview(host->second, found->second);
    s->native_parents.erase(parent);
  }
  native_view_free(found->second);
  s->native_views.erase(found);
}
void DestroyControlGroup(Surface *s, const ControlGroup &group) {
  RemoveWindowSubclass(group.window, HostProc, subclass_id);
  RemoveWindowSubclass(group.viewport, HostProc, subclass_id);
  ReleaseControl(s, group.window);
  ReleaseControl(s, group.viewport);
  DestroyWindow(group.window);
  DestroyWindow(group.viewport);
}
void ParentControl(Surface *s, HWND hwnd) {
  const auto context = CurrentControls(s);
  if (s->native_parents[hwnd] != context.parent ||
      GetParent(hwnd) != context.parent) {
    native_view_add_subview(NativeView(s, context.parent), NativeView(s, hwnd));
    s->native_parents[hwnd] = context.parent;
  }
}
void ApplyRegion(HWND hwnd, HRGN region) {
  HRGN old = CreateRectRgn(0, 0, 0, 0);
  const bool equal = GetWindowRgn(hwnd, old) != ERROR && EqualRgn(old, region);
  DeleteObject(old);
  // Changing even an identical region sends WM_WINDOWPOSCHANGED, and redraws
  // the control synchronously. Hover must not move/repaint the other controls.
  if (equal || !SetWindowRgn(hwnd, region, FALSE))
    DeleteObject(region);
}
RectF InkBounds(const Command &c) {
  auto bounds = c.rect;
  if (c.kind == 4)
    bounds.Inflate(c.stroke_width / 2, c.stroke_width / 2);
  return bounds;
}
bool SavesGraphics(int kind) {
  return kind == 2 || kind == 5 || kind == 6 || kind == 9;
}
bool Contains(RectF outer, RectF inner) {
  return outer.X <= inner.X && outer.Y <= inner.Y &&
         outer.GetRight() >= inner.GetRight() &&
         outer.GetBottom() >= inner.GetBottom();
}
bool Near(double a, double b) { return std::abs(a - b) < 0.0001; }
bool Translates(const Command &a, const Command &b, double dx, double dy,
                bool allow_color_change = false) {
  if (a.kind != b.kind || !Near(a.rect.X + dx, b.rect.X) ||
      !Near(a.rect.Y + dy, b.rect.Y) || !Near(a.rect.Width, b.rect.Width) ||
      !Near(a.rect.Height, b.rect.Height) || a.radius != b.radius ||
      a.stroke_width != b.stroke_width || a.size != b.size ||
      a.weight != b.weight || a.line_spacing != b.line_spacing ||
      (!allow_color_change && (a.fill != b.fill || a.stroke != b.stroke)) ||
      a.text != b.text || a.family != b.family || a.colors != b.colors ||
      a.path.size() != b.path.size())
    return false;
  if (a.kind == 7 &&
      (!Near(a.start.X + dx, b.start.X) || !Near(a.start.Y + dy, b.start.Y) ||
       !Near(a.end.X + dx, b.end.X) || !Near(a.end.Y + dy, b.end.Y)))
    return false;
  for (size_t i = 0; i < a.path.size();) {
    if (a.path[i] != b.path[i])
      return false;
    const int op = int(a.path[i++]);
    const size_t count = op == 3 ? 0 : op == 2 ? 6 : 2;
    if (i + count > a.path.size())
      return false;
    for (const size_t end = i + count; i < end; i += 2)
      if (!Near(a.path[i] + dx, b.path[i]) ||
          !Near(a.path[i + 1] + dy, b.path[i + 1]))
        return false;
  }
  return true;
}
struct InkIterator {
  const std::vector<Command> &commands;
  size_t position, end;
  double dx, dy;
  RectF area;
  std::vector<const Command *> clips;
  bool valid = true;
  const Command *next() {
    while (position < end) {
      const auto &c = commands[position++];
      if (c.kind == 6 || c.kind == 9) {
        valid = false;
        return nullptr;
      }
      if (c.kind == 2 || c.kind == 5) {
        clips.push_back(&c);
        continue;
      }
      if (c.kind == 3) {
        if (clips.empty()) {
          valid = false;
          return nullptr;
        }
        clips.pop_back();
        continue;
      }
      if ((c.kind == 0 || c.kind == 4) && !(c.fill >> 24) && !(c.stroke >> 24))
        continue;
      auto ink = InkBounds(c);
      ink.Inflate(2, 2);
      for (const auto *clip : clips)
        ink.Intersect(clip->rect);
      ink.Offset(float(dx), float(dy));
      if (ink.IntersectsWith(area)) {
        // External bitmap files can change without changing their command.
        if (c.kind == 8) {
          valid = false;
          return nullptr;
        }
        return &c;
      }
    }
    return nullptr;
  }
};
bool ScrollInkTranslates(Surface *s, const std::vector<Command> &commands,
                         const ScrollDrawing &a, const ScrollDrawing &b,
                         RECT destination, int dx, int dy, double scale,
                         RECT &repaint) {
  RectF area(float(destination.left / scale), float(destination.top / scale),
             float((destination.right - destination.left) / scale),
             float((destination.bottom - destination.top) / scale));
  InkIterator before{commands, a.begin, a.end, dx / scale, dy / scale, area};
  InkIterator after{s->pending, b.begin, b.end, 0, 0, area};
  for (;;) {
    const auto *old = before.next(), *next = after.next();
    if (!before.valid || !after.valid)
      return false;
    if (!old || !next)
      return old == next;
    if (!Translates(*old, *next, dx / scale, dy / scale, true) ||
        before.clips.size() != after.clips.size())
      return false;
    if (old->fill != next->fill || old->stroke != next->stroke) {
      auto ink = InkBounds(*next);
      ink.Inflate(2, 2);
      RECT changed{LONG(std::floor(ink.X * scale)),
                   LONG(std::floor(ink.Y * scale)),
                   LONG(std::ceil(ink.GetRight() * scale)),
                   LONG(std::ceil(ink.GetBottom() * scale))};
      IntersectRect(&changed, &changed, &destination);
      UnionRect(&repaint, &repaint, &changed);
    }
    for (size_t i = 0; i < before.clips.size(); ++i)
      if (!Translates(*before.clips[i], *after.clips[i], dx / scale,
                      dy / scale))
        return false;
  }
}
// Pixel translation is only safe over a uniform opaque backdrop, with no
// stationary overlay intersecting the viewport. Anything uncertain repaints.
bool ScrollBackdrop(Surface *s, const ScrollDrawing &scroll, RectF copy_area) {
  RECT client;
  GetClientRect(s->host, &client);
  const float scale = GetDpiForWindow(s->host) / 96.f;
  struct Scope {
    RectF clip;
    bool complex = false;
  };
  std::vector<Scope> scopes{
      {RectF(0, 0, client.right / scale, client.bottom / scale)}};
  bool flat = true; // The framebuffer's initial clear is solid white.
  for (size_t i = 0; i < s->pending.size(); ++i) {
    if (i == scroll.begin) {
      if (scopes.back().complex || !Contains(scopes.back().clip, copy_area)) {
        return false;
      }
      i = scroll.end - 1;
      continue;
    }
    const auto &c = s->pending[i];
    if (c.kind == 6 || c.kind == 9)
      return false;
    if (c.kind == 2 || c.kind == 5) {
      auto scope = scopes.back();
      scope.clip.Intersect(c.rect);
      scope.complex |= c.kind == 5 || c.radius != 0;
      scopes.push_back(scope);
      continue;
    }
    if (c.kind == 3) {
      if (scopes.size() > 1)
        scopes.pop_back();
      continue;
    }
    if (c.kind == 0 && !(c.fill >> 24) && !(c.stroke >> 24))
      continue;
    auto ink = InkBounds(c);
    ink.Inflate(2, 2);
    ink.Intersect(scopes.back().clip);
    if (!ink.IntersectsWith(copy_area))
      continue;
    if (i >= scroll.end) {
      return false;
    }
    flat = !scopes.back().complex && c.kind == 0 && c.radius == 0 &&
           (c.fill >> 24) == 255 && c.stroke_width == 0 &&
           Contains(c.rect, copy_area) &&
           Contains(scopes.back().clip, copy_area);
  }
  return flat;
}
ScrollCopy PrepareScrollCopy(Surface *s) {
  RECT client;
  GetClientRect(s->host, &client);
  const auto dpi = GetDpiForWindow(s->host);
  if (!s->buffer || s->buffer_dpi != dpi ||
      s->buffer->width != UINT(client.right) ||
      s->buffer->height != UINT(client.bottom))
    return {};
  const double scale = dpi / 96.;
  const auto &commands = s->buffer_dirty ? s->painted_commands : s->commands;
  const auto &scrolls = s->buffer_dirty ? s->painted_scrolls : s->scrolls;
  for (const auto &b : s->pending_scrolls) {
    for (const auto &a : scrolls) {
      if (a.id != b.id || !a.viewport.Equals(b.viewport) ||
          a.begin != b.begin || a.end <= a.begin || b.end <= b.begin ||
          commands.size() - a.end != s->pending.size() - b.end)
        continue;
      const double x = (b.x - a.x) * scale, y = (b.y - a.y) * scale;
      const int dx = int(std::round(x)), dy = int(std::round(y));
      if ((!dx && !dy) || std::abs(x - dx) > 0.001 || std::abs(y - dy) > 0.001)
        continue;
      // Repaint stationary borders/overhang on every edge and reserve both
      // potential scroll-indicator strips. Only the interior can be copied.
      RECT area{LONG(std::ceil((b.viewport.X + 4) * scale)),
                LONG(std::ceil((b.viewport.Y + 4) * scale)),
                LONG(std::floor((b.viewport.GetRight() - 8) * scale)),
                LONG(std::floor((b.viewport.GetBottom() - 8) * scale))};
      IntersectRect(&area, &area, &client);
      const RectF copy_area(float(area.left / scale), float(area.top / scale),
                            float((area.right - area.left) / scale),
                            float((area.bottom - area.top) / scale));
      const bool outside =
          std::equal(commands.begin(), commands.begin() + a.begin,
                     s->pending.begin()) &&
          std::equal(commands.begin() + a.end, commands.end(),
                     s->pending.begin() + b.end);
      const bool backdrop = ScrollBackdrop(s, b, copy_area);
      if (!outside || !backdrop)
        continue;
      RECT shifted = area, destination;
      OffsetRect(&shifted, dx, dy);
      if (!IntersectRect(&destination, &area, &shifted))
        continue;
      RECT repaint{};
      const bool ink = ScrollInkTranslates(s, commands, a, b, destination, dx,
                                           dy, scale, repaint);
      if (!ink)
        continue;
      // A broad theme/content change is cheaper to redraw. Small hover color
      // changes repaint their ink over the translated, last-painted pixels.
      if (int64_t(repaint.right - repaint.left) *
              (repaint.bottom - repaint.top) >
          int64_t(destination.right - destination.left) *
              (destination.bottom - destination.top) / 2)
        continue;
      return {destination, dx, dy, repaint};
    }
  }
  return {};
}
// When culling changes the command count, retain the common enclosing clip.
// A scroll viewport stays fixed even though its visible descendants change.
RECT ChangedScope(Surface *s, RECT client) {
  const auto &a = s->commands, &b = s->pending;
  size_t prefix = 0, suffix = 0;
  while (prefix < min(a.size(), b.size()) && a[prefix] == b[prefix])
    ++prefix;
  while (suffix < min(a.size(), b.size()) - prefix &&
         a[a.size() - suffix - 1] == b[b.size() - suffix - 1])
    ++suffix;
  struct Scope {
    RECT clip;
    bool transformed;
  };
  std::vector<Scope> scopes{{client, false}};
  const double scale = GetDpiForWindow(s->host) / 96.;
  for (size_t i = 0; i < prefix; ++i) {
    const auto &c = a[i];
    if (SavesGraphics(c.kind)) {
      auto next = scopes.back();
      if ((c.kind == 2 || c.kind == 5) && !next.transformed) {
        const auto r = InkBounds(c);
        RECT clip{LONG(std::floor(r.X * scale)), LONG(std::floor(r.Y * scale)),
                  LONG(std::ceil(r.GetRight() * scale)),
                  LONG(std::ceil(r.GetBottom() * scale))};
        IntersectRect(&next.clip, &next.clip, &clip);
      }
      next.transformed |= c.kind == 6 || c.kind == 9;
      scopes.push_back(next);
    } else if (c.kind == 3 && scopes.size() > 1) {
      scopes.pop_back();
    }
  }
  size_t enclosing = scopes.size() - 1;
  for (const auto *commands : {&a, &b}) {
    size_t depth = scopes.size() - 1;
    for (size_t i = prefix; i < commands->size() - suffix; ++i) {
      const auto kind = (*commands)[i].kind;
      if (SavesGraphics(kind))
        ++depth;
      else if (kind == 3 && depth > 0)
        --depth;
      enclosing = min(enclosing, depth);
    }
  }
  return scopes[enclosing].clip;
}
RECT Damage(Surface *s) {
  RECT client;
  GetClientRect(s->host, &client);
  if (!s->buffer)
    return client;
  if (s->commands.size() != s->pending.size())
    return ChangedScope(s, client);
  RECT damage{};
  const double scale = GetDpiForWindow(s->host) / 96.;
  std::vector<bool> transforms;
  int transformed = 0;
  for (size_t i = 0; i < s->commands.size(); ++i) {
    const auto &a = s->commands[i], &b = s->pending[i];
    if (!(a == b)) {
      if (a.kind != b.kind || transformed || a.kind == 2 || a.kind == 3 ||
          a.kind == 5 || a.kind == 6 || a.kind == 9)
        return ChangedScope(s, client);
      if (!(a.kind == 0 && !(a.fill >> 24) && !(a.stroke >> 24) &&
            !(b.fill >> 24) && !(b.stroke >> 24))) {
        for (const auto *c : {&a, &b}) {
          auto r = InkBounds(*c);
          // Include antialiasing and text overhang at the edge of a node.
          r.Inflate(2 + c->stroke_width, 2 + c->stroke_width);
          RECT pixels{LONG(std::floor(r.X * scale)),
                      LONG(std::floor(r.Y * scale)),
                      LONG(std::ceil(r.GetRight() * scale)),
                      LONG(std::ceil(r.GetBottom() * scale))};
          UnionRect(&damage, &damage, &pixels);
        }
      }
    }
    if (b.kind == 2 || b.kind == 5 || b.kind == 6 || b.kind == 9) {
      bool transform = b.kind == 6 || b.kind == 9;
      transforms.push_back(transform);
      transformed += transform;
    } else if (b.kind == 3 && !transforms.empty()) {
      transformed -= transforms.back();
      transforms.pop_back();
    }
  }
  IntersectRect(&damage, &damage, &client);
  return damage;
}
} // namespace
extern "C" {
void sui_prepare_application(void) {
  // Must precede Application initialization, which can create hidden HWNDs.
  // An embedding host with an existing manifest/context remains in charge.
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}
void *sui_surface_create(void *host, sui_event_callback callback, void *context,
                         uint64_t native_view) {
  InitializeGraphics();
  auto *s = new Surface{static_cast<HWND>(host), callback, context};
  if (!SetWindowSubclass(s->host, HostProc, subclass_id,
                         reinterpret_cast<DWORD_PTR>(s))) {
    delete s;
    return nullptr;
  }
  if (native_view)
    s->native_views.emplace(s->host, native_handle_retain(native_view));
  const auto style = GetWindowLongPtrW(s->host, GWL_STYLE);
  s->host_clipped_children = (style & WS_CLIPCHILDREN) != 0;
  SetWindowLongPtrW(s->host, GWL_STYLE, style & ~WS_CLIPCHILDREN);
  s->tooltip = CreateWindowExW(
      WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_ALWAYSTIP,
      CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, s->host,
      nullptr, GetModuleHandleW(nullptr), nullptr);
  SetTimer(s->host, subclass_id, 16, nullptr);
  return s;
}
void sui_surface_destroy(void *handle) {
  auto *s = static_cast<Surface *>(handle);
  KillTimer(s->host, subclass_id);
  while (!s->edits.empty())
    sui_edit_destroy(s, s->edits.begin()->first);
  for (const auto &entry : s->buttons)
    RemoveWindowSubclass(entry.first, ButtonProc, subclass_id);
  for (const auto &entry : s->buttons)
    ReleaseControl(s, entry.first);
  for (const auto &entry : s->control_groups) {
    DestroyControlGroup(s, entry.second);
  }
  ReleaseControl(s, s->host);
  if (s->updating_views)
    native_view_end_updates(false);
  RemoveWindowSubclass(s->host, HostProc, subclass_id);
  if (s->host_clipped_children)
    SetWindowLongPtrW(s->host, GWL_STYLE,
                      GetWindowLongPtrW(s->host, GWL_STYLE) | WS_CLIPCHILDREN);
  if (s->tooltip)
    DestroyWindow(s->tooltip);
  delete s;
}
int sui_control_focused(void *control) {
  return GetFocus() == static_cast<HWND>(control);
}
void sui_surface_trace_duration(void *handle, int stage, double milliseconds) {
  auto *s = static_cast<Surface *>(handle);
  if (s->trace.Enabled())
    s->trace.Add(9, stage, FrameTrace::Now(), s->host,
                 uint64_t((std::max)(0.0, milliseconds) * 1000000));
}
void sui_surface_trace_update(void *handle, int begin) {
  auto *s = static_cast<Surface *>(handle);
  if (!s->trace.Enabled()) return;
  if (begin) s->trace.update_start = FrameTrace::Now();
  else s->trace.Add(2, 2, s->trace.update_start, s->host);
}
void sui_surface_schedule(void *handle) {
  PostMessageW(static_cast<Surface *>(handle)->host, deferred_input, 0, 0);
}
void sui_surface_flush(void *handle) {
  auto *s = static_cast<Surface *>(handle);
  MSG msg;
  while (PeekMessageW(&msg, s->host, deferred_input, deferred_input, PM_REMOVE))
    DispatchMessageW(&msg);
}
void sui_surface_input(void *handle, sui_input_callback callback) {
  static_cast<Surface *>(handle)->input = callback;
}
void *sui_edit_create(void *handle, int64_t id, int multiline, int secure) {
  auto *s = static_cast<Surface *>(handle);
  DWORD style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_CLIPSIBLINGS |
                (multiline ? (ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN)
                           : ES_AUTOHSCROLL) |
                (secure ? ES_PASSWORD : 0);
  HWND edit = CreateWindowExW(0, L"EDIT", L"", style, 0, 0, 1, 1, s->host,
                              nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!edit)
    return nullptr;
  s->edits.emplace(edit, EditHook{id});
  SetWindowSubclass(edit, EditProc, subclass_id,
                    reinterpret_cast<DWORD_PTR>(s));
  SendMessageW(edit, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, 0);
  return edit;
}
int sui_edit_text(void *edit, char *output, int capacity) {
  HWND hwnd = static_cast<HWND>(edit);
  std::wstring text(GetWindowTextLengthW(hwnd) + 1, L'\0');
  GetWindowTextW(hwnd, text.data(), int(text.size()));
  int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0,
                                 nullptr, nullptr);
  if (output && capacity >= size)
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, output, capacity, nullptr,
                        nullptr);
  return size;
}
void sui_edit_update(void *handle, void *control, const char *text,
                     const char *placeholder, double x, double y, double w,
                     double h, const char *family, double size, double weight,
                     uint32_t foreground, uint32_t background, int enabled,
                     int focus) {
  auto *s = static_cast<Surface *>(handle);
  HWND hwnd = static_cast<HWND>(control);
  auto &hook = s->edits.at(hwnd);
  hook.updating = true;
  auto value = Wide(text);
  std::wstring current(GetWindowTextLengthW(hwnd) + 1, L'\0');
  GetWindowTextW(hwnd, current.data(), int(current.size()));
  current.resize(wcslen(current.c_str()));
  if (value != current) {
    DWORD start = 0, end = 0;
    SendMessageW(hwnd, EM_GETSEL, reinterpret_cast<WPARAM>(&start),
                 reinterpret_cast<LPARAM>(&end));
    SetWindowTextW(hwnd, value.c_str());
    SendMessageW(hwnd, EM_SETSEL, min(start, DWORD(value.size())),
                 min(end, DWORD(value.size())));
  }
  auto cue = Wide(placeholder);
  SendMessageW(hwnd, EM_SETCUEBANNER, TRUE,
               reinterpret_cast<LPARAM>(cue.c_str()));
  double scale = GetDpiForWindow(s->host) / 96.;
  auto fontKey = Wide(family) + std::to_wstring(size * scale) + L":" +
                 std::to_wstring(weight);
  if (hook.fontKey != fontKey) {
    auto font = CreateFontW(
        -int(std::round(size * scale)), 0, 0, 0, int(weight), FALSE, FALSE,
        FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, Wide(family).c_str());
    SendMessageW(hwnd, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    if (hook.font)
      DeleteObject(hook.font);
    hook.font = font;
    hook.fontKey = fontKey;
  }
  auto rgb = [](uint32_t color) {
    return RGB((color >> 16) & 255, (color >> 8) & 255, color & 255);
  };
  const bool colors_changed =
      hook.foreground != rgb(foreground) || hook.background != rgb(background);
  hook.foreground = rgb(foreground);
  if (!hook.brush || hook.background != rgb(background)) {
    if (hook.brush)
      DeleteObject(hook.brush);
    hook.background = rgb(background);
    hook.brush = CreateSolidBrush(hook.background);
  }
  sui_control_frame(s, hwnd, x, y, w, h);
  OrderControl(s, hwnd);
  if (IsWindowEnabled(hwnd) != (enabled != 0))
    EnableWindow(hwnd, enabled);
  if (focus && enabled && GetFocus() != hwnd)
    SetFocus(hwnd);
  if (colors_changed)
    InvalidateRect(hwnd, nullptr, FALSE);
  hook.updating = false;
}
void sui_edit_destroy(void *handle, void *edit) {
  auto *s = static_cast<Surface *>(handle);
  HWND hwnd = static_cast<HWND>(edit);
  auto found = s->edits.find(hwnd);
  if (found == s->edits.end())
    return;
  auto hook = found->second;
  s->edits.erase(found);
  RemoveWindowSubclass(hwnd, EditProc, subclass_id);
  ReleaseControl(s, hwnd);
  DestroyWindow(hwnd);
  if (hook.font)
    DeleteObject(hook.font);
  if (hook.brush)
    DeleteObject(hook.brush);
}
void sui_control_clip(void *control, double x, double y, double w, double h) {
  HWND hwnd = static_cast<HWND>(control);
  double scale = GetDpiForWindow(hwnd) / 96.;
  const bool visible = w > 0 && h > 0;
  if (bool(IsWindowVisible(hwnd)) != visible)
    ShowWindow(hwnd, visible ? SW_SHOWNA : SW_HIDE);
  ApplyRegion(hwnd, CreateRectRgn(int(std::floor(x * scale)),
                                  int(std::floor(y * scale)),
                                  int(std::ceil((x + w) * scale)),
                                  int(std::ceil((y + h) * scale))));
}
void sui_control_opacity(void *control, double opacity) {
  auto hwnd = static_cast<HWND>(control);
  auto style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if (opacity < 1) {
    if (!(style & WS_EX_LAYERED))
      SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | WS_EX_LAYERED);
    SetLayeredWindowAttributes(hwnd, 0, BYTE(max(0., min(1., opacity)) * 255),
                               LWA_ALPHA);
  } else if (style & WS_EX_LAYERED)
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style & ~WS_EX_LAYERED);
}
void sui_control_focus(void *control) { SetFocus(static_cast<HWND>(control)); }
void sui_edit_replace_text(void *edit, const char *text) {
  SetWindowTextW(static_cast<HWND>(edit), Wide(text).c_str());
}
void sui_surface_pointer(void *handle, int event, double x, double y,
                         int value) {
  auto *s = static_cast<Surface *>(handle);
  double scale = GetDpiForWindow(s->host) / 96.;
  POINT point = {LONG(std::round(x * scale)), LONG(std::round(y * scale))};
  UINT msg = event == 2   ? WM_LBUTTONDOWN
             : event == 3 ? WM_LBUTTONUP
             : event == 5 ? WM_MOUSEWHEEL
             : event == 9 ? WM_RBUTTONDOWN
                          : WM_MOUSEMOVE;
  WPARAM wp = (event == 1 || event == 2) ? MK_LBUTTON : 0;
  if (event == 5) {
    ClientToScreen(s->host, &point);
    wp = MAKEWPARAM(0, value);
  }
  SendMessageW(s->host, msg, wp, MAKELPARAM(point.x, point.y));
}
void sui_surface_begin(void *handle) {
  auto *s = static_cast<Surface *>(handle);
  if (s->trace.Enabled()) s->trace.publication_start = FrameTrace::Now();
  if (!s->updating_views) {
    native_view_begin_updates();
    s->updating_views = true;
  }
  s->pending.clear();
  s->pending_scrolls.clear();
  s->scroll_stack.clear();
  s->control_contexts.clear();
  s->live_groups.clear();
  s->control_order.clear();
  s->controls_updated = false;
}
void sui_surface_shape(void *h, double x, double y, double w, double height,
                       double radius, uint32_t fill, uint32_t stroke,
                       double width) {
  auto c = Box(0, x, y, w, height, radius);
  c.fill = fill;
  c.stroke = stroke;
  c.stroke_width = float(width);
  static_cast<Surface *>(h)->pending.push_back(std::move(c));
}
void sui_surface_text(void *h, double x, double y, double w, double height,
                      const char *text, const char *family, double size,
                      double weight, double line_spacing, uint32_t color) {
  auto c = Box(1, x, y, w, height, 0);
  c.text = Wide(text);
  c.family = Wide(family);
  c.size = float(size);
  c.weight = float(weight);
  c.fill = color;
  c.line_spacing = float(line_spacing);
  static_cast<Surface *>(h)->pending.push_back(std::move(c));
}
void sui_surface_path(void *h, const double *commands, int count, uint32_t fill,
                      uint32_t stroke, double width, int clip) {
  Command c;
  c.kind = clip ? 5 : 4;
  c.path.assign(commands, commands + count);
  c.rect = PathBounds(c.path);
  c.fill = fill;
  c.stroke = stroke;
  c.stroke_width = float(width);
  static_cast<Surface *>(h)->pending.push_back(std::move(c));
}
void sui_surface_translation(void *h, double x, double y) {
  Command c;
  c.kind = 9;
  c.rect = RectF(float(x), float(y), 0, 0);
  static_cast<Surface *>(h)->pending.push_back(std::move(c));
}
void sui_surface_transform(void *h, double cx, double cy, double rotation,
                           double sx, double sy) {
  Command c;
  c.kind = 6;
  c.rect = RectF(float(cx), float(cy), 0, 0);
  c.radius = float(rotation);
  c.size = float(sx);
  c.weight = float(sy);
  static_cast<Surface *>(h)->pending.push_back(std::move(c));
}
void sui_surface_gradient(void *h, double x, double y, double width,
                          double height, double sx, double sy, double ex,
                          double ey, const uint32_t *colors, int count) {
  auto c = Box(7, x, y, width, height, 0);
  c.start = PointF(float(x + sx * width), float(y + sy * height));
  c.end = PointF(float(x + ex * width), float(y + ey * height));
  c.colors.assign(colors, colors + count);
  static_cast<Surface *>(h)->pending.push_back(std::move(c));
}
void sui_surface_image(void *h, const char *file, double x, double y,
                       double width, double height) {
  auto c = Box(8, x, y, width, height, 0);
  c.text = Wide(file);
  static_cast<Surface *>(h)->pending.push_back(std::move(c));
}
void sui_surface_clip(void *h, double x, double y, double w, double height,
                      double radius) {
  static_cast<Surface *>(h)->pending.push_back(Box(2, x, y, w, height, radius));
}
void sui_surface_restore(void *h) {
  Command c;
  c.kind = 3;
  static_cast<Surface *>(h)->pending.push_back(c);
}
void sui_surface_end(void *h) {
  auto *s = static_cast<Surface *>(h);
  double started = ClockMilliseconds();
  auto checkpoint = [&](int stage) {
    auto now = ClockMilliseconds();
    s->publish_times[stage] = now - started;
    started = now;
  };
  s->scroll_copy = PrepareScrollCopy(s);
  checkpoint(0);
  s->reused_pixels = 0;
  s->paint_stats = {};
  // Animation-only publications have no control traversal. Keep their hosts.
  if (s->controls_updated) {
    for (auto it = s->control_groups.begin(); it != s->control_groups.end();) {
      if (s->live_groups.count(it->first)) {
        ++it;
        continue;
      }
      DestroyControlGroup(s, it->second);
      it = s->control_groups.erase(it);
    }
    // Later painted siblings are in front. Tab order is retained separately.
    std::unordered_map<HWND, HWND> previous;
    for (auto it = s->control_order.rbegin(); it != s->control_order.rend();
         ++it) {
      auto hwnd = *it;
      auto &above = previous[GetParent(hwnd)];
      if (GetWindow(hwnd, GW_HWNDPREV) != above)
        SetWindowPos(hwnd, above ? above : HWND_TOP, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOREDRAW);
      above = hwnd;
    }
  }
  checkpoint(1);
  std::vector<size_t> scopes;
  for (size_t i = 0; i < s->pending.size(); ++i) {
    auto &command = s->pending[i];
    if (SavesGraphics(command.kind))
      scopes.push_back(i);
    else if (command.kind == 3 && !scopes.empty()) {
      s->pending[scopes.back()].clip_end = i;
      scopes.pop_back();
    }
  }
  checkpoint(2);
  if (s->updating_views) {
    native_view_end_updates(false);
    s->updating_views = false;
  }
  checkpoint(3);
  RECT damage = Damage(s);
  if (s->trace.Enabled() && !IsRectEmpty(&damage)) ++s->trace.frame;
  checkpoint(4);
  UnionRect(&s->damage, &s->damage, &damage);
  if (!s->buffer_dirty) {
    s->painted_commands = std::move(s->commands);
    s->painted_scrolls = std::move(s->scrolls);
  }
  s->commands.swap(s->pending);
  s->scrolls.swap(s->pending_scrolls);
  if (!IsRectEmpty(&s->damage)) {
    s->buffer_dirty = true;
    std::vector<RECT> native_damage;
    auto native_area = [&](HWND hwnd) {
      if (!IsWindowVisible(hwnd) ||
          (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_LAYERED))
        return;
      RECT r;
      GetWindowRect(hwnd, &r);
      MapWindowPoints(nullptr, s->host, reinterpret_cast<POINT *>(&r), 2);
      if (IntersectRect(&r, &r, &s->damage))
        native_damage.push_back(r);
    };
    for (const auto &entry : s->edits)
      native_area(entry.first);
    for (const auto &entry : s->buttons)
      if (!entry.second.custom_draw)
        native_area(entry.first);
    // One canvas copy paints all styled controls. Independent native widgets
    // still receive their own damage; do not blit the same pixels per HWND.
    RECT exposed;
    if (GetUpdateRect(s->host, &exposed, FALSE))
      UnionRect(&s->damage, &s->damage, &exposed);
    if (s->native_state_changed) {
      RedrawWindow(s->host, nullptr, nullptr,
                   RDW_VALIDATE | RDW_NOERASE | RDW_NOFRAME | RDW_ALLCHILDREN);
      s->native_state_changed = false;
    }
    for (const auto &entry : s->buttons) {
      if (entry.second.custom_draw) {
        // A styled popup over an opaque native editor still needs its own
        // paint: the canvas deliberately excludes that editor's rectangle.
        if (!native_damage.empty()) {
          RECT r, overlap;
          GetWindowRect(entry.first, &r);
          MapWindowPoints(nullptr, s->host, reinterpret_cast<POINT *>(&r), 2);
          for (const auto &native : native_damage) {
            if (IntersectRect(&overlap, &r, &native)) {
              InvalidateRect(entry.first, nullptr, FALSE);
              break;
            }
          }
        }
      } else
        InvalidateRect(entry.first, nullptr, FALSE);
    }
    for (const auto &entry : s->edits) {
      RECT r;
      GetWindowRect(entry.first, &r);
      MapWindowPoints(nullptr, s->host, reinterpret_cast<POINT *>(&r), 2);
      if (IntersectRect(&r, &r, &s->damage))
        InvalidateRect(entry.first, nullptr, FALSE);
    }
    RedrawWindow(s->host, &s->damage, nullptr, RDW_INVALIDATE | RDW_NOCHILDREN);
  }
  checkpoint(5);
  s->trace.Add(3, !IsRectEmpty(&damage), s->trace.publication_start, s->host);
}
double sui_surface_publish_time(void *handle, int stage) {
  return stage >= 0 && stage < 6
             ? static_cast<Surface *>(handle)->publish_times[stage]
             : 0;
}
void sui_surface_scroll_begin(void *handle, int64_t id, int64_t revision,
                              double x, double y, double width, double height,
                              double content_x, double content_y) {
  auto *s = static_cast<Surface *>(handle);
  s->scroll_stack.push_back(s->pending_scrolls.size());
  s->pending_scrolls.push_back(
      {id, revision, RectF(float(x), float(y), float(width), float(height)),
       content_x, content_y, s->pending.size()});
}
void sui_surface_scroll_end(void *handle) {
  auto *s = static_cast<Surface *>(handle);
  if (s->scroll_stack.empty())
    return;
  s->pending_scrolls[s->scroll_stack.back()].end = s->pending.size();
  s->scroll_stack.pop_back();
}
int64_t sui_surface_reused_pixels(void *handle) {
  return static_cast<Surface *>(handle)->reused_pixels;
}
sui_paint_stats sui_surface_paint_stats(void *handle) {
  return static_cast<Surface *>(handle)->paint_stats;
}
sui_paint_stats sui_surface_total_paint_stats(void *handle) {
  return static_cast<Surface *>(handle)->total_paint_stats;
}
void sui_control_tab_visible(void *handle, void *control, int visible) {
  auto *s = static_cast<Surface *>(handle);
  auto found = s->buttons.find(static_cast<HWND>(control));
  if (found != s->buttons.end())
    found->second.tab_visible = visible != 0;
}
void sui_control_frame(void *handle, void *control, double x, double y,
                       double width, double height) {
  auto *s = static_cast<Surface *>(handle);
  HWND hwnd = static_cast<HWND>(control);
  ParentControl(s, hwnd);
  const auto context = CurrentControls(s);
  const double scale = GetDpiForWindow(s->host) / 96.;
  const auto view = NativeView(s, hwnd);
  // Read through NativeAPI so a frame queued earlier in this transaction is
  // visible here, even while the physical HWND still has its previous frame.
  const auto current = native_view_get_frame(view);
  RECT before{ControlPixel(current.x, scale), ControlPixel(current.y, scale),
               ControlPixel(current.x, scale) + ControlPixel(current.width, scale),
               ControlPixel(current.y, scale) + ControlPixel(current.height, scale)};
  // Subtract logical origins before snapping. Rounding world coordinates
  // independently makes stable child frames jump at negative half pixels.
  const double local_x = x - context.origin_x, local_y = y - context.origin_y;
  const int px = ControlPixel(local_x, scale);
  const int py = ControlPixel(local_y, scale);
  const int pw = max(0, ControlPixel(width, scale));
  const int ph = max(0, ControlPixel(height, scale));
  RECT after{px, py, px + pw, py + ph};
  if (EqualRect(&before, &after))
    return;
  // NativeAPI owns the control hierarchy, coalesced layout and deferred moves.
  native_view_set_frame(view, {local_x, local_y, width, height});
  RECT client, damage;
  GetClientRect(s->host, &client);
  UnionRect(&damage, &before, &after);
  OffsetRect(&damage, context.x, context.y);
  IntersectRect(&damage, &damage, &client);
  UnionRect(&s->damage, &s->damage, &damage);
}
void sui_controls_begin(void *handle) {
  auto *s = static_cast<Surface *>(handle);
  s->controls_updated = true;
  s->focus_order.clear();
}
void sui_controls_push(void *handle, int64_t id, double x, double y,
                       double width, double height, double clip_x,
                       double clip_y, double clip_width, double clip_height) {
  auto *s = static_cast<Surface *>(handle);
  s->live_groups.insert(id);
  auto found = s->control_groups.find(id);
  if (found == s->control_groups.end()) {
    auto create = [&](HWND parent) {
      auto hwnd = CreateWindowExW(
          WS_EX_CONTROLPARENT, L"STATIC", L"",
          WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | SS_NOTIFY, 0, 0, 1, 1,
          parent, nullptr, GetModuleHandleW(nullptr), nullptr);
      if (hwnd)
        SetWindowSubclass(hwnd, HostProc, subclass_id,
                          reinterpret_cast<DWORD_PTR>(s));
      return hwnd;
    };
    auto viewport = create(CurrentControls(s).parent);
    auto content = viewport ? create(viewport) : nullptr;
    if (!content) {
      if (viewport)
        DestroyWindow(viewport);
      s->control_contexts.push_back(CurrentControls(s));
      return;
    }
    found =
        s->control_groups.emplace(id, ControlGroup{viewport, content}).first;
  }
  auto &group = found->second;
  const double scale = GetDpiForWindow(s->host) / 96.;
  sui_control_frame(s, group.viewport, clip_x, clip_y, clip_width, clip_height);
  OrderControl(s, group.viewport);
  s->control_contexts.push_back(
      ChildControls(s, group.viewport, clip_x, clip_y, scale));
  // A fixed viewport clips a translated content HWND without changing HRGNs
  // on every tick (which makes Windows recalculate every child's visibility).
  auto damage = s->damage;
  sui_control_frame(s, group.window, x, y, width, height);
  if (!EqualRect(&damage, &s->damage)) {
    RECT viewport{int(std::floor(clip_x * scale)),
                  int(std::floor(clip_y * scale)),
                  int(std::ceil((clip_x + clip_width) * scale)),
                  int(std::ceil((clip_y + clip_height) * scale))};
    UnionRect(&s->damage, &damage, &viewport);
  }
  const auto content = ChildControls(s, group.window, x, y, scale);
  s->control_contexts.pop_back();
  s->control_contexts.push_back(content);
}
void sui_controls_pop(void *handle) {
  auto *s = static_cast<Surface *>(handle);
  if (!s->control_contexts.empty())
    s->control_contexts.pop_back();
}
void sui_surface_button(void *h, void *button, int64_t id, int custom_draw,
                        uint64_t native_view) {
  auto *s = static_cast<Surface *>(h);
  HWND hwnd = static_cast<HWND>(button);
  s->native_state_changed = true;
  if (native_view)
    s->native_views.emplace(hwnd, native_handle_retain(native_view));
  ParentControl(s, hwnd);
  SetWindowLongPtrW(hwnd, GWL_STYLE,
                    GetWindowLongPtrW(hwnd, GWL_STYLE) | WS_CLIPSIBLINGS);
  s->buttons.emplace(hwnd, ButtonHook{id, custom_draw != 0});
  if (custom_draw)
    SetWindowLongPtrW(hwnd, GWL_STYLE,
                      (GetWindowLongPtrW(hwnd, GWL_STYLE) & ~BS_TYPEMASK) |
                          BS_OWNERDRAW);
  SetWindowSubclass(hwnd, ButtonProc, subclass_id,
                    reinterpret_cast<DWORD_PTR>(s));
  TOOLINFOW tool = {sizeof(tool)};
  tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
  tool.hwnd = s->host;
  tool.uId = reinterpret_cast<UINT_PTR>(hwnd);
  tool.lpszText = const_cast<wchar_t *>(L"");
  if (s->tooltip)
    SendMessageW(s->tooltip, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
}
void sui_surface_remove_button(void *h, void *button) {
  auto *s = static_cast<Surface *>(h);
  HWND hwnd = static_cast<HWND>(button);
  RemoveWindowSubclass(hwnd, ButtonProc, subclass_id);
  TOOLINFOW tool = {sizeof(tool)};
  tool.hwnd = s->host;
  tool.uId = reinterpret_cast<UINT_PTR>(hwnd);
  if (s->tooltip)
    SendMessageW(s->tooltip, TTM_DELTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
  s->buttons.erase(hwnd);
  ReleaseControl(s, hwnd);
}
void sui_button_update(void *h, void *button, double radius, const char *help,
                       double x, double y, double w, double height) {
  auto *s = static_cast<Surface *>(h);
  HWND hwnd = static_cast<HWND>(button);
  ParentControl(s, hwnd);
  // Preserve declaration order without churning every HWND on a state update.
  OrderControl(s, hwnd);
  auto found = s->buttons.find(hwnd);
  if (found == s->buttons.end())
    return;
  auto &hook = found->second;
  RECT rect;
  GetClientRect(hwnd, &rect);
  const double limit = min(rect.right, rect.bottom) / 2.;
  const int r = int(
      std::ceil(std::isfinite(radius)
                    ? max(0., min(radius * GetDpiForWindow(hwnd) / 96., limit))
                    : limit));
  const double scale = GetDpiForWindow(hwnd) / 96.;
  RECT clipped{int(std::floor(x * scale)), int(std::floor(y * scale)),
               int(std::ceil((x + w) * scale)),
               int(std::ceil((y + height) * scale))};
  IntersectRect(&clipped, &clipped, &rect);
  // A translation does not change a fully visible control's local region.
  // Avoid allocating/querying HRGNs for every control on every scroll tick.
  if (hook.clip_width != rect.right || hook.clip_height != rect.bottom ||
      hook.clip_radius != r || !EqualRect(&hook.clip, &clipped)) {
    HRGN region = r ? CreateRoundRectRgn(0, 0, rect.right + 1, rect.bottom + 1,
                                         r * 2, r * 2)
                    : CreateRectRgn(0, 0, rect.right, rect.bottom);
    HRGN clip = CreateRectRgnIndirect(&clipped);
    CombineRgn(region, region, clip, RGN_AND);
    DeleteObject(clip);
    ApplyRegion(hwnd, region);
    hook.clip = clipped;
    hook.clip_width = rect.right;
    hook.clip_height = rect.bottom;
    hook.clip_radius = r;
  }
  auto text = Wide(help);
  if (text != hook.help) {
    hook.help = std::move(text);
    TOOLINFOW tool = {sizeof(tool)};
    tool.hwnd = s->host;
    tool.uId = reinterpret_cast<UINT_PTR>(hwnd);
    tool.lpszText = hook.help.data();
    if (s->tooltip)
      SendMessageW(s->tooltip, TTM_UPDATETIPTEXTW, 0,
                   reinterpret_cast<LPARAM>(&tool));
  }
}
void sui_surface_focus_next(void *h, void *current, int backward) {
  auto *s = static_cast<Surface *>(h);
  const auto count = int(s->focus_order.size());
  if (!count)
    return;
  auto found = std::find(s->focus_order.begin(), s->focus_order.end(),
                         static_cast<HWND>(current));
  int index = found == s->focus_order.end()
                  ? (backward ? 0 : -1)
                  : int(found - s->focus_order.begin());
  for (int i = 0; i < count; ++i) {
    index = (index + (backward ? count - 1 : 1)) % count;
    const auto hwnd = s->focus_order[index];
    const auto button = s->buttons.find(hwnd);
    if (button != s->buttons.end() && !button->second.tab_visible)
      continue;
    if (IsWindowVisible(hwnd) && IsWindowEnabled(hwnd)) {
      SetFocus(hwnd);
      return;
    }
  }
}
sui_size sui_measure_text(const char *text, const char *family_name,
                          double size, double weight) {
  InitializeGraphics();
  Bitmap bitmap(1, 1, PixelFormat32bppPARGB);
  Graphics g(&bitmap);
  g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
  auto text_w = Wide(text), family_w = Wide(family_name);
  FontFamily family(family_w.c_str());
  Font font(
      family.GetLastStatus() == Ok ? &family : FontFamily::GenericSansSerif(),
      float(size), weight >= 600 ? FontStyleBold : FontStyleRegular, UnitPixel);
  StringFormat format(StringFormat::GenericTypographic());
  format.SetFormatFlags(StringFormatFlagsNoWrap |
                        StringFormatFlagsMeasureTrailingSpaces);
  RectF measured;
  g.MeasureString(text_w.empty() ? L" " : text_w.c_str(), -1, &font,
                  PointF(0, 0), &format, &measured);
  return {text_w.empty() ? 0 : std::ceil(measured.Width),
          std::ceil(measured.Height)};
}
void sui_button_activate(void *button) {
  HWND hwnd = static_cast<HWND>(button);
  if (IsWindowEnabled(hwnd))
    SendMessageW(hwnd, BM_CLICK, 0, 0);
}
}
