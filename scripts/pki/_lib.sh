#!/usr/bin/env bash

# Shared helpers for the host-only PKI gate. This file is sourced by the
# executable scripts; it does not perform any operation on its own.

PKI_REPOSITORY_ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
PKI_OWNER_CA_COMPLETION='u60-owner-ca-complete-v1'
PKI_DEVICE_CSR_COMPLETION='u60-device-csr-complete-v1'
PKI_DEVICE_BUNDLE_COMPLETION='u60-device-bundle-complete-v1'
PKI_PUBLISHED_PATHS=()
PKI_PUBLISHED_COUNT=0
PKI_PUBLISH_COMPLETE=no
PKI_VALIDATED_DIRECTORY=''
PKI_CURRENT_USER_HOME=''

pki_die() {
  printf 'u60-pki: %s\n' "$*" >&2
  exit 1
}

pki_resolve_current_user_home() {
  local home_candidate

  case "$(uname -s)" in
    Darwin)
      home_candidate=$(id -P 2>/dev/null | awk -F: 'NR == 1 { print $9 }')
      ;;
    *)
      if command -v getent >/dev/null 2>&1; then
        home_candidate=$(getent passwd "$(id -u)" | awk -F: 'NR == 1 { print $6 }')
      else
        home_candidate=$(awk -F: -v uid="$(id -u)" '$3 == uid { print $6; exit }' /etc/passwd)
      fi
      ;;
  esac
  [[ -n "$home_candidate" && -d "$home_candidate" ]] ||
    pki_die 'cannot identify the current user home directory'
  PKI_CURRENT_USER_HOME=$(cd -P -- "$home_candidate" 2>/dev/null && pwd -P) ||
    pki_die 'cannot resolve the current user home directory'
}

pki_resolve_current_user_home

pki_require_command() {
  command -v "$1" >/dev/null 2>&1 || pki_die "required command not found: $1"
}

pki_require_regular_file() {
  local path=$1
  local label=$2
  [[ ! -L "$path" && -f "$path" ]] || pki_die "$label must be a regular, non-symlink file"
}

pki_file_mode() {
  local path=$1
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$path" ;;
    *) stat -c '%a' "$path" ;;
  esac
}

pki_file_uid() {
  local path=$1
  case "$(uname -s)" in
    Darwin) stat -f '%u' "$path" ;;
    *) stat -c '%u' "$path" ;;
  esac
}

pki_path_is_equal_or_descendant() {
  local candidate=$1
  local base=$2
  [[ "$candidate" == "$base" || "$candidate" == "$base/"* ]]
}

pki_resolve_existing_directory() {
  local directory=$1
  local label=$2
  local logical
  local physical

  [[ ! -L "$directory" && -d "$directory" ]] || pki_die "$label must be a real directory"
  logical=$(cd -L -- "$directory" 2>/dev/null && pwd -L) ||
    pki_die "cannot resolve $label"
  physical=$(cd -P -- "$directory" 2>/dev/null && pwd -P) ||
    pki_die "cannot resolve $label"
  [[ "$logical" == "$physical" ]] || pki_die "$label path must not contain symlinks"
  PKI_VALIDATED_DIRECTORY=$physical
}

pki_assert_private_directory_boundary() {
  local directory=$1
  local label=$2
  local current_directory

  current_directory=$(pwd -P)

  [[ "$directory" != '/' ]] || pki_die "$label must not be the filesystem root"
  [[ "$directory" != "$current_directory" ]] || pki_die "$label must not be the current working directory"
  [[ "$directory" != "$PKI_CURRENT_USER_HOME" ]] || pki_die "$label must not be the user home directory"
  if pki_path_is_equal_or_descendant "$directory" "$PKI_REPOSITORY_ROOT"; then
    pki_die "$label must resolve outside the Git repository"
  fi
}

pki_require_owned_private_directory() {
  local directory=$1
  local label=$2

  [[ $(pki_file_uid "$directory") == "$(id -u)" ]] ||
    pki_die "$label must be owned by the current user"
  [[ $(pki_file_mode "$directory") == '700' ]] ||
    pki_die "$label mode must already be 0700"
}

pki_validate_existing_private_directory() {
  local directory=$1
  local label=$2

  pki_resolve_existing_directory "$directory" "$label"
  pki_assert_private_directory_boundary "$PKI_VALIDATED_DIRECTORY" "$label"
  pki_require_owned_private_directory "$PKI_VALIDATED_DIRECTORY" "$label"
}

pki_validate_output_directory() {
  local directory=$1
  local label=$2
  local base
  local parent
  local parent_physical

  [[ -n "$directory" ]] || pki_die "$label must not be empty"
  [[ "$directory" != -* ]] || pki_die "$label must not begin with a hyphen"
  [[ ! -L "$directory" ]] || pki_die "$label must not be a symlink"

  if [[ -e "$directory" ]]; then
    pki_resolve_existing_directory "$directory" "$label"
    pki_assert_private_directory_boundary "$PKI_VALIDATED_DIRECTORY" "$label"
    pki_require_owned_private_directory "$PKI_VALIDATED_DIRECTORY" "$label"
    return
  fi

  base=$(basename -- "$directory")
  parent=$(dirname -- "$directory")
  [[ "$base" != '.' && "$base" != '..' ]] || pki_die "$label must identify a concrete directory"
  pki_resolve_existing_directory "$parent" "$label parent"
  parent_physical=$PKI_VALIDATED_DIRECTORY
  PKI_VALIDATED_DIRECTORY="$parent_physical/$base"
  pki_assert_private_directory_boundary "$PKI_VALIDATED_DIRECTORY" "$label"
}

