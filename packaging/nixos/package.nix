{ lib, stdenv, python3, kmod, kdePackages, driver, plasmaWidget ? false }:

let
  python = python3.withPackages (ps: [ ps.pyside6 ]);
in
stdenv.mkDerivation {
  pname = "omnibook-fan-curves";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../app
      ../mint/hp-fan-curves.desktop
      ./plasma
    ];
  };

  nativeBuildInputs = [ kdePackages.wrapQtAppsHook ];
  buildInputs = [ kdePackages.qtbase kdePackages.qtwayland kdePackages.breeze-icons ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    app="$out/libexec/omnibook-fan-curves"
    install -d "$app" "$out/bin"
    install -m644 app/*.py app/curves.json "$app/"
    install -m755 app/curve-python app/open-curve-editor app/thermal "$app/"
    substituteInPlace "$app/curve-python" --replace-fail /usr/bin/python3 ${python}/bin/python3
    substituteInPlace "$app/curve_control.py" --replace-fail '"/usr/sbin"' '"${kmod}/bin"'
    install -Dm644 "${driver}/lib/modules/${driver.kernelRelease}/omnibook-fan-probe.ko" \
      "$app/${driver.kernelRelease}/omnibook-fan-probe.ko"
    install -Dm644 "${driver}/lib/modules/${driver.kernelRelease}/omnibook-charge-control.ko" \
      "$app/${driver.kernelRelease}/omnibook-charge-control.ko"
    cat >"$out/bin/hp-fan-curves" <<EOF
#!/bin/sh
exec "$app/open-curve-editor" "\$@"
EOF
    chmod 755 "$out/bin/hp-fan-curves"
    cat >"$out/bin/hp-charge-limit" <<EOF
#!/bin/sh
exec "$app/curve-python" "$app/battery_limit.py" "\$@"
EOF
    chmod 755 "$out/bin/hp-charge-limit"
    install -Dm644 packaging/mint/hp-fan-curves.desktop "$out/share/applications/hp-fan-curves.desktop"
    substituteInPlace "$out/share/applications/hp-fan-curves.desktop" \
      --replace-fail /usr/local/lib/omnibook-fan-curves/open-curve-editor "$out/bin/hp-fan-curves"
    ${lib.optionalString plasmaWidget ''
      plasmoid="$out/share/plasma/plasmoids/local.omnibook.thermal"
      mkdir -p "$plasmoid"
      cp -r packaging/nixos/plasma/. "$plasmoid/"
      substituteInPlace "$plasmoid/contents/ui/HpThermalControls.qml" \
        --replace-fail @THERMAL_HELPER@ "$app/thermal"
      substituteInPlace "$plasmoid/contents/ui/HpThermalControls.qml" \
        --replace-fail 'helper.substring(0, helper.lastIndexOf("/")) + "/open-curve-editor"' \
          "\"$out/bin/hp-fan-curves\""
    ''}
    runHook postInstall
  '';

  meta = {
    description = "Desktop editor and background controller for HP OmniBook fan curves";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "hp-fan-curves";
  };
}
