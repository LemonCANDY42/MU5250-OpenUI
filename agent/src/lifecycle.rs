use std::sync::Arc;

use crate::adapter::B04Adapter;
use crate::b04_io::{B04Io, DeviceLifecycleAction, SystemB04Io};

pub trait LifecycleControl: Send + Sync {
    fn execute(&self, action: DeviceLifecycleAction) -> Result<(), String>;
}

pub struct LifecycleService {
    io: Arc<dyn B04Io>,
}

impl LifecycleService {
    pub fn new() -> Self {
        Self {
            io: Arc::new(SystemB04Io::new()),
        }
    }
}

impl LifecycleControl for LifecycleService {
    fn execute(&self, action: DeviceLifecycleAction) -> Result<(), String> {
        B04Adapter::new()
            .firmware_gate()
            .map_err(|_| "the exact HK B04 firmware identity is not verified".to_string())?;
        self.io.device_lifecycle(action)
    }
}
