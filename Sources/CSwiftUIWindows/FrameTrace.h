#pragma once

#include <windows.h>
#include <cstdint>
#include <fstream>
#include <filesystem>
#include <string>
#include <vector>

// Opt-in diagnostics for the normal application's message loop. Records are
// buffered until shutdown; tracing never pumps, schedules or synthesizes input.
struct FrameTrace {
  struct Record {
    int kind, detail;
    int64_t start, end;
    uint64_t frame, input, tag, window;
    uint32_t queued_ms;
  };
  std::wstring path;
  std::vector<Record> records;
  uint64_t frame = 0, input = 0;
  int64_t publication_start = 0, update_start = 0;
  bool overflow = false, finished = false;
  HDC marker_dc = nullptr;
  HBITMAP marker_bitmap = nullptr;
  HGDIOBJ old_bitmap = nullptr;
  uint32_t *marker_pixels = nullptr;

  static int64_t Now() {
    LARGE_INTEGER time;
    QueryPerformanceCounter(&time);
    return time.QuadPart;
  }
  FrameTrace() {
    wchar_t value[32768];
    const auto length = GetEnvironmentVariableW(L"SWIFTUI_PORT_TRACE_PATH", value, 32768);
    if (length && length < 32768) {
      path.assign(value, length);
      records.reserve(200000);
    }
  }
  ~FrameTrace() {
    Finish();
    if (marker_dc) SelectObject(marker_dc, old_bitmap);
    if (marker_bitmap) DeleteObject(marker_bitmap);
    if (marker_dc) DeleteDC(marker_dc);
  }
  bool Enabled() const { return !path.empty() && !finished; }
  void Add(int kind, int detail, int64_t start, HWND window = nullptr,
           uint64_t tag = 0, uint32_t queued_ms = 0) {
    if (!Enabled()) return;
    if (records.size() == 200000) { overflow = true; return; }
    records.push_back({kind, detail, start, Now(), frame, input, tag,
                       reinterpret_cast<uint64_t>(window), queued_ms});
  }
  struct Span {
    FrameTrace &trace;
    int kind, detail;
    HWND window;
    int64_t started;
    uint64_t tag = 0;
    uint32_t queued_ms = 0;
    Span(FrameTrace &trace, int kind, int detail, HWND window)
        : trace(trace), kind(kind), detail(detail), window(window),
          started(kind && trace.Enabled() ? Now() : 0) {
      if (started && kind == 1) {
        ++trace.input;
        tag = static_cast<uint64_t>(GetMessageExtraInfo());
        queued_ms = GetTickCount() - static_cast<DWORD>(GetMessageTime());
      }
    }
    ~Span() { if (started) trace.Add(kind, detail, started, window, tag, queued_ms); }
  };
  void Marker(HWND window) {
    if (!Enabled() || !frame) return;
    HDC dc = GetDC(window);
    if (!dc) return;
    if (!marker_dc) {
      marker_dc = CreateCompatibleDC(dc);
      BITMAPINFO info{};
      info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      info.bmiHeader.biWidth = 144;
      info.bmiHeader.biHeight = -8;
      info.bmiHeader.biPlanes = 1;
      info.bmiHeader.biBitCount = 32;
      info.bmiHeader.biCompression = BI_RGB;
      marker_bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS,
                        reinterpret_cast<void **>(&marker_pixels), nullptr, 0);
      if (marker_bitmap) old_bitmap = SelectObject(marker_dc, marker_bitmap);
    }
    if (marker_pixels) {
      const uint64_t code = 0xA55A | ((frame & 0xffff) << 16) | ((~frame & 0xffff) << 32);
      for (int y = 0; y < 8; ++y)
        for (int x = 0; x < 144; ++x)
          marker_pixels[y * 144 + x] = (code & (uint64_t(1) << (x / 3))) ? 0xffffff : 0;
      RECT client{};
      GetClientRect(window, &client);
      BitBlt(dc, client.right * 30 / 100 + 8, client.bottom * 15 / 100 + 8,
             144, 8, marker_dc, 0, 0, SRCCOPY);
      GdiFlush();
    }
    ReleaseDC(window, dc);
  }
  void Finish() {
    if (!Enabled()) return;
    finished = true;
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    std::ofstream output{std::filesystem::path(path)};
    output << "frequency," << frequency.QuadPart << ",pid," << GetCurrentProcessId()
           << ",overflow," << overflow << '\n';
    output << "kind,detail,start_qpc,end_qpc,frame_id,input_id,tag,hwnd,queued_ms\n";
    for (const auto &r : records)
      output << r.kind << ',' << r.detail << ',' << r.start << ',' << r.end << ','
             << r.frame << ',' << r.input << ',' << r.tag << ',' << r.window << ','
             << r.queued_ms << '\n';
    output << "complete\n";
  }
};
