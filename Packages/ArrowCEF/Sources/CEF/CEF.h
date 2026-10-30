// Umbrella header for the CEF C API used by Arrow.
// Pins the CEF API version so struct layouts match the version passed to
// cef_api_hash() at startup (see CEFRuntime.swift / ArrowHelper/main.swift).
#ifndef ARROW_CEF_H
#define ARROW_CEF_H

#define CEF_API_VERSION 15600

#if defined(_WIN32)
// Swift's WinSDK module splits windows.h into submodules: include the ones
// declaring the types CEF's Windows headers use (HWND, HCURSOR, MSG…).
#include <windows.h>
#include <minwindef.h>
#include <winnt.h>
#include <windef.h>
#include <winuser.h>
#endif

#include "include/cef_api_hash.h"
#include "include/cef_version_info.h"
#if defined(__APPLE__)
#include "include/cef_sandbox_mac.h"
#endif
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_cookie_capi.h"
#include "include/capi/cef_devtools_message_observer_capi.h"
#include "include/capi/cef_dialog_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_download_item_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_focus_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_image_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"
#include "include/capi/cef_keyboard_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_media_router_capi.h"
#include "include/capi/cef_menu_model_capi.h"
#include "include/capi/cef_navigation_entry_capi.h"
#include "include/capi/cef_permission_handler_capi.h"
#include "include/capi/cef_preference_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_request_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_request_context_handler_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_resource_handler_capi.h"
#include "include/capi/cef_resource_request_handler_capi.h"
#include "include/capi/cef_response_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "include/capi/cef_ssl_info_capi.h"
#include "include/capi/cef_ssl_status_capi.h"
#include "include/capi/cef_task_capi.h"
#include "include/capi/cef_trace_capi.h"
#include "include/capi/cef_values_capi.h"
#include "include/capi/cef_x509_certificate_capi.h"

#endif  // ARROW_CEF_H
