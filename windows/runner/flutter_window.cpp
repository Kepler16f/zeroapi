#include "flutter_window.h"

#include <optional>

#include <fstream>
#include <regex>
#include <string>

#include <windows.h>
#include <shlobj.h>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayMsg = WM_APP + 40;  // 托盘回调消息
constexpr UINT kTrayRestore = WM_APP + 41;
constexpr UINT kTrayQuit = WM_APP + 42;
constexpr UINT kTrayRestartGateway = WM_APP + 43;

std::wstring ConfigPath() {
  wchar_t buf[MAX_PATH] = {};
  if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, buf))) {
    return std::wstring(buf) + L"\\zeroapi\\config.json";
  }
  return L"";
}

// 窗口几何文件：runner 自用，和 Dart 写的 config.json 分开存放，
// 避免两个进程并发覆盖同一个文件。
std::wstring GeometryPath() {
  wchar_t buf[MAX_PATH] = {};
  if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, buf))) {
    std::wstring dir = std::wstring(buf) + L"\\zeroapi";
    ::CreateDirectoryW(dir.c_str(), nullptr);  // 已存在时返回 FALSE，忽略
    return dir + L"\\window.state";
  }
  return L"";
}

// 极简解析：config.json 是 Dart 写的 UTF-8 缩进 JSON（键与值均为 ASCII），
// 用宽字符路径打开（用户名可能含非 ASCII）、按字节读取内容后正则匹配
// closeToTray。不能用 wifstream 读内容——会把 UTF-8 当 UTF-16 读出乱码，
// false 永远匹配不到。
bool ParseCloseToTray(const std::wstring& wpath) {
  std::ifstream f(wpath.c_str(), std::ios::binary);
  if (!f) return true;  // 读不到按默认：收起到托盘
  std::string content((std::istreambuf_iterator<char>(f)),
                      std::istreambuf_iterator<char>());
  std::regex re("\"closeToTray\"\\s*:\\s*(true|false)");
  std::smatch m;
  if (std::regex_search(content, m, re) && m.size() == 2) {
    return m[1] == "true";
  }
  return true;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

// static
bool FlutterWindow::LoadSavedGeometry(SavedGeometry* out) {
  const auto path = GeometryPath();
  if (path.empty()) return false;
  std::ifstream f(path.c_str(), std::ios::binary);
  if (!f) return false;
  int x = 0;
  int y = 0;
  unsigned int w = 0;
  unsigned int h = 0;
  int maximized = 0;
  if (!(f >> x >> y >> w >> h >> maximized)) return false;
  // 合理性校验：太小或不在任何显示器上的记录直接丢弃，避免窗口跑到屏幕外
  if (w < 320 || h < 240) return false;
  RECT rect{x, y, x + static_cast<LONG>(w), y + static_cast<LONG>(h)};
  if (::MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) == nullptr) return false;
  out->x = x;
  out->y = y;
  out->width = w;
  out->height = h;
  out->maximized = maximized != 0;
  out->valid = true;
  return true;
}

void FlutterWindow::ApplySavedGeometry(const SavedGeometry& geometry) {
  if (!geometry.valid) return;
  // 用 SetWindowPlacement（GetWindowPlacement 的对偶）而不是裸 SetWindowPos：
  // 两者对 DPI 虚拟化的解释一致，避免位置在缩放显示器上发生漂移。
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  placement.showCmd = geometry.maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
  RECT rect{geometry.x, geometry.y,
            geometry.x + static_cast<LONG>(geometry.width),
            geometry.y + static_cast<LONG>(geometry.height)};
  // 防跑屏：把还原矩形钳进最近显示器的工作区
  HMONITOR monitor = ::MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  if (monitor != nullptr && ::GetMonitorInfoW(monitor, &info)) {
    const RECT& work = info.rcWork;
    const LONG maxW = work.right - work.left;
    const LONG maxH = work.bottom - work.top;
    LONG w = rect.right - rect.left;
    LONG h = rect.bottom - rect.top;
    if (w > maxW) w = maxW;
    if (h > maxH) h = maxH;
    LONG x = rect.left;
    LONG y = rect.top;
    if (x + w > work.right) x = work.right - w;
    if (y + h > work.bottom) y = work.bottom - h;
    if (x < work.left) x = work.left;
    if (y < work.top) y = work.top;
    rect = {x, y, x + w, y + h};
  }
  placement.rcNormalPosition = rect;
  ::SetWindowPlacement(GetHandle(), &placement);
  // 首帧 Show() 是 SW_SHOWNORMAL，会把最大化状态还原；记下标志等 Show 后补
  start_maximized_ = geometry.maximized;
}

