use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Default)]
pub struct StopToken(Arc<AtomicBool>);

impl StopToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn stop(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_stopped(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    pub fn sleep(&self, duration: Duration) -> bool {
        let deadline = Instant::now() + duration;
        loop {
            if self.is_stopped() {
                return false;
            }
            let now = Instant::now();
            if now >= deadline {
                return true;
            }
            std::thread::sleep((deadline - now).min(Duration::from_millis(20)));
        }
    }
}
