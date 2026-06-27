#![no_std]

/// `escape_attempt(4 GiB, val)` writes `val` 4 GiB past `local` - outside this
/// 4 GiB sandbox. The out-of-bounds address is intentional UB; `black_box` keeps
/// the optimizer from folding it away, so it survives to codegen, where LFI masks
/// the store back in-bounds (see the README). `nix build` then has the
/// verifier certify that every store in the binary carries that mask.
#[unsafe(no_mangle)]
pub extern "C" fn escape_attempt(offset: u64, val: u64) -> u64 {
    let mut local: u64 = 0;
    let p = core::hint::black_box((&raw mut local).wrapping_byte_add(offset as usize));
    unsafe { p.write_volatile(val) };
    unsafe { (&raw const local).read_volatile() }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
