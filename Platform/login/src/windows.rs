use crate::{
    callback_output, failure_status, joined, scheme_of, CANCELLED, FAILED, PAGE_PREFIX, USAGE,
    USAGE_ERROR,
};
use std::cell::RefCell;
use std::ffi::c_void;
use std::io::Write;
use std::os::windows::ffi::OsStrExt;
use webview2_com::Microsoft::Web::WebView2::Win32::*;
use webview2_com::{
    CreateCoreWebView2ControllerCompletedHandler, CreateCoreWebView2EnvironmentCompletedHandler,
    GetCookiesCompletedHandler, NavigationCompletedEventHandler, NavigationStartingEventHandler,
    NewWindowRequestedEventHandler,
};
use windows::core::{w, Interface, BOOL, HRESULT, HSTRING, PCWSTR, PWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::System::Com::{
    CoInitializeEx, CoTaskMemFree, CoUninitialize, COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Console::{FreeConsole, GetConsoleProcessList};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{
    GetDpiForSystem, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Shell::{FOLDERID_LocalAppData, SHGetKnownFolderPath, KF_FLAG_DEFAULT};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetClientRect, GetMessageW,
    LoadCursorW, LoadIconW, PostQuitMessage, RegisterClassW, ShowWindow, TranslateMessage,
    CW_USEDEFAULT, IDC_ARROW, MSG, SW_SHOW, WINDOW_EX_STYLE, WM_DESTROY, WM_SIZE, WNDCLASSW,
    WS_OVERLAPPEDWINDOW,
};

const SITE: PCWSTR = w!("https://ca.account.sony.com/");

#[link(name = "WebView2LoaderStatic", kind = "static")]
extern "system" {
    fn CreateCoreWebView2EnvironmentWithOptions(
        browser_executable_folder: PCWSTR,
        user_data_folder: PCWSTR,
        environment_options: *mut c_void,
        environment_created_handler: *mut c_void,
    ) -> HRESULT;
}

#[derive(Default)]
struct State {
    scheme: String,
    start_address: HSTRING,
    window: HWND,
    controller: Option<ICoreWebView2Controller>,
    view: Option<ICoreWebView2>,
    status: i32,
    ended: bool,
    ended_address: String,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State { status: CANCELLED, ..State::default() });
}

fn with<T>(action: impl FnOnce(&mut State) -> T) -> T {
    STATE.with(|state| action(&mut state.borrow_mut()))
}

fn close_window() {
    let window = with(|state| state.window);
    unsafe {
        let _ = DestroyWindow(window);
    }
}

fn take_string(text: PWSTR) -> String {
    if text.is_null() {
        return String::new();
    }
    unsafe {
        let read = String::from_utf16_lossy(text.as_wide());
        CoTaskMemFree(Some(text.0 as *const c_void));
        read
    }
}

fn navigation_allowed(address: &str) -> bool {
    let kind = scheme_of(address);
    let (scheme, ended, view) =
        with(|state| (state.scheme.clone(), state.ended, state.view.clone()));
    if kind.eq_ignore_ascii_case(&scheme) {
        if let (false, Some(view)) = (ended, view) {
            with(|state| {
                state.ended = true;
                state.ended_address = address.to_string();
            });
            let asked = unsafe {
                view.cast::<ICoreWebView2_2>()
                    .and_then(|view2| view2.CookieManager())
                    .map(|cookies| {
                        let handler =
                            GetCookiesCompletedHandler::create(Box::new(cookies_received));
                        let _ = cookies.GetCookies(SITE, &handler);
                    })
            };
            if asked.is_err() {
                close_window();
            }
        }
        return false;
    }
    kind == "https" || address == "about:blank"
}

fn cookies_received(
    result: windows::core::Result<()>,
    cookies: Option<ICoreWebView2CookieList>,
) -> windows::core::Result<()> {
    let mut all: Vec<(String, String)> = Vec::new();
    let mut plain: Vec<(String, String)> = Vec::new();
    if let (Ok(()), Some(cookies)) = (result, cookies) {
        let mut count = 0u32;
        unsafe {
            let _ = cookies.Count(&mut count);
            for index in 0..count {
                let Ok(cookie) = cookies.GetValueAtIndex(index) else {
                    continue;
                };
                let (mut name, mut value, mut secure) = (PWSTR::null(), PWSTR::null(), BOOL(0));
                let _ = cookie.Name(&mut name);
                let _ = cookie.Value(&mut value);
                let _ = cookie.IsSecure(&mut secure);
                let pair = (take_string(name), take_string(value));
                if !secure.as_bool() {
                    plain.push(pair.clone());
                }
                all.push(pair);
            }
        }
    }
    let pairs = |list: &[(String, String)]| {
        joined(
            list.iter()
                .map(|(name, value)| (name.as_str(), value.as_str())),
        )
    };
    let address = with(|state| state.ended_address.clone());
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(callback_output(&address, &pairs(&all), &pairs(&plain)).as_bytes());
    let _ = out.flush();
    with(|state| state.status = 0);
    close_window();
    Ok(())
}

fn navigation_starting(
    _sender: Option<ICoreWebView2>,
    args: Option<ICoreWebView2NavigationStartingEventArgs>,
) -> windows::core::Result<()> {
    let Some(args) = args else { return Ok(()) };
    let mut address = PWSTR::null();
    unsafe {
        let _ = args.Uri(&mut address);
        if !navigation_allowed(&take_string(address)) {
            let _ = args.SetCancel(true);
        }
    }
    Ok(())
}

fn new_window_requested(
    sender: Option<ICoreWebView2>,
    args: Option<ICoreWebView2NewWindowRequestedEventArgs>,
) -> windows::core::Result<()> {
    let Some(args) = args else { return Ok(()) };
    let mut address = PWSTR::null();
    unsafe {
        let _ = args.Uri(&mut address);
        let _ = args.SetHandled(true);
        let address = take_string(address);
        if navigation_allowed(&address) {
            if let Some(sender) = sender {
                let _ = sender.Navigate(&HSTRING::from(address));
            }
        }
    }
    Ok(())
}

fn navigation_completed(
    _sender: Option<ICoreWebView2>,
    args: Option<ICoreWebView2NavigationCompletedEventArgs>,
) -> windows::core::Result<()> {
    let Some(args) = args else { return Ok(()) };
    let (mut success, mut error) = (BOOL(0), COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN);
    unsafe {
        let _ = args.IsSuccess(&mut success);
        let _ = args.WebErrorStatus(&mut error);
    }
    eprintln!(
        "con-login: page {} ({})",
        if success.as_bool() {
            "loaded"
        } else {
            "failed"
        },
        error.0
    );
    Ok(())
}

fn hresult(result: &windows::core::Result<()>) -> u32 {
    match result {
        Ok(()) => 0,
        Err(error) => error.code().0 as u32,
    }
}

fn controller_made(
    result: windows::core::Result<()>,
    made: Option<ICoreWebView2Controller>,
) -> windows::core::Result<()> {
    let code = hresult(&result);
    let (Ok(()), Some(controller)) = (result, made) else {
        eprintln!("con-login: no page (0x{code:08x})");
        with(|state| state.status = failure_status(code));
        close_window();
        return Ok(());
    };
    eprintln!("con-login: page ready");
    let (window, address) = with(|state| (state.window, state.start_address.clone()));
    unsafe {
        let Ok(view) = controller.CoreWebView2() else {
            return Ok(());
        };
        with(|state| {
            state.controller = Some(controller.clone());
            state.view = Some(view.clone());
        });
        let mut bounds = RECT::default();
        let _ = GetClientRect(window, &mut bounds);
        let _ = controller.SetBounds(bounds);
        let mut token = 0i64;
        let _ = view.add_NavigationStarting(
            &NavigationStartingEventHandler::create(Box::new(navigation_starting)),
            &mut token,
        );
        let _ = view.add_NewWindowRequested(
            &NewWindowRequestedEventHandler::create(Box::new(new_window_requested)),
            &mut token,
        );
        let _ = view.add_NavigationCompleted(
            &NavigationCompletedEventHandler::create(Box::new(navigation_completed)),
            &mut token,
        );
        let _ = view.Navigate(&address);
    }
    Ok(())
}

fn environment_made(
    result: windows::core::Result<()>,
    environment: Option<ICoreWebView2Environment>,
) -> windows::core::Result<()> {
    let code = hresult(&result);
    let (Ok(()), Some(environment)) = (result, environment) else {
        eprintln!("con-login: no browser (0x{code:08x})");
        with(|state| state.status = failure_status(code));
        close_window();
        return Ok(());
    };
    let window = with(|state| state.window);
    let handler = CreateCoreWebView2ControllerCompletedHandler::create(Box::new(controller_made));
    unsafe {
        let private = environment
            .cast::<ICoreWebView2Environment10>()
            .and_then(|environment10| {
                let options = environment10.CreateCoreWebView2ControllerOptions()?;
                options.SetIsInPrivateModeEnabled(true)?;
                environment10.CreateCoreWebView2ControllerWithOptions(window, &options, &handler)
            });
        if private.is_err() {
            let _ = environment.CreateCoreWebView2Controller(window, &handler);
        }
    }
    Ok(())
}

extern "system" fn window_procedure(window: HWND, message: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    match message {
        WM_SIZE => {
            if let Some(controller) = with(|state| state.controller.clone()) {
                let mut bounds = RECT::default();
                unsafe {
                    let _ = GetClientRect(window, &mut bounds);
                    let _ = controller.SetBounds(bounds);
                }
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(window, message, w, l) },
    }
}

fn scaled(value: i32, dpi: u32) -> i32 {
    ((i64::from(value) * i64::from(dpi) + 48) / 96) as i32
}

pub fn run() -> i32 {
    let arguments: Vec<Vec<u16>> = std::env::args_os()
        .map(|argument| argument.encode_wide().collect())
        .collect();
    let prefix: Vec<u16> = PAGE_PREFIX.encode_utf16().collect();
    if arguments.len() != 3 || !arguments[1].starts_with(&prefix) || arguments[2].len() >= 64 {
        eprintln!("{USAGE}");
        return USAGE_ERROR;
    }
    with(|state| {
        state.start_address = HSTRING::from_wide(&arguments[1]);
        state.scheme = String::from_utf16_lossy(&arguments[2]);
    });
    unsafe {
        let mut processes = [0u32; 2];
        if GetConsoleProcessList(&mut processes) == 1 {
            let _ = FreeConsole();
        }
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        if CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_err() {
            return FAILED;
        }
        let instance: HINSTANCE = GetModuleHandleW(None).map(Into::into).unwrap_or_default();
        let class = WNDCLASSW {
            lpfnWndProc: Some(window_procedure),
            hInstance: instance,
            lpszClassName: w!("ConLogin"),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hIcon: LoadIconW(Some(instance), PCWSTR(std::ptr::without_provenance(1)))
                .unwrap_or_default(),
            ..Default::default()
        };
        RegisterClassW(&class);
        let dpi = GetDpiForSystem();
        let Ok(window) = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("ConLogin"),
            w!("PlayStation \u{2014} Con"),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            scaled(520, dpi),
            scaled(760, dpi),
            None,
            None,
            Some(instance),
            None,
        ) else {
            return FAILED;
        };
        with(|state| state.window = window);
        let _ = ShowWindow(window, SW_SHOW);
        let Ok(local) = SHGetKnownFolderPath(&FOLDERID_LocalAppData, KF_FLAG_DEFAULT, None) else {
            return FAILED;
        };
        let mut data: Vec<u16> = local.as_wide().to_vec();
        CoTaskMemFree(Some(local.0 as *const c_void));
        data.extend("\\app.sole.desktop\\WebView2".encode_utf16());
        data.truncate(259);
        data.push(0);
        let handler =
            CreateCoreWebView2EnvironmentCompletedHandler::create(Box::new(environment_made));
        let made = CreateCoreWebView2EnvironmentWithOptions(
            PCWSTR::null(),
            PCWSTR(data.as_ptr()),
            std::ptr::null_mut(),
            handler.as_raw(),
        );
        if made.is_err() {
            eprintln!("con-login: WebView2 is not there (0x{:08x})", made.0 as u32);
            return failure_status(made.0 as u32);
        }
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).0 > 0 {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if let Some(controller) = with(|state| state.controller.take()) {
            let _ = controller.Close();
        }
        with(|state| state.view = None);
        CoUninitialize();
    }
    with(|state| state.status)
}
