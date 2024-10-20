{ lib
, runCommandLocal
, runtimeShell
, substituteAll
, nix
, coreutils
, jq
, xmlstarlet
, curl
, gnugrep
, gawk
, dotnet-sdk
, cacert
, findutils
, yq
, nugetConfig ? ""
}:

runCommandLocal "nuget-to-nix" {
  script = substituteAll {
    src = ./nuget-to-nix.sh;
    inherit runtimeShell cacert nugetConfig;

    binPath = lib.makeBinPath [
      nix
      coreutils
      jq
      xmlstarlet
      curl
      gnugrep
      gawk
      dotnet-sdk
      findutils
      yq
    ];
  };

  meta = {
    description = "Convert a nuget packages directory to a lockfile for buildDotnetModule";
    mainProgram = "nuget-to-nix";
  };
} ''
  install -Dm755 $script $out/bin/nuget-to-nix
''
