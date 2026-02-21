# Legacy compatibility shim.
# Source this file to keep `davy` as a shell function that delegates
# to the Rust CLI implementation.

davy() {
  if type -P davy >/dev/null 2>&1; then
    command davy "$@"
    return $?
  fi

  local script_dir
  local script_source
  if [ -n "${BASH_SOURCE[0]-}" ]; then
    script_source="${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION-}" ]; then
    script_source="${(%):-%N}"
  else
    script_source="$0"
  fi
  script_dir="$(cd "$(dirname "${script_source}")" && pwd)"

  if [ -f "${script_dir}/Cargo.toml" ]; then
    (cd "${script_dir}" && cargo run --quiet -- "$@")
    return $?
  fi

  echo "davy: Rust binary not found. Install with: cargo install --path /path/to/davy-repo" >&2
  return 127
}