void FlutterWindow::SaveGeometryNow() {
  const HWND hwnd = GetHandle();
  if (hwnd == nullptr || ::IsIconic(hwnd)) return;  // 最小化时尺寸不可用
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(WINDOWPLACEMENT);
  if (!::GetWindowPlacement(hwnd, &placement)) return;
  const RECT& r = placement.rcNormalPosition;
  const auto path = GeometryPath();
  if (path.empty()) return;
  std::ofstream f(path.c_str(), std::ios::binary | std::ios::trunc);
  if (!f) return;
  f << r.left << ' ' << r.top << ' ' << (r.right - r.left) << ' '
    << (r.bottom - r.top) << ' '
    << (placement.showCmd == SW_SHOWMAXIMIZED ? 1 : 0);
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 托盘菜单 → Dart：重启网关。C++ 只负责发起调用，实际重启由
  // GatewayService.restartServer() 完成。
  host_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "zeroapi/host",
          &flutter::StandardMethodCodec::GetInstance());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    if (start_maximized_) {
      ShowWindow(GetHandle(), SW_MAXIMIZE);
      start_maximized_ = false;
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  taskbar_created_ =
      RegisterWindowMessageW(L"TaskbarCreated");  // 资源管理器重启后重挂图标
  return true;
}

void FlutterWindow::OnDestroy() {
  SaveGeometryNow();
  RemoveTrayIcon();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::CloseToTrayEnabled() {
  const auto path = ConfigPath();
  if (path.empty()) return true;
  return ParseCloseToTray(path);
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_) return;
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = kTrayIconId;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayMsg;
  tray_icon_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"ZeroApi（零汇）— 网关运行中");
  Shell_NotifyIconW(NIM_ADD, &tray_icon_);
  tray_icon_added_ = true;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) return;
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_icon_added_ = false;
}

void FlutterWindow::HideToTray() {
  AddTrayIcon();
  ShowWindow(GetHandle(), SW_HIDE);
  tray_active_ = true;
  if (!tray_hint_shown_) {
    tray_hint_shown_ = true;
    NOTIFYICONDATAW notify = tray_icon_;
    notify.uFlags = NIF_INFO;
    notify.dwInfoFlags = NIIF_INFO;
    wcscpy_s(notify.szInfoTitle, L"ZeroApi 已最小化到托盘");
    wcscpy_s(notify.szInfo, L"双击托盘图标恢复窗口；网关仍在运行。");
    Shell_NotifyIconW(NIM_MODIFY, &notify);
  }
}

void FlutterWindow::ShowFromTray() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
  tray_active_ = false;
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kTrayRestore, L"显示主窗口");
  AppendMenuW(menu, MF_STRING, kTrayRestartGateway, L"重启网关");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayQuit, L"退出 ZeroApi");
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(GetHandle());
  int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y,
                           0, GetHandle(), nullptr);
  DestroyMenu(menu);
  if (cmd == kTrayRestore) {
    ShowFromTray();
  } else if (cmd == kTrayRestartGateway) {
    if (host_channel_) {
      host_channel_->InvokeMethod("restartGateway",
                                  std::make_unique<flutter::EncodableValue>());
    }
  } else if (cmd == kTrayQuit) {
    quitting_ = true;
    RemoveTrayIcon();
    DestroyWindow(GetHandle());
  }
}

void FlutterWindow::OnTrayIconMessage(WPARAM wparam, LPARAM lparam) {
  if (wparam != kTrayIconId) return;
  switch (static_cast<UINT>(lparam)) {
    case WM_LBUTTONDBLCLK:
    case WM_LBUTTONUP:
      if (tray_active_) ShowFromTray();
      break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowTrayMenu();
      break;
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 托盘回调优先（不经过 flutter 视图消息处理）
  if (message == kTrayMsg) {
    OnTrayIconMessage(wparam, lparam);
    return 0;
  }
  if (taskbar_created_ != 0 && message == taskbar_created_ && tray_active_) {
    // 资源管理器重启：重挂托盘图标
    tray_icon_added_ = false;
    AddTrayIcon();
    return 0;
  }
  if (message == kRestoreFromSecondInstance) {
    // 再次点击桌面图标：从托盘或最小化恢复到前台
    if (tray_active_) {
      ShowFromTray();
    } else {
      ShowWindow(GetHandle(), SW_RESTORE);
      SetForegroundWindow(GetHandle());
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_EXITSIZEMOVE:
      // 用户拖拽/缩放结束：记下窗口位置与大小（最大化标志由
      // GetWindowPlacement 一并带出）
      SaveGeometryNow();
      break;
    case WM_CLOSE:
      // 设置"退出应用"或托盘菜单"退出"时正常销毁；
      // 否则默认收起到托盘，网关继续运行
      SaveGeometryNow();
      if (!quitting_ && CloseToTrayEnabled()) {
        HideToTray();
        return 0;
      }
      break;
    case WM_QUERYENDSESSION:
      // 系统关机/注销时不阻止退出
      return TRUE;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
