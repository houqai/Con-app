use std::sync::{Arc, RwLock};
use std::thread::JoinHandle;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u32)]
pub enum ThreadRole {
    Io = 1,
    Sender = 2,
    Session = 3,
    Control = 4,
    Statistics = 5,
    Discovery = 6,
    Registration = 7,
    Probe = 8,
    Capture = 9,
    Helper = 10,
}

pub type ThreadHook = Arc<dyn Fn(ThreadRole, &str) + Send + Sync>;

static HOOK: RwLock<Option<ThreadHook>> = RwLock::new(None);

pub fn set_hook(hook: Option<ThreadHook>) {
    *HOOK.write().unwrap_or_else(|p| p.into_inner()) = hook;
}

pub fn spawn<F, T>(role: ThreadRole, name: &str, f: F) -> std::io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    let name = name.to_string();
    std::thread::Builder::new()
        .name(name.clone())
        .spawn(move || {
            let hook = HOOK.read().unwrap_or_else(|p| p.into_inner()).clone();
            if let Some(h) = hook {
                h(role, &name);
            }
            f()
        })
}

pub const INTERACTIVE_SUPPORTED: bool = imp::SUPPORTED;

pub fn set_current_thread_interactive() -> Result<(), String> {
    imp::set_interactive()
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
mod imp {
    pub const SUPPORTED: bool = true;

    pub fn set_interactive() -> Result<(), String> {
        let r = unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0)
        };
        if r == 0 {
            Ok(())
        } else {
            Err(format!("pthread_set_qos_class_self_np: error {r}"))
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod imp {
    pub const SUPPORTED: bool = true;

    pub fn set_interactive() -> Result<(), String> {
        let r = unsafe { libc::setpriority(libc::PRIO_PROCESS as _, libc::gettid() as _, -8) };
        if r == 0 {
            Ok(())
        } else {
            Err(format!("setpriority: {}", std::io::Error::last_os_error()))
        }
    }
}

#[cfg(windows)]
mod imp {
    use std::ffi::c_void;

    pub const SUPPORTED: bool = true;

    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentThread() -> *mut c_void;
        fn SetThreadPriority(thread: *mut c_void, priority: i32) -> i32;
    }

    const THREAD_PRIORITY_HIGHEST: i32 = 2;

    pub fn set_interactive() -> Result<(), String> {
        let ok = unsafe { SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST) };
        if ok != 0 {
            Ok(())
        } else {
            Err(format!(
                "SetThreadPriority: {}",
                std::io::Error::last_os_error()
            ))
        }
    }
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "linux",
    target_os = "android",
    windows
)))]
mod imp {
    pub const SUPPORTED: bool = false;

    pub fn set_interactive() -> Result<(), String> {
        Err("not supported on this system".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn hook_runs_on_the_new_thread_first() {
        let seen: Arc<Mutex<Vec<(ThreadRole, String, String)>>> = Arc::default();
        let s = seen.clone();
        set_hook(Some(Arc::new(move |role, name: &str| {
            let current = std::thread::current().name().unwrap_or("").to_string();
            s.lock().unwrap().push((role, name.to_string(), current));
        })));
        let order = Arc::new(Mutex::new(Vec::new()));
        let o = order.clone();
        let t = spawn(ThreadRole::Capture, "con-test-hook", move || {
            o.lock().unwrap().push("work");
        })
        .unwrap();
        t.join().unwrap();
        set_hook(None);
        let seen = seen.lock().unwrap();
        let mine: Vec<_> = seen.iter().filter(|e| e.1 == "con-test-hook").collect();
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].0, ThreadRole::Capture);
        assert_eq!(mine[0].2, "con-test-hook");
        assert_eq!(*order.lock().unwrap(), vec!["work"]);
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    #[test]
    fn interactive_class_on_apple() {
        spawn(ThreadRole::Helper, "con-test-qos", || {
            set_current_thread_interactive().unwrap();
            let mut class = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
            let mut rel = 0;
            let r = unsafe {
                libc::pthread_get_qos_class_np(libc::pthread_self(), &mut class, &mut rel)
            };
            assert_eq!(r, 0);
            assert_eq!(
                class as u32,
                libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE as u32
            );
        })
        .unwrap()
        .join()
        .unwrap();
    }
}
