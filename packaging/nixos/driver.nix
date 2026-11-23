{ lib, stdenv, kernel }:

stdenv.mkDerivation {
  pname = "omnibook-fan-driver";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../../driver;
    fileset = lib.fileset.unions [
      ../../driver/Makefile
      ../../driver/omnibook-fan-probe.c
    ];
  };

  nativeBuildInputs = kernel.moduleBuildDependencies;
  hardeningDisable = [ "all" ];
  dontConfigure = true;
  enableParallelBuilding = true;

  buildPhase = ''
    runHook preBuild
    make -C "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build" M="$PWD" \
      -j"$NIX_BUILD_CORES" modules
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 omnibook-fan-probe.ko \
      "$out/lib/modules/${kernel.modDirVersion}/omnibook-fan-probe.ko"
    runHook postInstall
  '';

  passthru.kernelRelease = kernel.modDirVersion;
  meta = {
    description = "Fan curve driver for HP OmniBook board 8DA8";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}
