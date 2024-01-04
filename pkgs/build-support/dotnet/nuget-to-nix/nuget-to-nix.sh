#!@runtimeShell@

set -euo pipefail
shopt -s nullglob

export PATH="@binPath@"
# used for glob ordering of package names
export LC_ALL=C

if [ $# -eq 0 ]; then
  >&2 echo "Usage: $0 <packages directory> [path to a file with a list of excluded packages] > deps.nix"
  exit 1
fi

pkgs=$1
tmp=$(realpath "$(mktemp -td nuget-to-nix.XXXXXX)")
trap 'rm -r "$tmp"' EXIT
trap "printf '\n]\n'" EXIT

excluded_list=$(realpath "${2:-/dev/null}")

export DOTNET_NOLOGO=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1

mapfile -t sources < <(dotnet nuget list source --format short | awk '/^E / { print $2 }')

declare -A base_addresses

nuget_config_path="@nugetConfig@"
if [[ -z $nuget_config_path ]]; then
  nuget_config_path=$(realpath $(find . -iname 'NuGet.Config' | sort | head -n 1))
fi

for index in "${sources[@]}"; do
  base_addresses[$index]=$(
    curl --compressed --netrc -fL "$index" | \
      jq -r '[.resources[] | select(."@type" == "SearchQueryService")."@id"].[0]')
done

get_nuget_package_source () {
  # $1 = source
  # $2 = nuget_config_path
  xq -r '.configuration.packageSources.add[] | select(.["@value"] == "'$1'").["@key"]' $2
}

get_nuget_user () {
  # $1 = NUGET_NAME
  # $2 = nuget_config_path
  xq -r '.configuration.packageSourceCredentials.["'$1'"].add[] | select(.["@key"] == "Username").["@value"]' $2
}

get_nuget_pass () {
  # $1 = NUGET_NAME
  # $2 = nuget_config_path
  xq -r '.configuration.packageSourceCredentials.["'$1'"].add[] | select(.["@key"] == "ClearTextPassword").["@value"]' $2
}

get_nuget_config_param () {
  # $1 = source
  # $2 nuget_config_path
  NUGET_NAME="$(get_nuget_package_source $source $nuget_config_path)"
  if [ $NUGET_NAME ]; then
    NUGET_USER="$(get_nuget_user $NUGET_NAME $nuget_config_path)"
    NUGET_PASS="$(get_nuget_pass $NUGET_NAME $nuget_config_path)"
  fi

  if [ $NUGET_USER ]; then
    echo "nugetUser = \"$NUGET_USER\"; nugetPass = \"$NUGET_PASS\"; "
  else
    echo "couldn't find nuget package source $source definition in $nuget_config_path" >&2
    exit 0
  fi
}

try_get_package_content_url_from_source () {
  source="$1"
  # Remove the protocol (https://) from the beginning of the URL
  package_source_host="${source#*://}"

  # Remove everything after the first slash to get the hostname
  package_source_host="${package_source_host%%/*}"

  netrc_filepath="$PWD"/.netrc-nuget
  api_json_tmp_path="$PWD/.temp"

  if [ $nuget_config_path ]; then
    NUGET_NAME="$(get_nuget_package_source $source $nuget_config_path)"
    if [ $NUGET_NAME ]; then
      NUGET_USER="$(get_nuget_user $NUGET_NAME $nuget_config_path)"
      NUGET_PASS="$(get_nuget_pass $NUGET_NAME $nuget_config_path)"
    else
      echo "couldn't find nuget package source $source definition in $nuget_config_path" >&2
    fi
  fi

  if [ $NUGET_USER ]; then
    echo "machine $package_source_host login $NUGET_USER password $NUGET_PASS" > $netrc_filepath
  else
    echo > $netrc_filepath
  fi

  package_info_source="${base_addresses[$source]}"
  if [ -z $package_info_source ]; then
    echo "couldn't match corresponding nuget source address with $source" >&2
    exit 0
  fi

  curl --compressed --netrc-file $netrc_filepath -fL "${base_addresses[$source]}?q=${id}" > $api_json_tmp_path
  if [ $(jq -r '.totalHits' < $api_json_tmp_path) -eq 0 ]; then
    echo "couldn't find nuget package $package at ${base_addresses[$source]}" >&2
    exit 0
  fi

  package_info_url="$(jq -r '.data[] | select(.id | test("^'$package'$"; "i")).versions[] | select(.version == "'$version'")."@id"' < $api_json_tmp_path)"
  if [ "$package_info_url" == "null" ]; then
    echo "couldn't find nuget package $package with $version at ${base_addresses[$source]}, found $package_info" >&2
    exit 0
  fi

  package_content_url=$(
    curl --compressed --netrc-file $netrc_filepath -fL "${package_info_url}" | \
      jq -r '.packageContent')

  echo $package_content_url
}

echo "{ fetchNuGet }: ["

cd "$pkgs"
for package in *; do
  cd "$package"
  for version in *; do
    package_nuspec_path=$(find "$version" -iname "$package".nuspec)
    id=$(cat $package_nuspec_path | xq -r .package.metadata.id)

    if grep -qxF "$id.$version.nupkg" "$excluded_list"; then
      continue
    fi

    source="$(jq -r '.source' "$version"/.nupkg.metadata)"
    sha256="$(nix-hash --type sha256 --flat --base32 "$version/$package.$version".nupkg)"
    if [ -z ${sha256} ]; then
      echo "couldn't find $package $version" >&2
      exit 1
    fi

    if [[ "$source" =~ ^https://api.nuget.org ]]; then
      echo "  (fetchNuGet { pname = \"$id\"; version = \"$version\"; sha256 = \"$sha256\"; })"
      continue
    fi

    if [[ "$source" == "null" ]]; then
      for index in "${sources[@]}"; do
        source=$index
        package_content_url=$(try_get_package_content_url_from_source $source)
        if [[ ! -z $package_content_url ]]; then
          break
        fi
      done
      nuget_config_param=$(get_nuget_config_param $source $nuget_config_path)
    else
      package_content_url=$(try_get_package_content_url_from_source $source)
      nuget_config_param=$(get_nuget_config_param $source $nuget_config_path)
    fi

    echo "  (fetchNuGet { pname = \"$id\"; version = \"$version\"; sha256 = \"$sha256\"; url = \"$package_content_url\"; $nuget_config_param})"

  done
  cd ..
done