pki_prepare_output_dir() {
  local directory=$1
  local require_empty=$2
  local expected_physical

  pki_validate_output_directory "$directory" 'output directory'
  expected_physical=$PKI_VALIDATED_DIRECTORY
  if [[ -e "$directory" ]]; then
    if [[ "$require_empty" == 'yes' ]] &&
      find "$directory" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      pki_die 'output directory must be empty'
    fi
  else
    mkdir -m 700 "$directory" || pki_die 'cannot create output directory'
    pki_resolve_existing_directory "$directory" 'created output directory'
    [[ "$PKI_VALIDATED_DIRECTORY" == "$expected_physical" ]] ||
      pki_die 'created output directory resolved to an unexpected path'
    pki_require_owned_private_directory "$PKI_VALIDATED_DIRECTORY" 'created output directory'
  fi
  PKI_VALIDATED_DIRECTORY=$expected_physical
}

pki_assert_absent() {
  local path=$1
  [[ ! -e "$path" && ! -L "$path" ]] || pki_die "refusing to overwrite: $path"
}

pki_new_stage_dir() {
  local output_directory=$1
  mktemp -d "$output_directory/.pki-stage.XXXXXX" || pki_die 'cannot create staging directory'
}

pki_cleanup_stage() {
  local stage=${PKI_STAGE_DIR:-}
  local index
  local published
  if [[ ${PKI_PUBLISH_COMPLETE:-no} != 'yes' ]]; then
    for ((index = 0; index < PKI_PUBLISHED_COUNT; index += 1)); do
      published=${PKI_PUBLISHED_PATHS[index]}
      if [[ ! -L "$published" && -f "$published" ]]; then
        rm -f "$published"
      fi
    done
  fi
  if [[ -n "$stage" && -d "$stage" && "$(basename "$stage")" == .pki-stage.* ]]; then
    rm -rf "$stage"
  fi
  PKI_CA_PASSPHRASE_VALUE=''
  unset PKI_CA_PASSPHRASE_VALUE
}

pki_read_ca_passphrase() {
  local fd=${U60_CA_PASSPHRASE_FD:-3}
  [[ "$fd" =~ ^[0-9]+$ ]] || pki_die 'U60_CA_PASSPHRASE_FD must be a decimal file descriptor'
  ((fd >= 3 && fd <= 255)) || pki_die 'passphrase file descriptor must be between 3 and 255'

  PKI_CA_PASSPHRASE_VALUE=''
  IFS= read -r PKI_CA_PASSPHRASE_VALUE <&"$fd" || true
  [[ ${#PKI_CA_PASSPHRASE_VALUE} -ge 16 ]] || pki_die 'CA passphrase must contain at least 16 characters'
}

pki_openssl_with_passphrase() {
  printf '%s\n' "$PKI_CA_PASSPHRASE_VALUE" | openssl "$@"
}

pki_require_completion_marker() {
  local marker=$1
  local expected=$2
  local label=$3

  pki_require_regular_file "$marker" "$label"
  cmp -s "$marker" <(printf '%s\n' "$expected") || pki_die "$label is missing or invalid"
}

pki_require_disjoint_directories() {
  local first=$1
  local second=$2
  local label=$3

  if pki_path_is_equal_or_descendant "$first" "$second" ||
    pki_path_is_equal_or_descendant "$second" "$first"; then
    pki_die "$label must not be equal, an ancestor or a descendant"
  fi
}

pki_publish_files() {
  local arguments=("$@")
  local index
  local source
  local destination

  (( ${#arguments[@]} > 0 && ${#arguments[@]} % 2 == 0 )) ||
    pki_die 'internal error: staged files must be provided in source/destination pairs'

  PKI_PUBLISHED_PATHS=()
  PKI_PUBLISHED_COUNT=0
  PKI_PUBLISH_COMPLETE=no
  for ((index = 0; index < ${#arguments[@]}; index += 2)); do
    source=${arguments[index]}
    destination=${arguments[index + 1]}
    pki_require_regular_file "$source" 'staged artifact'
    pki_assert_absent "$destination"
  done

  # A hard link publishes each complete staged inode without an overwrite race.
  # The stage is inside the output directory, so both paths are on one filesystem.
  for ((index = 0; index < ${#arguments[@]}; index += 2)); do
    source=${arguments[index]}
    destination=${arguments[index + 1]}
    ln "$source" "$destination" || pki_die "cannot publish without overwrite: $destination"
    PKI_PUBLISHED_PATHS+=("$destination")
    PKI_PUBLISHED_COUNT=${#PKI_PUBLISHED_PATHS[@]}
  done
  PKI_PUBLISH_COMPLETE=yes
}

pki_is_p256_public_key() {
  local public_key=$1
  openssl pkey -pubin -in "$public_key" -text_pub -noout 2>/dev/null |
    grep -Eq 'ASN1 OID: prime256v1|NIST CURVE: P-256'
}

pki_certificate_pin() {
  local certificate=$1
  local digest
  digest=$(
    openssl x509 -in "$certificate" -pubkey -noout |
      openssl pkey -pubin -outform DER 2>/dev/null |
      openssl dgst -sha256 -binary |
      openssl base64 -A
  ) || return 1
  printf 'sha256/%s\n' "$digest"
}
