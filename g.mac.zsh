typeset -g _G_MAC_SCRIPT="${${(%):-%x}:A:h}/g.mac.py"

function g {
    if [[ ! -f "$_G_MAC_SCRIPT" ]]; then
        print -u2 "g: macOS script not found: $_G_MAC_SCRIPT"
        return 1
    fi

    local result_file
    result_file="$(mktemp "${TMPDIR:-/tmp}/g.XXXXXX")" || return 1
    python3 "$_G_MAC_SCRIPT" "$result_file"
    local exit_code=$?
    local destination
    if (( exit_code == 0 )); then
        IFS= read -r destination < "$result_file"
        if [[ -n "$destination" ]]; then
            cd -- "$destination" || exit_code=$?
        fi
    fi
    command rm -f -- "$result_file"
    return $exit_code
}
