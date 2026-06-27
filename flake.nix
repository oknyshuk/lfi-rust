{
  description = "Rust in an LFI sandbox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, rust-overlay, ... }:
    let
      # x86_64 host only: the LFI clang is an aarch64 binary, run under qemu-user.
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      aarch64 = nixpkgs.legacyPackages.aarch64-linux;

      rust = pkgs.rust-bin.stable.latest.default.override {
        targets = [ "aarch64-unknown-linux-musl" ];
      };

      # Trusted component: LFI's verifier, built from source (arm64 only).
      verify =
        let
          disarm = pkgs.fetchFromGitHub {
            owner = "aengelke";
            repo = "disarm";
            rev = "2d13d3f410a52daff1c5d8ef07d623332f372560";
            hash = "sha256-uQC4EhF4ytsGzc5B0uaQKDmuVIGiPDPbY275yIeyWVE=";
          };
        in
        pkgs.stdenv.mkDerivation {
          pname = "lfi-verify";
          version = "fa99ad5";
          src = pkgs.fetchFromGitHub {
            owner = "lfi-project";
            repo = "lfi-verifier";
            rev = "fa99ad5c3bcb0f84d3d0f9b96449657d57e444de";
            hash = "sha256-RPptU8xCm7ASpGEDDtuwD5a2zO8TFx4bxun9UNNebjE=";
          };
          nativeBuildInputs = with pkgs; [
            meson
            ninja
            python3
            go
          ];
          # Pre-place the disarm subproject so the build needs no network.
          postPatch = ''
            cp -r --no-preserve=mode,ownership ${disarm} subprojects/disarm
            cp subprojects/packagefiles/disarm/meson.build subprojects/disarm/
          '';
          mesonFlags = [ "-Darch=arm64" ];
          # upstream's executable() sets install:true, so the default install works.
        };

      # Untrusted compiler: LFI's prebuilt clang (LLVM 23), hash-pinned and run
      # under qemu-user with an assembled aarch64 sysroot. We needn't trust it --
      # the verifier re-checks its output.
      clang = pkgs.fetchzip {
        url = "https://github.com/lfi-project/lfi/releases/download/v0.12/aarch64-lfi-clang.tar.gz";
        hash = "sha256-7/7jh1UwQOf0KYCu/vBXOLxgszduxOdMzvg7schHn5g=";
      };
      sysroot = pkgs.symlinkJoin {
        name = "lfi-aarch64-sysroot";
        paths = [
          aarch64.glibc
          aarch64.stdenv.cc.cc.lib
          aarch64.zlib.out
          aarch64.zstd.out
          aarch64.libxml2.out
        ];
        # lld wants SONAME libxml2.so.2; nixpkgs ships .so.16 (ABI-compatible here).
        postBuild = "ln -s libxml2.so.16 $out/lib/libxml2.so.2";
      };
      lficc = pkgs.writeShellScriptBin "lficc" ''
        export QEMU_LD_PREFIX=${sysroot}
        # ld.lld lists libxml2 as NEEDED but never uses it for ELF linking; our
        # compat .so.2 trips a harmless loader version-mismatch warning. Drop it.
        ${pkgs.qemu-user}/bin/qemu-aarch64 -E LD_LIBRARY_PATH=/lib ${clang}/bin/clang "$@" \
          2> >(grep -v 'libxml2\.so\.2: no version information' >&2)
      '';

      # The artifact: a #![no_std] crate -> verified .lfi. stock rustc can't emit
      # LFI code yet (its LLVM 22 lacks the target, merged upstream in LLVM 23), so
      # rustc emits IR and the pinned LFI clang retargets + codegens it. The build
      # runs the verifier as its last step, so build success = the isolation proof.
      sandbox =
        pkgs.runCommand "sandbox"
          {
            nativeBuildInputs = [
              rust
              lficc
              verify
            ];
          }
          ''
            rustc --edition 2024 --target aarch64-unknown-linux-musl --emit=llvm-ir -O \
              -C codegen-units=1 --crate-type staticlib -C panic=abort ${./src/lib.rs} -o crate.ll
            # --target overrides the IR's triple, so clang applies the LFI rewrites.
            lficc --target=aarch64_lfi-unknown-linux-musl -Wno-override-module -O2 -c crate.ll -o crate.o
            lficc -Wl,--gc-sections -Wl,-u,escape_attempt -Wl,--export-dynamic \
              crate.o -lboxrt -static-pie -o sandbox.lfi
            lfi-verify --ctxreg sandbox.lfi
            install -Dm755 sandbox.lfi $out/bin/sandbox.lfi
          '';

      # An un-sandboxed store, hand-written so the rewriter leaves it alone
      # (.lfi_rewrite_disable). The verifier must reject it -- that's the point of
      # an independent verifier: it fails closed on code the compiler didn't confine.
      rejects-unsandboxed =
        let
          src = pkgs.writeText "unsandboxed.s" ''
            .text
            .globl bad
            bad:
                .lfi_rewrite_disable
                str x0, [x1]
                .lfi_rewrite_enable
                ret
          '';
        in
        pkgs.runCommand "rejects-unsandboxed"
          {
            nativeBuildInputs = [
              lficc
              verify
            ];
          }
          ''
            lficc -Wl,-u,bad -Wl,--export-dynamic ${src} -lboxrt -static-pie -o bad.lfi
            if lfi-verify --ctxreg bad.lfi; then
              echo "FAIL: verifier accepted an un-sandboxed store (fail-open!)" >&2
              exit 1
            fi
            echo "OK: rejected (fails closed)"
            touch $out
          '';
    in
    {
      packages.${system}.default = sandbox;
      checks.${system} = {
        verifies = sandbox;
        inherit rejects-unsandboxed;
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          rust
          lficc
          verify
          pkgs.qemu-user
        ];
      };
    };
}
