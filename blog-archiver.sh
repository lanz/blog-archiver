#!/bin/bash

# blog-archiver.sh
# Archive Blogspot or WordPress blogs using wget.
# Copyright (c) 2026 lanz (https://github.com/lanz)
# SPDX-License-Identifier: GPL-3.0-or-later

set -o pipefail

VERSION="1.0"

# Terminal colors
BOLD='\033[1m'
CYAN='\033[36m'
RESET='\033[0m'

echo
echo -e "${BOLD}${CYAN}========================================${RESET}"
echo -e "${BOLD}${CYAN}              BLOG ARCHIVER${RESET}"
echo -e "${BOLD}${CYAN}========================================${RESET}"
echo "       Blogspot & WordPress"
echo "       Offline Archive Tool"
echo "              v$VERSION"
echo

read -rp "Blog URL: " blog_url

# Remove trailing slash for easier hostname parsing.
blog_url="${blog_url%/}"

# Make sure the URL has a scheme.
if [[ ! "$blog_url" =~ ^https?:// ]]; then
    echo
    echo "Error: URL must begin with http:// or https://"
    exit 1
fi

# Extract hostname.
hostname=$(printf '%s\n' "$blog_url" |
    sed -E 's|^https?://([^/:]+).*|\1|' |
    tr '[:upper:]' '[:lower:]')

if [[ -z "$hostname" ]]; then
    echo
    echo "Error: Could not determine hostname from URL."
    exit 1
fi

# Detect blog platform
case "$hostname" in

    *.blogspot.com|*.blogspot.*|blogspot.com)
        blog_type="blogspot"
        ;;

    *.wordpress.com|wordpress.com)
        blog_type="wordpress"
        ;;

    *)
        echo
        echo "Could not automatically determine the blog platform."
        echo
        echo "1) Blogspot"
        echo "2) WordPress"
        echo

        read -rp "Blog type [1-2]: " choice

        case "$choice" in
            1)
                blog_type="blogspot"
                ;;
            2)
                blog_type="wordpress"
                ;;
            *)
                echo
                echo "Invalid selection."
                exit 1
                ;;
        esac
        ;;
esac

# Set up archive directory
archive_root="archives"
archive_dir="$archive_root/$hostname"

if ! mkdir -p "$archive_dir"; then
    echo
    echo "Error: Could not create archive directory:"
    echo "  $archive_dir"
    exit 1
fi

log_file="$archive_dir/wget.log"

echo
echo "Detected platform : $blog_type"
echo "Blog URL           : $blog_url"
echo "Archive directory  : $archive_dir"
echo

read -rp "Start archive? [Y/n]: " confirm

if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo
    echo "Archive cancelled."
    exit 0
fi

echo

# Archive blog
case "$blog_type" in

    blogspot)

        echo "Archiving Blogspot blog..."
        echo

        blogspoturl="$blog_url/"
        cookie_file="$archive_root/.${hostname}.cookies.txt"

        # Obtain Blogger guest authentication cookies.
        echo "Obtaining Blogger session cookies..."

        wget -O - \
            "https://blogger.com/blogin.g?blogspotURL=$blogspoturl" |
            grep guestAuth |
            cut -d'"' -f 4 |
            wget -i - \
                --save-cookies "$cookie_file" \
                --keep-session-cookies

        cookie_status=$?

        if [[ $cookie_status -ne 0 || ! -f "$cookie_file" ]]; then
            echo
            echo "Warning: Blogger authentication cookies could not be obtained."
            echo "Continuing with the archive anyway..."
            echo
        fi

        # Download Blogspot blog.
        (
            cd "$archive_dir" || exit 1

            wget \
                --load-cookies "../.${hostname}.cookies.txt" \
                --recursive \
                --level=2 \
                --no-clobber \
                --no-parent \
                --page-requisites \
                --continue \
                --convert-links \
                --no-host-directories \
                --user-agent="" \
                -e robots=off \
                --reject "*\\?*,*@*" \
                --exclude-directories="/search,/feeds" \
                --referer="$blogspoturl" \
                --wait=1 \
                "$blogspoturl" 2>&1 | tee "wget.log"
        )

        status=$?

        # Remove temporary cookies.
        rm -f "$cookie_file"
        ;;

    wordpress)

        echo "Archiving WordPress blog..."
        echo

        (
            cd "$archive_dir" || exit 1

            wget \
                --mirror \
                --page-requisites \
                --adjust-extension \
                --convert-links \
                --no-host-directories \
                --no-parent \
                --wait=1 \
                --limit-rate=20k \
                --exclude-directories="feed,wp-json,search,comments" \
                --reject-regex="\/\\?(s|replytocom|share)=" \
                -e robots=off \
                "$blog_url/" 2>&1 | tee "wget.log"
        )

        status=$?
        ;;

    *)
        echo "Error: Unknown blog type: $blog_type"
        exit 1
        ;;

esac

echo

if [[ $status -eq 0 ]]; then
    echo "========================================"
    echo "Archive complete!"
    echo "========================================"
    echo
    echo "Archive : $archive_dir"
    echo "Log     : $log_file"
else
    echo "========================================"
    echo "Archive completed with errors."
    echo "========================================"
    echo
    echo "Partial archive : $archive_dir"
    echo "Log             : $log_file"
fi

exit "$status"