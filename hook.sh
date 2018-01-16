#!/bin/bash

set -euo pipefail

export LC_ALL=C


die() {
    echo "error: $@"
    exit 1
}


get_delegated_domain() {
    local domain="${1}"
    while test "${domain#*.}" != "${domain}"; do
        if host -t NS "${domain}" | grep -i "cloudns.net" &> /dev/null; then
            echo "${domain}"
            return 0
        else
            domain="${domain#*.}"
        fi
    done
    return 1
}


get_prefix() {
    local domain="$(get_delegated_domain ${1})"
    test -z "${domain}" && return 1
    test "${domain}" = "${1}" && return 0
    echo "${1%*.${domain}}"
}


do_request() {
    test -z "${CLOUDNS_AUTH_ID}" && return 1
    test -z "${CLOUDNS_AUTH_PASSWORD}" && return 1
    local args="auth-id=${CLOUDNS_AUTH_ID}&auth-password=${CLOUDNS_AUTH_PASSWORD}&${2}"
    curl \
        --silent \
        --show-error \
        "https://api.cloudns.net${1}?${args}"
}


deploy_challenge() {
    echo " + cloudns hook executing: deploy_challenge"
    local prefix="$(get_prefix ${1})" domain="$(get_delegated_domain ${1})"
    test -z "${domain}" && return 1
    echo "  + creating TXT record for ${1}"
    do_request \
        /dns/add-record.json \
        "domain-name=${domain}&record-type=TXT&host=_acme-challenge${prefix:+.${prefix}}&record=${3}&ttl=60" \
        | grep -i success &> /dev/null
    echo "  + waiting for propagation ..."
    sleep 5
    while ! do_request /dns/is-updated.json "domain-name=${domain}" | grep -i true &> /dev/null; do
        echo "  + waiting for propagation ..."
        sleep 30
    done
}


clean_challenge() {
    echo " + cloudns hook executing: clean_challenge"
    local prefix="$(get_prefix ${1})" domain="$(get_delegated_domain ${1})"
    test -z "${domain}" && return 1
    echo "  + retrieving TXT record for ${1}"
    local txt_id=$(
        do_request \
            /dns/records.json \
            "domain-name=${domain}" \
            | jq -r \
                "to_entries | map(.value) | .[] | select(.type == \"TXT\" and .host == \"_acme-challenge${prefix:+.${prefix}}\") | .id"
    )
    test -z "${txt_id}" && return 1
    echo "  + cleaning TXT record for ${1}"
    do_request \
        /dns/delete-record.json \
        "domain-name=${domain}&record-id=${txt_id}" \
        | grep -i success &> /dev/null
}

invalid_challenge() {
    # This hook is called if the challenge response has failed, so domain
    # owners can be aware and act accordingly.
    local DOMAIN="${1}" RESPONSE="${2}"
}

startup_hook() {
  # This hook is called before the cron command to do some initial tasks
  # (e.g. starting a webserver).

  :
}

exit_hook() {
  # This hook is called at the end of the cron command and can be used to
  # do some final (cleanup or other) tasks.

  :
}

HANDLER="$1"; shift
if [[ "${HANDLER}" =~ ^(deploy_challenge|clean_challenge|deploy_cert|unchanged_cert|invalid_challenge|request_failure|startup_hook|exit_hook)$ ]]; then
  "$HANDLER" "$@"
fi