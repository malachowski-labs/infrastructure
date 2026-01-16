#!/usr/bin/env bash

help() {
    echo "Fetch Secrets Script"
    echo "Script is used to expose secrets from a Google Cloud Secret Manager."
    echo "It should be run in a development only"
    echo "==============================="
    echo
    echo "Usage: fetch-secrets.sh [-h|r|w]"
    echo "  -h  Display this help message"
    echo "  -r  Get read-only secrets"
    echo "  -w  Get write-enabled secrets"
}

fetch-readonly-secrets() {
    # Add logic to fetch read-only secrets from Google Cloud Secret Manager
    CLOUDFLARE_API_TOKEN=$(gcloud secrets versions access latest --secret="cloudflare-read-token")
    HCLOUD_TOKEN=$(gcloud secrets versions access latest --secret="infra-planner-hcloud-token")

    export CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
    export HCLOUD_TOKEN=$HCLOUD_TOKEN
    echo "Read-only secrets fetched and exported as environment variables."
}

fetch-writeenabled-secrets() {
    CLOUDFLARE_API_TOKEN=$(gcloud secrets versions access latest --secret="cloudflare-manager-executor")
    HCLOUD_TOKEN=$(gcloud secrets versions access latest --secret="infra-executor-hcloud-token")

    export CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
    export HCLOUD_TOKEN=$HCLOUD_TOKEN
    echo "Write-enabled secrets fetched and exported as environment variables."
}

abort() {
    local code="${1:-1}"
    echo "Aborting script with exit code ${code}."

    if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
        echo "Script is being sourced. Returning to caller."
        return "${code}"
    else
        echo "Script is being executed. Exiting."
        exit "${code}"
    fi
}

while getopts ":hrw" option; do
    case $option in
        h) # display help
            help
            abort 0;;
        w) # fetch write-enabled secrets
            echo "Fetching write-enabled secrets..."
            fetch-writeenabled-secrets
            abort 0;;
        r) # fetch read-only secrets
            echo "Fetching read-only secrets..."
            fetch-readonly-secrets
            abort 0;;
        \?) # invalid option
            echo "Error: Invalid option"
            help
            abort 1;;
    esac
done
