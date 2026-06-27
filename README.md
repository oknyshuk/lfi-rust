# Rust in an LFI sandbox

A `#![no_std]` Rust library compiled into an [LFI](https://github.com/lfi-project) sandbox and
certified by LFI's independent verifier. LFI is software fault isolation for AArch64: it
reserves registers and rewrites every load/store/branch so code can't leave a 4 GiB region,
then a separate static verifier re-checks the machine code. LFI ships C/C++/asm; this adds Rust.

## Claim

> Rust compiles to verifier-certified, confined LFI code; and the verifier independently
> rejects code that isn't confined.

## Usage

```bash
nix build         # Rust -> .lfi, with lfi-verify as the final build step
nix flake check   # certifies the crate; checks the verifier rejects an un-sandboxed store
nix develop       # rustc (+aarch64 target), the LFI clang, lfi-verify
```

## What it proves

| Property                                      | Mechanism                           | Proof                           |
| --------------------------------------------- | ----------------------------------- | ------------------------------- |
| Compiled Rust can't leave the sandbox         | LFI rewrites + reserved x25–x30     | `nix build` (`checks.verifies`) |
| The verifier is independent, and fails closed | re-checks machine code, from source | `checks.rejects-unsandboxed`    |

`nix build` runs `lfi-verify` on the output as its last step, so it can only ever produce a
certified-confined `.lfi`. A write 4 GiB out of bounds, for instance, compiles to a masked store:

```asm
add x8, x8, x0           ; x8 = &local + offset  (the 4 GiB out-of-bounds address survives)
str x1, [x27, w8, uxtw]  ; LFI masks it: sandbox base + low 32 bits, discarding the 4 GiB
```

## How

Stock rustc can't emit LFI code yet: the upstreamed `aarch64_lfi` target is in LLVM 23, but
rust still ships LLVM 22. So `rustc` emits LLVM IR, the hash-pinned LFI `clang` retargets and
codegens it (register reservation + the SFI rewrites), it's linked with `boxrt`, and
`lfi-verify` certifies the result. The untrusted compiler is a pinned prebuilt; the trusted
verifier is built from source. (When rust reaches LLVM 23 this becomes a `target.json` +
`cargo build`, no clang.)

## Key files

```
flake.nix    the whole build: verifier from source, pinned clang, sandbox, checks
src/lib.rs   the #![no_std] library
```

## Limits

- The verifier proves **isolation, not correctness**.
- AArch64 via qemu-user on an x86-64 host; not yet run on real hardware.
- `#![no_std]`, no `alloc`.
- 128-bit atomics are sandboxed correctly (`ldxp/stxp …, [x28]`), but `lfi-verify`'s decoder
  misreads the pair's `Rt2` field (`x1` → `x0`) and rejects them. Observed as a false-positive
  on safe code; whether the same misread affects other encodings is uncharacterized - a bug in
  the verifier's decoder.

## License

MIT
