use std::ffi::c_int;

#[no_mangle]
pub extern "C" fn con_wine_heap_active() -> c_int {
    #[cfg(windows)]
    {
        windows::active() as c_int
    }
    #[cfg(not(windows))]
    {
        0
    }
}

#[cfg(windows)]
pub use windows::con_wine_heap_start;

#[cfg(windows)]
mod windows {
    use core::ffi::{c_void, CStr};
    use core::mem::{offset_of, transmute_copy};
    use core::ptr::{null, null_mut};
    use core::sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering::Relaxed};
    use windows_sys::Win32::Foundation::{HANDLE, HMODULE, MAX_PATH};
    use windows_sys::Win32::System::Diagnostics::Debug::{
        IMAGE_DIRECTORY_ENTRY_IMPORT, IMAGE_NT_HEADERS64,
    };
    use windows_sys::Win32::System::LibraryLoader::{
        GetModuleFileNameW, GetModuleHandleW, GetProcAddress,
    };
    use windows_sys::Win32::System::Memory::{
        HeapAlloc, HeapFree, HeapReAlloc, HeapSize, VirtualAlloc, VirtualFree, VirtualProtect,
        HEAP_ZERO_MEMORY, MEM_COMMIT, MEM_RELEASE, MEM_RESERVE, PAGE_PROTECTION_FLAGS,
        PAGE_READWRITE,
    };
    use windows_sys::Win32::System::ProcessStatus::K32EnumProcessModules;
    use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;
    use windows_sys::Win32::System::SystemServices::{
        IMAGE_DOS_HEADER, IMAGE_IMPORT_BY_NAME, IMAGE_IMPORT_DESCRIPTOR, IMAGE_ORDINAL_FLAG64,
        MEM_TOP_DOWN,
    };
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    use windows_sys::Win32::System::WindowsProgramming::IMAGE_THUNK_DATA64;

    const REGION_SIZE: usize = 2 << 30;
    const INITIAL_COMMIT: usize = 1 << 20;
    const LARGE: usize = 64 << 10;

    static HEAP: AtomicPtr<c_void> = AtomicPtr::new(null_mut());
    static REGION_START: AtomicUsize = AtomicUsize::new(0);
    static REGION_END: AtomicUsize = AtomicUsize::new(0);
    static ACTIVE: AtomicBool = AtomicBool::new(false);

    pub(super) fn active() -> bool {
        ACTIVE.load(Relaxed)
    }

    const MALLOC: usize = 0;
    const CALLOC: usize = 1;
    const REALLOC: usize = 2;
    const FREE: usize = 3;
    const MSIZE: usize = 4;
    const ALIGNED_MALLOC: usize = 5;
    const ALIGNED_REALLOC: usize = 6;
    const ALIGNED_FREE: usize = 7;
    const ALIGNED_MSIZE: usize = 8;
    const HOOKS: usize = 9;
    const NAMES: [&CStr; HOOKS] = [
        c"malloc",
        c"calloc",
        c"realloc",
        c"free",
        c"_msize",
        c"_aligned_malloc",
        c"_aligned_realloc",
        c"_aligned_free",
        c"_aligned_msize",
    ];
    static ORIGINAL: [AtomicUsize; HOOKS] = [const { AtomicUsize::new(0) }; HOOKS];

    type Malloc = unsafe extern "C" fn(usize) -> *mut c_void;
    type Calloc = unsafe extern "C" fn(usize, usize) -> *mut c_void;
    type Realloc = unsafe extern "C" fn(*mut c_void, usize) -> *mut c_void;
    type Free = unsafe extern "C" fn(*mut c_void);
    type Msize = unsafe extern "C" fn(*mut c_void) -> usize;
    type AlignedMalloc = unsafe extern "C" fn(usize, usize) -> *mut c_void;
    type AlignedRealloc = unsafe extern "C" fn(*mut c_void, usize, usize) -> *mut c_void;
    type AlignedFree = unsafe extern "C" fn(*mut c_void);
    type AlignedMsize = unsafe extern "C" fn(*mut c_void, usize, usize) -> usize;
    type CreateHeap = unsafe extern "system" fn(
        u32,
        *mut c_void,
        usize,
        usize,
        *mut c_void,
        *mut c_void,
    ) -> HANDLE;

    unsafe fn original<F: Copy>(index: usize) -> F {
        let address = ORIGINAL[index].load(Relaxed);
        unsafe { transmute_copy::<usize, F>(&address) }
    }

    fn heap() -> HANDLE {
        HEAP.load(Relaxed)
    }

    fn ours(p: *const c_void) -> bool {
        let p = p as usize;
        p >= REGION_START.load(Relaxed) && p < REGION_END.load(Relaxed)
    }

    unsafe extern "C" fn high_malloc(size: usize) -> *mut c_void {
        let p = if size < LARGE {
            unsafe { HeapAlloc(heap(), 0, size.max(1)) }
        } else {
            null_mut()
        };
        if !p.is_null() {
            return p;
        }
        unsafe { original::<Malloc>(MALLOC)(size) }
    }

    unsafe extern "C" fn high_calloc(count: usize, size: usize) -> *mut c_void {
        let Some(total) = count.checked_mul(size) else {
            return null_mut();
        };
        let p = if total < LARGE {
            unsafe { HeapAlloc(heap(), HEAP_ZERO_MEMORY, total.max(1)) }
        } else {
            null_mut()
        };
        if !p.is_null() {
            return p;
        }
        unsafe { original::<Calloc>(CALLOC)(count, size) }
    }

    unsafe extern "C" fn high_free(p: *mut c_void) {
        if p.is_null() {
            return;
        }
        if ours(p) {
            unsafe { HeapFree(heap(), 0, p) };
        } else {
            unsafe { original::<Free>(FREE)(p) }
        }
    }

    unsafe extern "C" fn high_msize(p: *mut c_void) -> usize {
        if ours(p) {
            unsafe { HeapSize(heap(), 0, p) }
        } else {
            unsafe { original::<Msize>(MSIZE)(p) }
        }
    }

    unsafe extern "C" fn high_realloc(p: *mut c_void, size: usize) -> *mut c_void {
        if p.is_null() {
            return unsafe { high_malloc(size) };
        }
        if size == 0 {
            unsafe { high_free(p) };
            return null_mut();
        }
        if !ours(p) {
            return unsafe { original::<Realloc>(REALLOC)(p, size) };
        }
        if size < LARGE {
            let q = unsafe { HeapReAlloc(heap(), 0, p, size) };
            if !q.is_null() {
                return q;
            }
        }
        let q = unsafe { high_malloc(size) };
        if q.is_null() {
            return null_mut();
        }
        let old = unsafe { HeapSize(heap(), 0, p) };
        unsafe {
            core::ptr::copy_nonoverlapping(p as *const u8, q as *mut u8, old.min(size));
            HeapFree(heap(), 0, p);
        }
        q
    }

    unsafe extern "C" fn high_aligned_malloc(size: usize, alignment: usize) -> *mut c_void {
        if !alignment.is_power_of_two() {
            return unsafe { original::<AlignedMalloc>(ALIGNED_MALLOC)(size, alignment) };
        }
        let alignment = alignment.max(size_of::<*mut c_void>());
        let raw = match size.checked_add(alignment + size_of::<*mut c_void>()) {
            Some(total) if total < LARGE => unsafe { HeapAlloc(heap(), 0, total) },
            _ => null_mut(),
        };
        if raw.is_null() {
            return unsafe { original::<AlignedMalloc>(ALIGNED_MALLOC)(size, alignment) };
        }
        let aligned = ((raw as usize + size_of::<*mut c_void>() + alignment - 1) & !(alignment - 1))
            as *mut *mut c_void;
        unsafe { aligned.sub(1).write(raw) };
        aligned as *mut c_void
    }

    unsafe extern "C" fn high_aligned_free(p: *mut c_void) {
        if p.is_null() {
            return;
        }
        if ours(p) {
            unsafe { HeapFree(heap(), 0, (p as *mut *mut c_void).sub(1).read()) };
        } else {
            unsafe { original::<AlignedFree>(ALIGNED_FREE)(p) }
        }
    }

    unsafe extern "C" fn high_aligned_msize(
        p: *mut c_void,
        alignment: usize,
        offset: usize,
    ) -> usize {
        if !ours(p) {
            return unsafe { original::<AlignedMsize>(ALIGNED_MSIZE)(p, alignment, offset) };
        }
        let raw = unsafe { (p as *mut *mut c_void).sub(1).read() };
        unsafe { HeapSize(heap(), 0, raw) - (p as usize - raw as usize) }
    }

    unsafe extern "C" fn high_aligned_realloc(
        p: *mut c_void,
        size: usize,
        alignment: usize,
    ) -> *mut c_void {
        if p.is_null() {
            return unsafe { high_aligned_malloc(size, alignment) };
        }
        if !ours(p) {
            return unsafe { original::<AlignedRealloc>(ALIGNED_REALLOC)(p, size, alignment) };
        }
        if size == 0 {
            unsafe { high_aligned_free(p) };
            return null_mut();
        }
        let q = unsafe { high_aligned_malloc(size, alignment) };
        if q.is_null() {
            return null_mut();
        }
        let old = unsafe { high_aligned_msize(p, alignment, 0) };
        unsafe {
            core::ptr::copy_nonoverlapping(p as *const u8, q as *mut u8, old.min(size));
            high_aligned_free(p);
        }
        q
    }

    fn replacements() -> [usize; HOOKS] {
        [
            high_malloc as Malloc as usize,
            high_calloc as Calloc as usize,
            high_realloc as Realloc as usize,
            high_free as Free as usize,
            high_msize as Msize as usize,
            high_aligned_malloc as AlignedMalloc as usize,
            high_aligned_realloc as AlignedRealloc as usize,
            high_aligned_free as AlignedFree as usize,
            high_aligned_msize as AlignedMsize as usize,
        ]
    }

    fn crt_module(name: &[u8]) -> bool {
        let prefix = b"api-ms-win-crt-heap";
        (name.len() >= prefix.len() && name[..prefix.len()].eq_ignore_ascii_case(prefix))
            || name.eq_ignore_ascii_case(b"ucrtbase.dll")
    }

    unsafe fn patch_module(module: HMODULE, replacements: &[usize; HOOKS]) {
        let base = module as *mut u8;
        unsafe {
            let dos = &*(base as *const IMAGE_DOS_HEADER);
            let nt = &*(base.offset(dos.e_lfanew as isize) as *const IMAGE_NT_HEADERS64);
            let imports = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT as usize];
            if imports.VirtualAddress == 0 {
                return;
            }
            let mut entry =
                base.add(imports.VirtualAddress as usize) as *const IMAGE_IMPORT_DESCRIPTOR;
            while (*entry).Name != 0 {
                let descriptor = &*entry;
                entry = entry.add(1);
                let first_names = descriptor.Anonymous.OriginalFirstThunk;
                let module_name =
                    CStr::from_ptr(base.add(descriptor.Name as usize) as *const _).to_bytes();
                if !crt_module(module_name) || first_names == 0 {
                    continue;
                }
                let mut names = base.add(first_names as usize) as *const IMAGE_THUNK_DATA64;
                let mut slots = base.add(descriptor.FirstThunk as usize) as *mut IMAGE_THUNK_DATA64;
                while (*names).u1.AddressOfData != 0 {
                    let by_name = (*names).u1.Ordinal & IMAGE_ORDINAL_FLAG64 == 0;
                    let slot = &raw mut (*slots).u1.Function;
                    let data = (*names).u1.AddressOfData as usize;
                    names = names.add(1);
                    slots = slots.add(1);
                    if !by_name {
                        continue;
                    }
                    let name = CStr::from_ptr(
                        base.add(data + offset_of!(IMAGE_IMPORT_BY_NAME, Name)) as *const _,
                    );
                    let Some(index) = NAMES.iter().position(|known| *known == name) else {
                        continue;
                    };
                    let mut protection: PAGE_PROTECTION_FLAGS = 0;
                    if VirtualProtect(
                        slot as *const c_void,
                        size_of::<u64>(),
                        PAGE_READWRITE,
                        &mut protection,
                    ) == 0
                    {
                        continue;
                    }
                    slot.write(replacements[index] as u64);
                    VirtualProtect(
                        slot as *const c_void,
                        size_of::<u64>(),
                        protection,
                        &mut protection,
                    );
                }
            }
        }
    }

    unsafe fn is_system(module: HMODULE) -> bool {
        let mut path = [0u16; MAX_PATH as usize];
        let mut system = [0u16; MAX_PATH as usize];
        let length = unsafe { GetSystemDirectoryW(system.as_mut_ptr(), MAX_PATH) } as usize;
        let path_length =
            unsafe { GetModuleFileNameW(module, path.as_mut_ptr(), MAX_PATH) } as usize;
        if path_length == 0 || length == 0 || length > system.len() {
            return true;
        }
        let lower = |c: u16| {
            if (b'A' as u16..=b'Z' as u16).contains(&c) {
                c + 32
            } else {
                c
            }
        };
        path_length >= length
            && path[..length]
                .iter()
                .zip(&system[..length])
                .all(|(a, b)| lower(*a) == lower(*b))
    }

    const fn wide<const N: usize>(text: &str) -> [u16; N] {
        let bytes = text.as_bytes();
        let mut out = [0u16; N];
        let mut i = 0;
        while i < bytes.len() {
            out[i] = bytes[i] as u16;
            i += 1;
        }
        out
    }
    const NTDLL: [u16; 10] = wide("ntdll.dll");
    const UCRTBASE: [u16; 13] = wide("ucrtbase.dll");

    unsafe extern "C" fn start() {
        unsafe {
            let ntdll = GetModuleHandleW(NTDLL.as_ptr());
            if ntdll.is_null()
                || GetProcAddress(ntdll, c"wine_get_version".as_ptr() as *const u8).is_none()
            {
                return;
            }
            let Some(create_heap) = GetProcAddress(ntdll, c"RtlCreateHeap".as_ptr() as *const u8)
            else {
                return;
            };
            let create_heap: CreateHeap = core::mem::transmute(create_heap);
            let crt = GetModuleHandleW(UCRTBASE.as_ptr());
            if crt.is_null() {
                return;
            }
            for (name, original) in NAMES.iter().zip(&ORIGINAL) {
                let Some(function) = GetProcAddress(crt, name.as_ptr() as *const u8) else {
                    return;
                };
                original.store(function as usize, Relaxed);
            }
            let region = VirtualAlloc(
                null(),
                REGION_SIZE,
                MEM_RESERVE | MEM_TOP_DOWN,
                PAGE_READWRITE,
            );
            if region.is_null() {
                return;
            }
            if (region as usize) <= 0x7fff_ffff {
                VirtualFree(region, 0, MEM_RELEASE);
                return;
            }
            if VirtualAlloc(region, INITIAL_COMMIT, MEM_COMMIT, PAGE_READWRITE).is_null() {
                return;
            }
            let heap = create_heap(
                0,
                region,
                REGION_SIZE,
                INITIAL_COMMIT,
                null_mut(),
                null_mut(),
            );
            if heap.is_null() {
                return;
            }
            HEAP.store(heap, Relaxed);
            REGION_START.store(region as usize, Relaxed);
            REGION_END.store(region as usize + REGION_SIZE, Relaxed);
            let mut modules: [HMODULE; 1024] = [null_mut(); 1024];
            let mut bytes: u32 = 0;
            if K32EnumProcessModules(
                GetCurrentProcess(),
                modules.as_mut_ptr(),
                size_of_val(&modules) as u32,
                &mut bytes,
            ) == 0
            {
                return;
            }
            let replacements = replacements();
            let count = (bytes as usize / size_of::<HMODULE>()).min(modules.len());
            for &module in &modules[..count] {
                if !is_system(module) {
                    patch_module(module, &replacements);
                }
            }
            ACTIVE.store(true, Relaxed);
        }
    }

    #[used]
    #[no_mangle]
    #[link_section = ".CRT$XCT"]
    #[allow(non_upper_case_globals)]
    pub static con_wine_heap_start: unsafe extern "C" fn() = start;
}

#[cfg(test)]
mod tests {
    #[test]
    #[cfg(not(windows))]
    fn inactive_where_there_is_no_wine() {
        assert_eq!(super::con_wine_heap_active(), 0);
    }
}
