#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod windows;

pub const PAGE_PREFIX: &str = "https://ca.account.sony.com/";
pub const USAGE: &str = "Usage: con-login <https://ca.account.sony.com/...> <scheme>";

#[cfg_attr(not(any(target_os = "linux", windows)), allow(dead_code))]
pub const CANCELLED: i32 = 1;
pub const USAGE_ERROR: i32 = 2;
pub const UNAVAILABLE: i32 = 3;
pub const FAILED: i32 = 4;

pub fn joined<'a>(cookies: impl IntoIterator<Item = (&'a str, &'a str)>) -> String {
    let mut text = String::new();
    for (name, value) in cookies {
        if !text.is_empty() {
            text.push_str("; ");
        }
        text.push_str(name);
        text.push('=');
        text.push_str(value);
    }
    text
}

pub fn callback_output(address: &str, secure_cookies: &str, plain_cookies: &str) -> String {
    format!("{address}\n{secure_cookies}\n{plain_cookies}\n")
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn scheme_of(address: &str) -> String {
    match address.split_once(':') {
        Some((scheme, _)) if scheme.encode_utf16().count() < 64 => scheme.to_lowercase(),
        _ => String::new(),
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn failure_status(code: u32) -> i32 {
    if code == 0x8007_0002 {
        UNAVAILABLE
    } else {
        FAILED
    }
}

fn main() {
    #[cfg(target_os = "linux")]
    std::process::exit(linux::run());
    #[cfg(windows)]
    std::process::exit(windows::run());
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        eprintln!("{USAGE}");
        std::process::exit(USAGE_ERROR);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookies_are_joined_as_a_request_carries_them() {
        assert_eq!(joined([("a", "1"), ("b", "x=y")]), "a=1; b=x=y");
        assert_eq!(joined([]), "");
    }

    #[test]
    fn the_scheme_is_the_text_before_the_colon() {
        assert_eq!(scheme_of("HTTPS://ca.account.sony.com/x"), "https");
        assert_eq!(
            scheme_of("com.scee.psxandroid.scecompcall://redirect?code=1"),
            "com.scee.psxandroid.scecompcall"
        );
        assert_eq!(scheme_of("about:blank"), "about");
        assert_eq!(scheme_of("no scheme"), "");
        assert_eq!(scheme_of(""), "");
        assert_eq!(scheme_of(&format!("{}:x", "a".repeat(64))), "");
    }

    #[test]
    fn only_a_missing_webview2_ends_with_status_3() {
        assert_eq!(failure_status(0x8007_0002), 3);
        assert_eq!(failure_status(0x8007_139f), 4);
        assert_eq!(failure_status(0x8000_4004), 4);
        assert_eq!(failure_status(0), 4);
    }

    #[test]
    fn the_end_is_three_lines() {
        assert_eq!(
            callback_output("scheme://x?code=1", "a=1; b=2", "b=2"),
            "scheme://x?code=1\na=1; b=2\nb=2\n"
        );
        assert_eq!(callback_output("s://", "", ""), "s://\n\n\n");
    }
}
