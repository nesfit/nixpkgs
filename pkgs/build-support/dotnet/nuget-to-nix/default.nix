{ lib
, runCommandLocal
, runtimeShell
, substituteAll
, nix
, coreutils
, jq
, yq
, curl
, gnugrep
, gawk
, dotnet-sdk
, findutils
, nugetConfig ? ""
}:

runCommandLocal "nuget-to-nix" {
  script = substituteAll {
    src = ./nuget-to-nix.sh;
    inherit runtimeShell nugetConfig;

    binPath = lib.makeBinPath [
      nix
      coreutils
      jq
      yq
      curl
      gnugrep
      gawk
      dotnet-sdk
      findutils
    ];
  };

  meta.description = "Convert a nuget packages directory to a lockfile for buildDotnetModule";
} ''
  install -Dm755 $script $out/bin/nuget-to-nix
''
