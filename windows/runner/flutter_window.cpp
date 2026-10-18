#include "flutter_window.h"

#include <optional>

#include <fstream>
#include <regex>
#include <string>

#include <windows.h>
#include <shlobj.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayMsg = WM_APP + 40;  // 托盘回调消息
constexpr UINT kTrayRestore = WM_APP + 41;
constexpr UINT kTrayQuit = WM_APP + 42;

std::wstring ConfigPath() {
  wchar_t buf[MAX_PATH] = {};
  if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, buf))) {
    return std::wstring(buf) + L"\\zeroapi\\config.json";
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

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
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
    case WM_CLOSE:
      // 设置"退出应用"或托盘菜单"退出"时正常销毁；
      // 否则默认收起到托盘，网关继续运行
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
