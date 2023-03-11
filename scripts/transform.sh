#!/bin/bash
set -e

INPUT_FILE="$(mktemp)"
TRANSFORM_FILE="$(mktemp)"
OUTPUT_FILE="$(mktemp)"

# Set WITHIN_DOCKER variable to true if DOCKER_EPP_BIORXIV_XSLT is set
if [[ -n "${DOCKER_EPP_BIORXIV_XSLT}" ]]; then
    WITHIN_DOCKER=true
else
    WITHIN_DOCKER=false
fi

usage() {
    echo "Usage: $0 [-d|--doi DOI] [XSL_FILE]"
    exit 1
}

XSL_FILE=""
DOI=""
SESSION_LOG_FILE=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--doi)
            DOI="$2"
            shift 2
            ;;
        -l|--log)
            SESSION_LOG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            if [[ -z "$XSL_FILE" ]]; then
                XSL_FILE="$1"
            else
                echo "Unexpected parameter: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

# Get the directory where the script is located
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
PARENT_DIR="$(dirname "${SCRIPT_DIR}")"

cd "${PARENT_DIR}"

function write_to_log() {
    if [[ -n "${SESSION_LOG_FILE}" ]]; then
        touch "${SESSION_LOG_FILE}"
        echo "$(date +"%Y-%m-%d %H:%M:%S"): ${1}" >> "${SESSION_LOG_FILE}"
    fi
}

function write_to_log_xslt() {
    if diff -w -u "${2}" "${3}" >/dev/null; then
        local change_log="no change applied"
    else
        local change_log="changed"
    fi

    write_to_log "(DOI: ${DOI}) - ${1} ${change_log}"
}

function transform_xml() {
    local xslt_output=$(mktemp)

    if [[ "${WITHIN_DOCKER}" == "true" ]]; then
        /usr/local/bin/apply-xslt "${1}" "${2}" > "${xslt_output}"
    else
        # Check if Docker image exists
        if [[ "$(docker images -q epp-biorxiv-xslt 2> /dev/null)" == "" ]]; then
            # Build Docker image
            docker buildx build -t epp-biorxiv-xslt .
        fi

        docker run --rm -v "${PARENT_DIR}/src:/app" -v "${1}:/input.xml" -v "${2}:/stylesheet.xsl" epp-biorxiv-xslt /usr/local/bin/apply-xslt /input.xml /stylesheet.xsl > "${xslt_output}"
    fi

    write_to_log_xslt "${2}" "${1}" "${xslt_output}"

    cat "${xslt_output}"

    rm -f "${xslt_output}"
}

# Preserve hexadecimal notation
cat /dev/stdin | sed -E "s/&#x([0-9A-F]{4});/HEX\1NOTATION/g" > "${INPUT_FILE}"

if [ ! -s "${INPUT_FILE}" ]; then
    echo "Error: Input XML is empty" >&2
    exit 1
fi

# Apply XSLT transform
if [[ -z "${XSL_FILE}" ]]; then
    # Apply XSLT transform to all XSL files in src/all folder
    for xsl_file in $PARENT_DIR/src/*.xsl; do
        transform_xml "${INPUT_FILE}" "${xsl_file}" > "${TRANSFORM_FILE}"
        cat "${TRANSFORM_FILE}" > "${INPUT_FILE}"
    done
    if [[ -n "${DOI}" ]]; then
        # Apply XSLT transform to all XSL files in src/all folder
        for xsl_file in $PARENT_DIR/src/$DOI/*.xsl; do
            transform_xml "${INPUT_FILE}" "${xsl_file}" > "${TRANSFORM_FILE}"
            cat "${TRANSFORM_FILE}" > "${INPUT_FILE}"
        done
    fi
else
    transform_xml "${INPUT_FILE}" "${XSL_FILE}" > "${TRANSFORM_FILE}"
fi

# Remove empty lines, restore DOCTYPE and restore hexadecimal notation
cat "${TRANSFORM_FILE}" | sed '/^$/d' | sed "s#<?xml version=\"1.0\" encoding=\"UTF-8\"?>#<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE article PUBLIC \"-//NLM//DTD JATS (Z39.96) Journal Archiving and Interchange DTD v1.2d1 20170631//EN\" \"JATS-archivearticle1.dtd\">\n#g" | sed -E "s/HEX([0-9A-F]{4})NOTATION/\&#x\1;/g" > "${OUTPUT_FILE}"

# Append an empty line to the file
echo "" >> "${OUTPUT_FILE}"

cat "${OUTPUT_FILE}"

rm -f "${INPUT_FILE}"
rm -f "${TRANSFORM_FILE}"
rm -f "${OUTPUT_FILE}"
