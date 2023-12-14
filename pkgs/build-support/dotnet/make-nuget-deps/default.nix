{ linkFarmFromDrvs, fetchurl }:
let
  mkNetrcFromNuGetConfig = {url, nugetUser, nugetPass}:
    if nugetUser == null then null else
    let
      matches = builtins.elemAt (builtins.split "https?://([a-zA-Z0-9.]+)" url) 1;
      nugetHost = builtins.elemAt matches 0;
    in
      ''
        echo "machine ${nugetHost} login ${nugetUser} password ${nugetPass}" > $PWD/netrc
      '';
in
{ name, nugetDeps, sourceFile ? null }:
linkFarmFromDrvs "${name}-nuget-deps" (nugetDeps {
  fetchNuGet = { pname, version, sha256
    , url ? "https://www.nuget.org/api/v2/package/${pname}/${version}", nugetUser ? null, nugetPass ? null}:
    fetchurl {
      name = "${pname}.${version}.nupkg";
      inherit url sha256;
      netrcPhase = mkNetrcFromNuGetConfig { inherit url nugetUser nugetPass; };
    };
}) // {
  inherit sourceFile;
}
