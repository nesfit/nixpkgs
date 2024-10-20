{ fetchurl, buildDotnetPackage, unzip }:

attrs @
{ pname
, version
, url ? "https://www.nuget.org/api/v2/package/${pname}/${version}"
, sha256 ? ""
, hash ? ""
, md5 ? ""
, nugetUser ? null
, nugetPass ? null
, ...
}:
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
if md5 != "" then
  throw "fetchnuget does not support md5 anymore, please use 'hash' attribute with SRI hash"
# This is also detected in fetchurl, but we just throw here to avoid confusion
else if (sha256 != "" && hash != "") then
  throw "multiple hashes passed to fetchNuGet"
else
  buildDotnetPackage ({
    src = fetchurl {
      inherit url sha256 hash;
      name = "${pname}.${version}.zip";
      netrcPhase = mkNetrcFromNuGetConfig { inherit url nugetUser nugetPass; };
    };

    sourceRoot = ".";

    nativeBuildInputs = [ unzip ];

    dontBuild = true;

    preInstall = ''
      function traverseRename () {
        for e in *
        do
          t="$(echo "$e" | sed -e "s/%20/\ /g" -e "s/%2B/+/g")"
          [ "$t" != "$e" ] && mv -vn "$e" "$t"
          if [ -d "$t" ]
          then
            cd "$t"
            traverseRename
            cd ..
          fi
        done
      }

      traverseRename
   '';
  } // attrs)
