#!/usr/bin/env bash
#
# Check or deterministically update the pinned release versions of OpenCode
# (including pre-releases/V2) and Omp (latest stable release) across the repo.

set -o errexit   # abort on nonzero exitstatus
set -o nounset   # abort on unbound variable
set -o pipefail  # don't hide errors within pipes

readonly OPENCODE_RELEASES_ATOM_URL="https://github.com/anomalyco/opencode/releases.atom"
readonly OMP_LATEST_URL="https://github.com/can1357/oh-my-pi/releases/latest"
readonly CURL_CONNECT_TIMEOUT=10
readonly CURL_MAX_TIME=30

REPO_ROOT="$(
  cd "$(dirname "${0}")/.."
  pwd
)"
readonly REPO_ROOT
readonly OPENCODE_DOCKERFILE="${REPO_ROOT}/opencode/opencode.Dockerfile"
readonly OMP_DOCKERFILE="${REPO_ROOT}/omp/omp.Dockerfile"
readonly MAKEFILE_PATH="${REPO_ROOT}/Makefile"
readonly AGENTS_MD="${REPO_ROOT}/AGENTS.md"

TMP_WORK_DIR=""

finish() {
  local result=$?
  if [ -n "${TMP_WORK_DIR}" ] && [ -d "${TMP_WORK_DIR}" ]; then
    rm --recursive --force -- "${TMP_WORK_DIR}"
  fi
  exit "${result}"
}
trap finish EXIT ERR

usage() {
  cat <<'HELPMSG'
Usage: update-versions.sh [-a <opencode|omp|all>] [-u] [-v <x.y.z>] [-d <YYYY-MM-DD>] [-h|--help]

Check or deterministically update the pinned release versions for OpenCode and Omp.
  - opencode: latest v* release/pre-release from GitHub Releases feed
  - omp:      latest stable release from GitHub Releases

Modes:
  Check mode (default):
    Prints the latest upstream version(s) to stdout without modifying files.
    Requires -a <opencode|omp|all>.

  Update mode (-u):
    Deterministically updates all pinned version locations across the repository:
      - opencode/opencode.Dockerfile (ARG OPENCODE_VERSION and ARG VERSION)
      - omp/omp.Dockerfile           (ARG OMP_VERSION and ARG VERSION, with 'v' prefix)
      - Makefile                     (local image tags and BASE_IMAGE references)
      - AGENTS.md                    (documented version pins and bump date)
    Defaults to -a all when -a is omitted.

Options:
  -a <agent>    Agent to check or update: "opencode", "omp", or "all"
  -u            Update files in place (deterministic across macOS and Linux)
  -v <version>  Explicit target version (plain <x.y.z> without 'v' prefix);
                valid only with -u and a single agent (-a opencode or -a omp)
  -d <date>     Explicit bump date (YYYY-MM-DD) for AGENTS.md (default: UTC today)
  -h, --help    Show this help message and exit
HELPMSG
}

log_error() {
  local message="${1}"
  printf 'Error: %s\n' "${message}" >&2
}

log_info() {
  local message="${1}"
  printf '%s\n' "${message}" >&2
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
  [ "${agent}" = "opencode" ] || [ "${agent}" = "omp" ] || [ "${agent}" = "all" ]
}

is_agent_targeted() {
  local selected_agent="${1}"
  local candidate="${2}"
  [ "${selected_agent}" = "${candidate}" ] || [ "${selected_agent}" = "all" ]
}

is_valid_version() {
  local version="${1}"
  case "${version}" in
    v*|"") return 1 ;;
    *)
      printf '%s\n' "${version}" | grep --extended-regexp --quiet '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
      ;;
  esac
}

