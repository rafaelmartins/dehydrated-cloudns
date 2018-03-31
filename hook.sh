#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C


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
    CLOUDNS_AUTH_ID="${CLOUDNS_AUTH_ID-}"
    test -z "${CLOUDNS_AUTH_ID}" && test -z "${CLOUDNS_SUB_AUTH_ID}" && return 1
    test -z "${CLOUDNS_AUTH_PASSWORD}" && return 1
    local args=""
    if test -n "${CLOUDNS_AUTH_ID}"; then
      args="auth-id=${CLOUDNS_AUTH_ID}"
    else
      args="sub-auth-id=${CLOUDNS_SUB_AUTH_ID}"
    fi
    args="${args}&auth-password=${CLOUDNS_AUTH_PASSWORD}&${2}"
    curl \
        --silent \
        "https://api.cloudns.net${1}?${args}"
}


deploy_challenge() {
    echo " + cloudns hook executing: deploy_challenge"
    local prefix="$(get_prefix ${1})" domain="$(get_delegated_domain ${1})"
    test -z "${domain}" && return 1
    echo "  + creating TXT record for ${1}"
    do_request \
        /dns/add-record.json \
        "domain-name=${domain}&record-type=TXT&host=_acme-challenge${prefix:+.${prefix}}&record=${2}&ttl=60" \
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
                "to_entries | map(.value) | .[] | select(.type == \"TXT\" and .host == \"_acme-challenge${prefix:+.${prefix}}\" and .record == \"${2}\") | .id"
    )
    test -z "${txt_id}" && return 1
    echo "  + cleaning TXT record for ${1}"
    for record in ${txt_id}; do
        do_request \
            /dns/delete-record.json \
            "domain-name=${domain}&record-id=${record}" \
            | grep -i success &> /dev/null
    done
}


case "${1:-}" in
    deploy_challenge)
        deploy_challenge "${2}" "${4}"
        ;;
    clean_challenge)
        clean_challenge "${2}" "${4}"
        ;;
esac
