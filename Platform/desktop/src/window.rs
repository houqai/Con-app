#[no_mangle]
pub extern "C" fn con_window_round_corners() {
    #[cfg(windows)]
    system::round_corners();
}

#[cfg(windows)]
mod system {
    use windows_sys::Win32::Foundation::{HWND, LPARAM};
    use windows_sys::Win32::Graphics::Dwm::{
        DwmSetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND,
    };
    use windows_sys::Win32::System::Threading::GetCurrentThreadId;
    use windows_sys::Win32::UI::WindowsAndMessaging::{EnumThreadWindows, GetClassNameW};

    pub fn round_corners() {
        unsafe { EnumThreadWindows(GetCurrentThreadId(), Some(round), 0) };
    }

    unsafe extern "system" fn round(window: HWND, _: LPARAM) -> i32 {
        let mut class = [0u16; 32];
        let length = unsafe { GetClassNameW(window, class.as_mut_ptr(), class.len() as i32) };
        if String::from_utf16_lossy(&class[..length.max(0) as usize]) == "SDL_app" {
            let preference = DWMWCP_ROUND;
            unsafe {
                DwmSetWindowAttribute(
                    window,
                    DWMWA_WINDOW_CORNER_PREFERENCE as u32,
                    (&preference as *const i32).cast(),
                    std::mem::size_of::<i32>() as u32,
                )
            };
        }
        1
    }
}
