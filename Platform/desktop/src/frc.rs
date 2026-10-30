#[cfg(windows)]
pub use amf::Frc;

pub struct Nv12<'a> {
    pub width: i32,
    pub height: i32,
    pub luma: &'a [u8],
    pub luma_pitch: usize,
    pub chroma: &'a [u8],
    pub chroma_pitch: usize,
}

pub fn check() -> i32 {
    const W: usize = 1920;
    const H: usize = 1080;
    let Some(mut frc) = Frc::new(W as i32, H as i32) else {
        return -1;
    };
    let grain =
        |x: usize, y: usize| ((x.wrapping_mul(73_856_093) ^ y.wrapping_mul(19_349_663)) >> 3) % 64;
    let picture = |bar: usize| {
        let mut luma = vec![0u8; W * H];
        for (y, row) in luma.chunks_mut(W).enumerate() {
            for (x, value) in row.iter_mut().enumerate() {
                let bright = x + 12 >= bar && x < bar + 12;
                *value = if bright {
                    190 + grain(x + 1000 - bar, y) as u8
                } else {
                    30 + grain(x, y) as u8
                };
            }
        }
        luma
    };
    let chroma = vec![128u8; W * H / 2];
    let mut found = -2;
    for (index, bar) in [100, 120, 140, 160, 180, 200].into_iter().enumerate() {
        let luma = picture(bar);
        let input = Nv12 {
            width: W as i32,
            height: H as i32,
            luma: &luma,
            luma_pitch: W,
            chroma: &chroma,
            chroma_pitch: W,
        };
        let worked = frc.between(
            &input,
            index as i64 * 16_667,
            16_667,
            &mut |between: &Nv12| {
                let row = &between.luma[H / 2 * between.luma_pitch..][..W];
                let bright: Vec<usize> = (0..W).filter(|&x| row[x] > 150).collect();
                found = if bright.is_empty() {
                    -3
                } else {
                    (bright.iter().sum::<usize>() / bright.len()) as i32
                };
            },
        );
        if !worked {
            return -2;
        }
    }
    found
}

#[cfg(not(windows))]
pub struct Frc;

#[cfg(not(windows))]
impl Frc {
    pub fn available() -> bool {
        false
    }
    pub fn new(_width: i32, _height: i32) -> Option<Frc> {
        None
    }
    pub fn size(&self) -> (i32, i32) {
        (0, 0)
    }
    pub fn between(
        &mut self,
        _picture: &Nv12,
        _time_us: i64,
        _frame_us: i64,
        _out: &mut dyn FnMut(&Nv12),
    ) -> bool {
        false
    }
}