is_valid_date() {
  local date_str="${1}"
  printf '%s\n' "${date_str}" | grep --extended-regexp --quiet '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
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

  if ! is_valid_version "${version}"; then
    log_error "Could not extract a valid OpenCode version from '${OPENCODE_RELEASES_ATOM_URL}'."
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

  if ! is_valid_version "${clean_version}"; then
    log_error "Extracted invalid version '${clean_version}' from URL '${effective_url}'."
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

read_current_opencode_version() {
  local version=""
  version="$(sed -n 's/^ARG OPENCODE_VERSION=//p' "${OPENCODE_DOCKERFILE}")"
  if ! is_valid_version "${version}"; then
    log_error "Could not read current OPENCODE_VERSION from '${OPENCODE_DOCKERFILE}'."
    return 1
  fi
  printf '%s\n' "${version}"
}

read_current_omp_version() {
  local raw_version=""
  local clean_version=""
  raw_version="$(sed -n 's/^ARG OMP_VERSION=//p' "${OMP_DOCKERFILE}")"
  clean_version="${raw_version#v}"
  if ! is_valid_version "${clean_version}"; then
    log_error "Could not read current OMP_VERSION from '${OMP_DOCKERFILE}'."
    return 1
  fi
  printf '%s\n' "${clean_version}"
}

ensure_temp_dir() {
  if [ -z "${TMP_WORK_DIR}" ]; then
    TMP_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/update-versions.XXXXXX")"
  fi
}

replace_in_file() {
  local file_path="${1}"
  local sed_expr="${2}"
  local tmp_file=""

  ensure_temp_dir
  tmp_file="$(mktemp "${TMP_WORK_DIR}/tmp.XXXXXX")"

  sed "${sed_expr}" "${file_path}" > "${tmp_file}"
  cat "${tmp_file}" > "${file_path}"
}

matches_expected_versions() {
  local expected="${1}"
  local arg_ver="${2}"
  local label_ver="${3}"
  [ "${arg_ver}" = "${expected}" ] && [ "${label_ver}" = "${expected}" ]
}

verify_opencode_files() {
  local expected="${1}"
  local arg_ver=""
  local label_ver=""
  local make_count=""
  local agents_count=""

  arg_ver="$(sed -n 's/^ARG OPENCODE_VERSION=//p' "${OPENCODE_DOCKERFILE}")"
  label_ver="$(sed -n 's/^ARG VERSION=//p' "${OPENCODE_DOCKERFILE}")"
  make_count="$(grep --count --fixed-strings "agent-box-opencode:${expected}" "${MAKEFILE_PATH}" || true)"
  agents_count="$(grep --count --fixed-strings -- "- OpenCode \`${expected}\` — \`ARG OPENCODE_VERSION\`" "${AGENTS_MD}" || true)"

  if ! matches_expected_versions "${expected}" "${arg_ver}" "${label_ver}"; then
    log_error "Verification failed in '${OPENCODE_DOCKERFILE}' (expected ${expected}, got OPENCODE_VERSION=${arg_ver}, VERSION=${label_ver})."
    return 1
  fi

  if [ "${make_count}" -ne 4 ]; then
    log_error "Verification failed in '${MAKEFILE_PATH}': expected 4 occurrences of 'agent-box-opencode:${expected}', found ${make_count}."
    return 1
  fi

  if [ "${agents_count}" -ne 1 ]; then
    log_error "Verification failed in '${AGENTS_MD}': expected OpenCode pin '${expected}'."
    return 1
  fi
}

verify_omp_files() {
  local expected="${1}"
  local expected_v="v${expected}"
  local arg_ver=""
  local label_ver=""
  local make_count=""
  local agents_count=""

  arg_ver="$(sed -n 's/^ARG OMP_VERSION=//p' "${OMP_DOCKERFILE}")"
  label_ver="$(sed -n 's/^ARG VERSION=//p' "${OMP_DOCKERFILE}")"
  make_count="$(grep --count --fixed-strings "agent-box-omp:${expected}" "${MAKEFILE_PATH}" || true)"
  agents_count="$(grep --count --fixed-strings -- "- omp \`${expected_v}\` — \`ARG OMP_VERSION\`" "${AGENTS_MD}" || true)"

  if ! matches_expected_versions "${expected_v}" "${arg_ver}" "${label_ver}"; then
    log_error "Verification failed in '${OMP_DOCKERFILE}' (expected ${expected_v}, got OMP_VERSION=${arg_ver}, VERSION=${label_ver})."
    return 1
  fi

  if [ "${make_count}" -ne 4 ]; then
    log_error "Verification failed in '${MAKEFILE_PATH}': expected 4 occurrences of 'agent-box-omp:${expected}', found ${make_count}."
    return 1
  fi

  if [ "${agents_count}" -ne 1 ]; then
    log_error "Verification failed in '${AGENTS_MD}': expected omp pin '${expected_v}'."
    return 1
  fi
}

update_bump_date() {
  local bump_date="${1}"
  local date_count=""

  replace_in_file "${AGENTS_MD}" "s/^Currently, pinned releases (bumped [0-9-]*):$/Currently, pinned releases (bumped ${bump_date}):/"

  date_count="$(grep --count --fixed-strings "Currently, pinned releases (bumped ${bump_date}):" "${AGENTS_MD}" || true)"
  if [ "${date_count}" -ne 1 ]; then
    log_error "Verification failed in '${AGENTS_MD}': could not update bump date to '${bump_date}'."
    return 1
  fi
}

apply_opencode_update() {
  local target_version="${1}"
  local current_version=""

  current_version="$(read_current_opencode_version)"
  if [ "${current_version}" = "${target_version}" ]; then
    log_info "opencode is already at ${target_version}."
    verify_opencode_files "${target_version}"
    return 1
  fi

  replace_in_file "${OPENCODE_DOCKERFILE}" "s/^ARG OPENCODE_VERSION=.*/ARG OPENCODE_VERSION=${target_version}/"
  replace_in_file "${OPENCODE_DOCKERFILE}" "s/^ARG VERSION=.*/ARG VERSION=${target_version}/"
  replace_in_file "${MAKEFILE_PATH}" "s/agent-box-opencode:[0-9][0-9A-Za-z._-]*/agent-box-opencode:${target_version}/g"
  replace_in_file "${AGENTS_MD}" "s/^- OpenCode \`[^\`]*\` — \`ARG OPENCODE_VERSION\`/- OpenCode \`${target_version}\` — \`ARG OPENCODE_VERSION\`/"

  verify_opencode_files "${target_version}"
  log_info "Updated opencode: ${current_version} -> ${target_version}"
  return 0
}

apply_omp_update() {
  local target_version="${1}"
  local current_version=""

  current_version="$(read_current_omp_version)"
  if [ "${current_version}" = "${target_version}" ]; then
    log_info "omp is already at ${target_version}."
    verify_omp_files "${target_version}"
    return 1
  fi

  replace_in_file "${OMP_DOCKERFILE}" "s/^ARG OMP_VERSION=.*/ARG OMP_VERSION=v${target_version}/"
  replace_in_file "${OMP_DOCKERFILE}" "s/^ARG VERSION=.*/ARG VERSION=v${target_version}/"
  replace_in_file "${MAKEFILE_PATH}" "s/agent-box-omp:[0-9][0-9A-Za-z._-]*/agent-box-omp:${target_version}/g"
  replace_in_file "${AGENTS_MD}" "s/^- omp \`v[^\`]*\` — \`ARG OMP_VERSION\`/- omp \`v${target_version}\` — \`ARG OMP_VERSION\`/"

  verify_omp_files "${target_version}"
  log_info "Updated omp: ${current_version} -> ${target_version}"
  return 0
}

run_check_mode() {
  local agent="${1}"
  local version=""

  case "${agent}" in
    opencode|omp)
      version="$(fetch_latest_version "${agent}")"
      printf '%s\n' "${version}"
      ;;
    all)
      printf 'opencode=%s\n' "$(fetch_latest_version opencode)"
      printf 'omp=%s\n' "$(fetch_latest_version omp)"
      ;;
  esac
}

resolve_target_version() {
  local agent="${1}"
  local explicit_version="${2}"
  if [ -n "${explicit_version}" ]; then
    printf '%s\n' "${explicit_version}"
  else
    fetch_latest_version "${agent}"
  fi
}

run_update_mode() {
  local agent="${1}"
  local explicit_version="${2}"
  local bump_date="${3}"
  local target_oc=""
  local target_omp=""
  local changed=0

  if is_agent_targeted "${agent}" "opencode"; then
    target_oc="$(resolve_target_version opencode "${explicit_version}")"
    if apply_opencode_update "${target_oc}"; then
      changed=1
    fi
  fi

  if is_agent_targeted "${agent}" "omp"; then
    target_omp="$(resolve_target_version omp "${explicit_version}")"
    if apply_omp_update "${target_omp}"; then
      changed=1
    fi
  fi

  if [ "${changed}" -eq 1 ]; then
    update_bump_date "${bump_date}"
  fi
}

validate_explicit_version() {
  local explicit_version="${1}"
  local update_mode="${2}"
  local selected_agent="${3}"

  if [ -z "${explicit_version}" ]; then
    return 0
  fi

  if [ "${update_mode}" -eq 0 ]; then
    log_error "Option -v <version> requires -u (update mode)."
    usage >&2
    return 1
  fi

  if [ "${selected_agent}" = "all" ]; then
    log_error "Option -v <version> requires a single agent (-a opencode or -a omp)."
    usage >&2
    return 1
  fi

  if ! is_valid_version "${explicit_version}"; then
    log_error "Invalid version '${explicit_version}'. Must be plain <x.y.z> without a 'v' prefix."
    return 1
  fi
}

resolve_bump_date() {
  local bump_date="${1}"
  if [ -z "${bump_date}" ]; then
    date -u +%Y-%m-%d
    return 0
  fi
  if ! is_valid_date "${bump_date}"; then
    log_error "Invalid date '${bump_date}'. Expected YYYY-MM-DD."
    return 1
  fi
  printf '%s\n' "${bump_date}"
}

main() {
  if help_wanted "$@"; then
    usage
    exit 0
  fi

  local selected_agent=""
  local update_mode=0
  local explicit_version=""
  local bump_date=""
  local opt=""

  while getopts ":a:uv:d:h" opt; do
    case "${opt}" in
      a)
        selected_agent="${OPTARG}"
        ;;
      u)
        update_mode=1
        ;;
      v)
        explicit_version="${OPTARG}"
        ;;
      d)
        bump_date="${OPTARG}"
        ;;
      h)
        usage
        exit 0
        ;;
      :)
        log_error "Option -${OPTARG} requires an argument."
        usage >&2
        exit 1
        ;;
      \?)
        log_error "Unknown option: -${OPTARG}."
        usage >&2
        exit 1
        ;;
    esac
  done

  shift $((OPTIND - 1))

  if [ "$#" -gt 0 ]; then
    log_error "Unexpected positional argument: '${1}'."
    usage >&2
    exit 1
  fi

  if [ "${update_mode}" -eq 1 ] && [ -z "${selected_agent}" ]; then
    selected_agent="all"
  fi

  if [ -z "${selected_agent}" ]; then
    log_error "Missing required option: -a <opencode|omp|all>."
    usage >&2
    exit 1
  fi

  if ! is_supported_agent "${selected_agent}"; then
    log_error "Invalid agent '${selected_agent}'. Must be 'opencode', 'omp', or 'all'."
    usage >&2
    exit 1
  fi

  validate_explicit_version "${explicit_version}" "${update_mode}" "${selected_agent}"
  bump_date="$(resolve_bump_date "${bump_date}")"

  if [ "${update_mode}" -eq 1 ]; then
    run_update_mode "${selected_agent}" "${explicit_version}" "${bump_date}"
  else
    run_check_mode "${selected_agent}"
  fi
}

main "$@"
