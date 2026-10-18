#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <windows.h>
#include <shellapi.h>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
// 另外负责关窗行为：按 config.json 的 closeToTray 决定收起到系统托盘还是退出。
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 每次 WM_CLOSE 现读 %APPDATA%\zeroapi\config.json 的 closeToTray，
  // 设置页切换即时生效，无需重启应用
  bool CloseToTrayEnabled();
  void HideToTray();
  void ShowFromTray();
  void AddTrayIcon();
  void RemoveTrayIcon();
  void OnTrayIconMessage(WPARAM wparam, LPARAM lparam);
  void ShowTrayMenu();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  NOTIFYICONDATAW tray_icon_ = {};
  bool tray_active_ = false;      // 当前处于隐藏到托盘状态
  bool tray_icon_added_ = false;  // 图标已挂到通知区域
  bool tray_hint_shown_ = false;
  bool quitting_ = false;      // 从托盘菜单"退出"发起，放行关闭→销毁
  UINT taskbar_created_ = 0;   // 资源管理器重启后需重加托盘图标
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
