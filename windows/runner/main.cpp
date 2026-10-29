#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 单实例：桌面图标被再次点击时不能再起第二个进程（会抢同一个网关端口）。
  // 已有实例则把它的窗口从托盘/最小化恢复到前台，然后直接退出本进程。
  // 用 Local\ 命名空间：同会话内互斥即可，且普通用户无需额外权限。
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"Local\\ZeroApiSingleInstance");
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"zeroapi");
    if (existing != nullptr) {
      ::PostMessageW(existing, FlutterWindow::kRestoreFromSecondInstance, 0, 0);
    }
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // 先读上次的窗口位置/大小，Create 之后立即应用（窗口在首帧前不可见，
  // 不会闪一下默认尺寸）
  FlutterWindow::SavedGeometry geometry;
  const bool has_geometry = FlutterWindow::LoadSavedGeometry(&geometry);
  if (!window.Create(L"zeroapi", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  if (has_geometry) window.ApplySavedGeometry(geometry);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
