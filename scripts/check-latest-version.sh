#!/usr/bin/env bash
#
# Retrieve the latest release version of OpenCode (including pre-releases/V2)
# or Omp (latest stable release) from GitHub.

set -o errexit   # abort on nonzero exitstatus
set -o nounset   # abort on unbound variable
set -o pipefail  # don't hide errors within pipes

readonly OPENCODE_RELEASES_ATOM_URL="https://github.com/anomalyco/opencode/releases.atom"
readonly OMP_LATEST_URL="https://github.com/can1357/oh-my-pi/releases/latest"
readonly CURL_CONNECT_TIMEOUT=10
readonly CURL_MAX_TIME=30

finish() {
  local result=$?
  exit "${result}"
}
trap finish EXIT ERR

usage() {
  cat <<'HELPMSG'
Usage: check-latest-version.sh -a <opencode|omp> [-h|--help]

Fetch the latest release version (plain semver) for OpenCode or Omp.
  - opencode: latest v* release/pre-release from GitHub Releases feed
  - omp:      latest stable release from GitHub Releases

Options:
  -a <agent>    Agent to check: "opencode" or "omp" (required)
  -h, --help    Show this help message and exit
HELPMSG
}

log_error() {
  local message="${1}"
  printf 'Error: %s\n' "${message}" >&2
}

help_wanted() {
  local arg=""
  for arg in "$@"; do
    if [ "${arg}" = "-h" ] || [ "${arg}" = "--help" ] || [ "${arg}" = "-?" ]; then
      return 0
    fi
  done
  return 1
}

is_supported_agent() {
  local agent="${1}"
  [ "${agent}" = "opencode" ] || [ "${agent}" = "omp" ]
}

is_tag_redirect_url() {
  local effective_url="${1}"
  case "${effective_url}" in
    */releases/tag/*) return 0 ;;
    *) return 1 ;;
  esac
}

fetch_opencode_latest_version() {
  local atom_feed=""
  local version=""

  atom_feed="$(
    curl \
      --fail \
      --silent \
      --show-error \
      --location \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      -- "${OPENCODE_RELEASES_ATOM_URL}"
  )"

  version="$(
    printf '%s\n' "${atom_feed}" \
      | sed -n 's|.*/releases/tag/v\([0-9][^"?#]*\)".*|\1|p' \
      | head -n 1
  )"

  if [ -z "${version}" ]; then
    log_error "Could not extract OpenCode version from '${OPENCODE_RELEASES_ATOM_URL}'."
    return 1
  fi

  printf '%s\n' "${version}"
}

fetch_omp_latest_version() {
  local effective_url=""
  local raw_tag=""
  local clean_version=""

  effective_url="$(
    curl \
      --fail \
      --silent \
      --show-error \
      --location \
      --head \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      --output /dev/null \
      --write-out '%{url_effective}' \
      -- "${OMP_LATEST_URL}"
  )"

  if ! is_tag_redirect_url "${effective_url}"; then
    log_error "Unexpected redirect URL: '${effective_url}'."
    return 1
  fi

  raw_tag="${effective_url##*/releases/tag/}"
  raw_tag="${raw_tag%%[?#]*}"
  clean_version="${raw_tag#v}"

  if [ -z "${clean_version}" ]; then
    log_error "Extracted version is empty from URL '${effective_url}'."
    return 1
  fi

  printf '%s\n' "${clean_version}"
}

fetch_latest_version() {
  local agent="${1}"

  case "${agent}" in
    opencode)
      fetch_opencode_latest_version
      ;;
    omp)
      fetch_omp_latest_version
      ;;
    *)
      log_error "Unsupported agent '${agent}'. Expected 'opencode' or 'omp'."
      return 1
      ;;
  esac
}

parse_args() {
  local selected_agent=""
  local opt=""

  while getopts ":a:h" opt; do
    case "${opt}" in
      a)
        selected_agent="${OPTARG}"
        ;;
      h)
        usage
        exit 0
        ;;
      :)
        log_error "Option -${OPTARG} requires an argument."
        usage >&2
        return 1
        ;;
      \?)
        log_error "Unknown option: -${OPTARG}."
        usage >&2
        return 1
        ;;
    esac
  done

  shift $((OPTIND - 1))

  if [ "$#" -gt 0 ]; then
    log_error "Unexpected positional argument: '${1}'."
    usage >&2
    return 1
  fi

  if [ -z "${selected_agent}" ]; then
    log_error "Missing required option: -a <opencode|omp>."
    usage >&2
    return 1
  fi

  if ! is_supported_agent "${selected_agent}"; then
    log_error "Invalid agent '${selected_agent}'. Must be 'opencode' or 'omp'."
    usage >&2
    return 1
  fi

  printf '%s\n' "${selected_agent}"
}

main() {
  if help_wanted "$@"; then
    usage
    exit 0
  fi

  local agent=""
  local latest_version=""

  agent="$(parse_args "$@")"
  latest_version="$(fetch_latest_version "${agent}")"

  printf '%s\n' "${latest_version}"
}

main "$@"