#[cfg(windows)]
mod amf {
    use super::Nv12;
    use std::ffi::c_void;
    use std::ptr::null_mut;
    use std::sync::OnceLock;
    use std::time::{Duration, Instant};
    use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};

    type Result = i32;
    const AMF_OK: Result = 0;
    const AMF_REPEAT: Result = 24;
    const AMF_INPUT_FULL: Result = 25;
    const AMF_NEED_MORE_INPUT: Result = 44;

    const AMF_MEMORY_HOST: i32 = 1;
    const AMF_MEMORY_DX11: i32 = 3;
    const AMF_SURFACE_NV12: i32 = 1;
    const AMF_DX11_0: i32 = 110;

    const AMF_VARIANT_BOOL: i32 = 1;
    const AMF_VARIANT_INT64: i32 = 2;

    const FRC_ENGINE_DX11: i64 = 3;
    const FRC_ONLY_INTERPOLATED: i64 = 2;
    const FRC_PROFILE_HIGH: i64 = 1;
    const FRC_MV_SEARCH_NATIVE: i64 = 0;

    #[repr(C)]
    struct Guid {
        data1: u32,
        data2: u16,
        data3: u16,
        data4: [u8; 8],
    }
    const IID_SURFACE: Guid = Guid {
        data1: 0x3075_dbe3,
        data2: 0x8718,
        data3: 0x4cfa,
        data4: [0x86, 0xfb, 0x21, 0x14, 0xc0, 0xa5, 0xa4, 0x51],
    };

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct Variant {
        kind: i32,
        value: [i64; 2],
    }
    fn boolean(on: bool) -> Variant {
        Variant {
            kind: AMF_VARIANT_BOOL,
            value: [i64::from(on), 0],
        }
    }
    fn integer(value: i64) -> Variant {
        Variant {
            kind: AMF_VARIANT_INT64,
            value: [value, 0],
        }
    }

    #[repr(C)]
    struct Object<T> {
        table: *const T,
    }
    type This = *mut c_void;

    #[repr(C)]
    struct FactoryTable {
        create_context: unsafe extern "system" fn(This, *mut *mut Object<ContextTable>) -> Result,
        create_component: unsafe extern "system" fn(
            This,
            *mut Object<ContextTable>,
            *const u16,
            *mut *mut Object<ComponentTable>,
        ) -> Result,
    }
    #[repr(C)]
    struct ContextTable {
        _acquire: usize,
        release: unsafe extern "system" fn(This) -> i32,
        _query_interface: usize,
        _storage: [usize; 10],
        terminate: unsafe extern "system" fn(This) -> Result,
        _dx9: [usize; 4],
        init_dx11: unsafe extern "system" fn(This, *mut c_void, i32) -> Result,
        _dx11: [usize; 3],
        _opencl: [usize; 8],
        _opengl: [usize; 5],
        _xv: [usize; 4],
        _gralloc: [usize; 4],
        _alloc_buffer: usize,
        alloc_surface: unsafe extern "system" fn(
            This,
            i32,
            i32,
            i32,
            i32,
            *mut *mut Object<SurfaceTable>,
        ) -> Result,
    }
    #[repr(C)]
    struct ComponentTable {
        _acquire: usize,
        release: unsafe extern "system" fn(This) -> i32,
        _query_interface: usize,
        set_property: unsafe extern "system" fn(This, *const u16, Variant) -> Result,
        _storage: [usize; 9],
        _storage_ex: [usize; 4],
        init: unsafe extern "system" fn(This, i32, i32, i32) -> Result,
        _reinit: usize,
        terminate: unsafe extern "system" fn(This) -> Result,
        _drain: usize,
        _flush: usize,
        submit_input: unsafe extern "system" fn(This, This) -> Result,
        query_output: unsafe extern "system" fn(This, *mut This) -> Result,
    }
    #[repr(C)]
    struct SurfaceTable {
        _acquire: usize,
        release: unsafe extern "system" fn(This) -> i32,
        query_interface: unsafe extern "system" fn(This, *const Guid, *mut This) -> Result,
        _storage: [usize; 10],
        _get_memory_type: usize,
        _duplicate: usize,
        convert: unsafe extern "system" fn(This, i32) -> Result,
        _interop: usize,
        _get_data_type: usize,
        _is_reusable: usize,
        set_pts: unsafe extern "system" fn(This, i64),
        _get_pts: usize,
        set_duration: unsafe extern "system" fn(This, i64),
        _get_duration: usize,
        _get_format: usize,
        _get_planes_count: usize,
        get_plane_at: unsafe extern "system" fn(This, usize) -> *mut Object<PlaneTable>,
    }
    #[repr(C)]
    struct PlaneTable {
        _acquire: usize,
        _release: usize,
        _query_interface: usize,
        _get_type: usize,
        get_native: unsafe extern "system" fn(This) -> *mut u8,
        _pixel_size: usize,
        _offset_x: usize,
        _offset_y: usize,
        _width: usize,
        _height: usize,
        get_h_pitch: unsafe extern "system" fn(This) -> i32,
        _v_pitch: usize,
        _tiled: usize,
    }

    type InitFn = unsafe extern "C" fn(u64, *mut *mut Object<FactoryTable>) -> Result;
    type QueryVersionFn = unsafe extern "C" fn(*mut u64) -> Result;

    const FRC_VERSION: u64 = (1 << 48) | (4 << 32) | (35 << 16);

    struct Factory(*mut Object<FactoryTable>);
    unsafe impl Send for Factory {}
    unsafe impl Sync for Factory {}

    fn factory() -> Option<&'static Factory> {
        static FACTORY: OnceLock<Option<Factory>> = OnceLock::new();
        FACTORY
            .get_or_init(|| {
                let name: Vec<u16> = "amfrt64.dll\0".encode_utf16().collect();
                unsafe {
                    let library = LoadLibraryW(name.as_ptr());
                    if library.is_null() {
                        return None;
                    }
                    let query: QueryVersionFn = std::mem::transmute(GetProcAddress(
                        library,
                        c"AMFQueryVersion".as_ptr().cast(),
                    )?);
                    let init: InitFn =
                        std::mem::transmute(GetProcAddress(library, c"AMFInit".as_ptr().cast())?);
                    let mut version = 0u64;
                    if query(&mut version) != AMF_OK || version < FRC_VERSION {
                        return None;
                    }
                    let mut factory = null_mut();
                    (init(version, &mut factory) == AMF_OK && !factory.is_null())
                        .then_some(Factory(factory))
                }
            })
            .as_ref()
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    pub struct Frc {
        context: *mut Object<ContextTable>,
        component: *mut Object<ComponentTable>,
        width: i32,
        height: i32,
    }
    unsafe impl Send for Frc {}

    impl Frc {
        pub fn available() -> bool {
            static AVAILABLE: OnceLock<bool> = OnceLock::new();
            *AVAILABLE.get_or_init(|| Frc::new(1280, 720).is_some())
        }

        pub fn new(width: i32, height: i32) -> Option<Frc> {
            let factory = factory()?;
            if width <= 0 || height <= 0 {
                return None;
            }
            unsafe {
                let mut frc = Frc {
                    context: null_mut(),
                    component: null_mut(),
                    width,
                    height,
                };
                let factory_table = &*(*factory.0).table;
                if (factory_table.create_context)(factory.0.cast(), &mut frc.context) != AMF_OK
                    || frc.context.is_null()
                {
                    return None;
                }
                if ((*(*frc.context).table).init_dx11)(frc.context.cast(), null_mut(), AMF_DX11_0)
                    != AMF_OK
                {
                    return None;
                }
                let id = wide("AMFFRC");
                if (factory_table.create_component)(
                    factory.0.cast(),
                    frc.context,
                    id.as_ptr(),
                    &mut frc.component,
                ) != AMF_OK
                    || frc.component.is_null()
                {
                    return None;
                }
                let component_table = &*(*frc.component).table;
                let this = frc.component.cast();
                let settings = [
                    ("FRCEngineType", integer(FRC_ENGINE_DX11)),
                    ("FRCMode", integer(FRC_ONLY_INTERPOLATED)),
                    ("FRCUseFutureFrame", boolean(false)),
                    ("FRCEnableFallback", boolean(true)),
                    ("FRCIndicator", boolean(false)),
                    ("FRCProfile", integer(FRC_PROFILE_HIGH)),
                    ("FRCMVSEARCHMODE", integer(FRC_MV_SEARCH_NATIVE)),
                ];
                for (name, value) in settings {
                    let name = wide(name);
                    if (component_table.set_property)(this, name.as_ptr(), value) != AMF_OK {
                        return None;
                    }
                }
                if (component_table.init)(this, AMF_SURFACE_NV12, width, height) != AMF_OK {
                    return None;
                }
                Some(frc)
            }
        }

        pub fn size(&self) -> (i32, i32) {
            (self.width, self.height)
        }

        pub fn between(
            &mut self,
            picture: &Nv12,
            time_us: i64,
            frame_us: i64,
            out: &mut dyn FnMut(&Nv12),
        ) -> bool {
            if picture.width != self.width || picture.height != self.height {
                return false;
            }
            unsafe {
                let context = &*(*self.context).table;
                let mut surface = null_mut();
                if (context.alloc_surface)(
                    self.context.cast(),
                    AMF_MEMORY_HOST,
                    AMF_SURFACE_NV12,
                    self.width,
                    self.height,
                    &mut surface,
                ) != AMF_OK
                    || surface.is_null()
                {
                    return false;
                }
                let surface_table = &*(*surface).table;
                let rows = self.height as usize;
                let copied = fill(
                    surface,
                    0,
                    picture.luma,
                    picture.luma_pitch,
                    rows,
                    self.width as usize,
                ) && fill(
                    surface,
                    1,
                    picture.chroma,
                    picture.chroma_pitch,
                    rows / 2,
                    self.width as usize,
                );
                (surface_table.set_pts)(surface.cast(), time_us * 10);
                (surface_table.set_duration)(surface.cast(), frame_us * 10);
                let up =
                    copied && (surface_table.convert)(surface.cast(), AMF_MEMORY_DX11) == AMF_OK;
                let component = &*(*self.component).table;
                let mut submitted = if up {
                    (component.submit_input)(self.component.cast(), surface.cast())
                } else {
                    -1
                };
                if submitted == AMF_INPUT_FULL {
                    self.collect(Duration::from_millis(12), out);
                    submitted = (component.submit_input)(self.component.cast(), surface.cast());
                }
                (surface_table.release)(surface.cast());
                if !up || (submitted != AMF_OK && submitted != AMF_NEED_MORE_INPUT) {
                    return false;
                }
                self.collect(Duration::from_millis(12), out);
                true
            }
        }

        unsafe fn collect(&mut self, mut patience: Duration, out: &mut dyn FnMut(&Nv12)) {
            let started = Instant::now();
            unsafe {
                let component = &*(*self.component).table;
                loop {
                    let mut data: *mut c_void = null_mut();
                    let result = (component.query_output)(self.component.cast(), &mut data);
                    if result == AMF_OK && !data.is_null() {
                        self.deliver(data, out);
                        patience = Duration::ZERO;
                        continue;
                    }
                    if !data.is_null() {
                        release(data);
                    }
                    if (result != AMF_REPEAT && result != AMF_OK && result != AMF_NEED_MORE_INPUT)
                        || started.elapsed() >= patience
                    {
                        return;
                    }
                    std::thread::sleep(Duration::from_micros(500));
                }
            }
        }

        unsafe fn deliver(&mut self, data: *mut c_void, out: &mut dyn FnMut(&Nv12)) {
            unsafe {
                let table = &*(*(data as *mut Object<SurfaceTable>)).table;
                let mut surface: *mut c_void = null_mut();
                let found = (table.query_interface)(data, &IID_SURFACE, &mut surface) == AMF_OK
                    && !surface.is_null();
                release(data);
                if !found {
                    return;
                }
                let surface_table = &*(*(surface as *mut Object<SurfaceTable>)).table;
                if (surface_table.convert)(surface, AMF_MEMORY_HOST) == AMF_OK {
                    let luma = (surface_table.get_plane_at)(surface, 0);
                    let chroma = (surface_table.get_plane_at)(surface, 1);
                    if !luma.is_null() && !chroma.is_null() {
                        let (luma_plane, chroma_plane) = (&*(*luma).table, &*(*chroma).table);
                        let luma_pitch = (luma_plane.get_h_pitch)(luma.cast()) as usize;
                        let chroma_pitch = (chroma_plane.get_h_pitch)(chroma.cast()) as usize;
                        let (y, uv) = (
                            (luma_plane.get_native)(luma.cast()),
                            (chroma_plane.get_native)(chroma.cast()),
                        );
                        let rows = self.height as usize;
                        if !y.is_null()
                            && !uv.is_null()
                            && luma_pitch >= self.width as usize
                            && chroma_pitch >= self.width as usize
                        {
                            out(&Nv12 {
                                width: self.width,
                                height: self.height,
                                luma: std::slice::from_raw_parts(y, luma_pitch * rows),
                                luma_pitch,
                                chroma: std::slice::from_raw_parts(uv, chroma_pitch * (rows / 2)),
                                chroma_pitch,
                            });
                        }
                    }
                }
                (surface_table.release)(surface);
            }
        }
    }

    unsafe fn fill(
        surface: *mut Object<SurfaceTable>,
        index: usize,
        from: &[u8],
        pitch: usize,
        rows: usize,
        width: usize,
    ) -> bool {
        unsafe {
            let plane = ((*(*surface).table).get_plane_at)(surface.cast(), index);
            if plane.is_null() || from.len() < pitch * (rows - 1) + width {
                return false;
            }
            let plane_table = &*(*plane).table;
            let to = (plane_table.get_native)(plane.cast());
            let to_pitch = (plane_table.get_h_pitch)(plane.cast()) as usize;
            if to.is_null() || to_pitch < width {
                return false;
            }
            for row in 0..rows {
                std::ptr::copy_nonoverlapping(
                    from.as_ptr().add(row * pitch),
                    to.add(row * to_pitch),
                    width,
                );
            }
            true
        }
    }

    unsafe fn release(data: *mut c_void) {
        unsafe { ((*(*(data as *mut Object<SurfaceTable>)).table).release)(data) };
    }

    impl Drop for Frc {
        fn drop(&mut self) {
            unsafe {
                if !self.component.is_null() {
                    let component_table = &*(*self.component).table;
                    (component_table.terminate)(self.component.cast());
                    (component_table.release)(self.component.cast());
                }
                if !self.context.is_null() {
                    let context_table = &*(*self.context).table;
                    (context_table.terminate)(self.context.cast());
                    (context_table.release)(self.context.cast());
                }
            }
        }
    }
}
