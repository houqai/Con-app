use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum LogLevel {
    Error,
    Warning,
    Info,
    Debug,
}

pub type LogSink = Arc<dyn Fn(LogLevel, &str) + Send + Sync>;

#[derive(Clone)]
pub struct Logger {
    sink: Option<LogSink>,
    max: LogLevel,
}

impl Default for Logger {
    fn default() -> Self {
        Self::new(None)
    }
}

impl std::fmt::Debug for Logger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(if self.sink.is_some() {
            "Logger(on)"
        } else {
            "Logger(off)"
        })
    }
}

impl Logger {
    pub fn new(sink: Option<LogSink>) -> Self {
        Self::with_max(sink, LogLevel::Debug)
    }

    pub fn with_max(sink: Option<LogSink>, max: LogLevel) -> Self {
        Self { sink, max }
    }

    pub fn log(&self, level: LogLevel, line: impl FnOnce() -> String) {
        if level > self.max {
            return;
        }
        if let Some(s) = &self.sink {
            s(level, &line());
        }
    }

    pub fn info(&self, line: impl FnOnce() -> String) {
        self.log(LogLevel::Info, line);
    }

    pub fn warn(&self, line: impl FnOnce() -> String) {
        self.log(LogLevel::Warning, line);
    }

    pub fn debug(&self, line: impl FnOnce() -> String) {
        self.log(LogLevel::Debug, line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn a_line_above_the_level_is_never_made() {
        let lines = Arc::new(Mutex::new(Vec::new()));
        let kept = lines.clone();
        let log = Logger::with_max(
            Some(Arc::new(move |_, line: &str| {
                kept.lock().unwrap().push(line.to_string())
            })),
            LogLevel::Info,
        );
        let made = std::cell::Cell::new(0);
        log.debug(|| {
            made.set(made.get() + 1);
            "debug".into()
        });
        log.info(|| {
            made.set(made.get() + 1);
            "info".into()
        });
        log.warn(|| "warning".into());
        assert_eq!(made.get(), 1);
        assert_eq!(*lines.lock().unwrap(), ["info", "warning"]);
    }
}
