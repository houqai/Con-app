use crate::{callback_output, joined, CANCELLED, PAGE_PREFIX, UNAVAILABLE, USAGE, USAGE_ERROR};
use std::cell::{Cell, RefCell};
use std::io::Write;
use std::rc::Rc;
use webkit6::prelude::*;
use webkit6::{
    gio, glib, gtk, soup, CookieManager, NavigationPolicyDecision, NetworkSession, PolicyDecision,
    PolicyDecisionType, WebView,
};

const SITE: &str = "ca.account.sony.com";

fn sandbox_refused() -> bool {
    let restricted =
        std::fs::read_to_string("/proc/sys/kernel/apparmor_restrict_unprivileged_userns")
            .ok()
            .and_then(|text| {
                text.split_whitespace()
                    .next()
                    .and_then(|word| word.parse::<i32>().ok())
            })
            .unwrap_or(0);
    if restricted == 0 {
        return false;
    }
    let label = std::fs::read("/proc/self/attr/apparmor/current")
        .or_else(|_| std::fs::read("/proc/self/attr/current"))
        .unwrap_or_default();
    label.starts_with(b"unconfined")
}

fn cookie_text(cookies: Result<Vec<soup::Cookie>, glib::Error>) -> String {
    let mut cookies = cookies.unwrap_or_default();
    let pairs: Vec<(String, String)> = cookies
        .iter_mut()
        .map(|cookie| {
            (
                cookie.name().map(|n| n.to_string()).unwrap_or_default(),
                cookie.value().map(|v| v.to_string()).unwrap_or_default(),
            )
        })
        .collect();
    joined(
        pairs
            .iter()
            .map(|(name, value)| (name.as_str(), value.as_str())),
    )
}

struct Page {
    scheme: String,
    session: NetworkSession,
    window: RefCell<Option<gtk::ApplicationWindow>>,
    ended: RefCell<Option<String>>,
    status: Rc<Cell<i32>>,
}

impl Page {
    fn decide(self: &Rc<Self>, decision: &PolicyDecision, kind: PolicyDecisionType) -> bool {
        if kind != PolicyDecisionType::NavigationAction
            && kind != PolicyDecisionType::NewWindowAction
        {
            return false;
        }
        let address = decision
            .downcast_ref::<NavigationPolicyDecision>()
            .and_then(|navigation| navigation.navigation_action())
            .and_then(|action| action.request())
            .and_then(|request| request.uri())
            .map(|uri| uri.to_string());
        let scheme = address
            .as_deref()
            .and_then(glib::Uri::parse_scheme)
            .map(|scheme| scheme.to_string());
        if scheme.as_deref() == Some(self.scheme.as_str()) {
            decision.ignore();
            if self.ended.borrow().is_none() {
                *self.ended.borrow_mut() = address;
                if let Some(cookies) = self.session.cookie_manager() {
                    let page = Rc::clone(self);
                    let secure = format!("https://{SITE}/");
                    cookies
                        .clone()
                        .cookies(&secure, gio::Cancellable::NONE, move |found| {
                            page.secure_cookies(&cookies, cookie_text(found))
                        });
                }
            }
            return true;
        }
        if scheme.is_none()
            || (scheme.as_deref() != Some("https") && address.as_deref() != Some("about:blank"))
        {
            decision.ignore();
            return true;
        }
        false
    }

    fn secure_cookies(self: Rc<Self>, cookies: &CookieManager, secure_text: String) {
        let plain = format!("http://{SITE}/");
        cookies.cookies(&plain, gio::Cancellable::NONE, move |found| {
            let plain_text = cookie_text(found);
            let address = self.ended.borrow().clone().unwrap_or_default();
            let mut out = std::io::stdout().lock();
            let _ = out.write_all(callback_output(&address, &secure_text, &plain_text).as_bytes());
            let _ = out.flush();
            self.status.set(0);
            if let Some(window) = self.window.borrow_mut().take() {
                window.destroy();
            }
        });
    }
}

pub fn run() -> i32 {
    if sandbox_refused() {
        eprintln!("con-login: AppArmor blocks the WebKit sandbox for this program; run Linux/install-apparmor.sh");
        return UNAVAILABLE;
    }
    let Ok(arguments) = std::env::args_os()
        .map(|argument| argument.into_string())
        .collect::<Result<Vec<String>, _>>()
    else {
        eprintln!("{USAGE}");
        return USAGE_ERROR;
    };
    if arguments.len() != 3 || !arguments[1].starts_with(PAGE_PREFIX) {
        eprintln!("{USAGE}");
        return USAGE_ERROR;
    }
    let address = arguments[1].clone();
    let scheme = arguments[2].clone();
    let status = Rc::new(Cell::new(CANCELLED));
    let sessions: Rc<RefCell<Vec<NetworkSession>>> = Rc::default();
    let app = gtk::Application::new(Some("app.sole.login"), gio::ApplicationFlags::NON_UNIQUE);
    let ended_with = Rc::clone(&status);
    let kept = Rc::clone(&sessions);
    app.connect_activate(move |app| {
        let session = NetworkSession::new_ephemeral();
        kept.borrow_mut().push(session.clone());
        let view = WebView::builder().network_session(&session).build();
        let window = gtk::ApplicationWindow::new(app);
        window.set_title(Some("PlayStation — Con"));
        window.set_default_size(520, 760);
        window.set_child(Some(&view));
        let page = Rc::new(Page {
            scheme: scheme.clone(),
            session,
            window: RefCell::new(Some(window.clone())),
            ended: RefCell::new(None),
            status: Rc::clone(&ended_with),
        });
        view.connect_decide_policy(move |_, decision, kind| page.decide(decision, kind));
        view.load_uri(&address);
        window.present();
    });
    app.run_with_args(&arguments[..1]);
    let status = status.get();
    std::mem::forget(sessions);
    status
}
