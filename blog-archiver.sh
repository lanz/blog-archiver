#!/usr/bin/env bash
#
# blog-archiver.sh - Archive Blogspot, WordPress, and Substack blogs for
# offline viewing.
#
# Copyright (C) 2026 Lance Duvall (https://github.com/lanz)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Requires Bash 3.2+ (the macOS default works) and GNU Wget.
# Run with --help for usage. To add a platform, see "Platforms" below.

set -euo pipefail

readonly VERSION="2.1.0"
readonly PROG="${0##*/}"

# Exit codes. Wget's own exit codes (1-8) are passed through unchanged.
readonly EX_USAGE=64        # bad command line or input
readonly EX_UNAVAILABLE=69  # required tool missing
readonly EX_CANTCREAT=73    # cannot create the archive directory
readonly EX_TEMPFAIL=75     # another run is archiving the same blog

# Regex building blocks.
readonly Q="[\"']"                          # either quote character
readonly RE_ZERO='^0*(\.0*)?$'              # 0, 0.0, 00 ...
readonly RE_ZERO_RATE='^0*(\.0*)?[kKmMgG]?$' # 0, 0k, 0.0m ...

# ---------------------------------------------------------------------------
# Settings (changed by command-line options)
# ---------------------------------------------------------------------------

output_root="${BLOG_ARCHIVER_DIR:-archives}"
blog_url=""          # normalized URL, no trailing slash
blog_host=""         # lowercase hostname
blog_origin=""       # scheme://host[:port]
blog_type=""
wait_seconds="1"
rate_limit=""
depth=""
user_agent=""
user_agent_set=0
use_sitemap=0
max_posts=""
media_hosts=1
all_image_sizes=0
assume_yes=0
dry_run=0
quiet=0
extra_wget_args=()

# Runtime state.
work_dir=""
lock_dir=""
archive_dir=""
log_file=""
cookie_file=""
seed_file=""
platform_source=""
wget_help=""
fetch_args=()
wget_cmd=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

setup_colors() {
    if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        BOLD=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m'
        YELLOW=$'\033[33m' CYAN=$'\033[36m' RESET=$'\033[0m'
    else
        BOLD="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
    fi
}

# All human-facing messages go to stderr.
info()  { [[ $quiet -eq 1 ]] || printf '%s\n' "$*" >&2; }
warn()  { printf '%sWarning:%s %s\n' "$YELLOW$BOLD" "$RESET" "$*" >&2; }
error() { printf '%sError:%s %s\n' "$RED$BOLD" "$RESET" "$*" >&2; }
die()   { error "$1"; exit "${2:-1}"; }

is_interactive() { [[ -t 0 && -t 2 ]]; }

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Sleep for the configured wait between requests (used outside wget).
pause() { [[ $wait_seconds =~ $RE_ZERO ]] || sleep "$wait_seconds"; }

count_lines() {
    local n
    n=$(wc -l 2>/dev/null < "$1") || n=0
    printf '%s' "$((n + 0))"
}

# ===========================================================================
# Platforms
#
# Each platform NAME is listed in PLATFORMS and defines:
#
#   NAME_label           Display name.
#   NAME_aliases         Other names accepted by --type (space-separated).
#   NAME_generator_re    ERE for the platform's <meta name="generator"> tag.
#                        This is strong evidence; leave empty if there is none.
#   NAME_marker_re       ERE for weaker evidence, such as asset URLs.
#   NAME_sitemaps        Sitemap paths to try (after any listed in robots.txt).
#   NAME_media_domains   Comma-separated image/CDN hosts to download from,
#                        or empty. Turned off with --no-media-hosts.
#   NAME_match_host H    Return 0 if hostname H belongs to the platform.
#   NAME_defaults        Fill in unset settings (depth, rate_limit, ...).
#   NAME_wget_args       Append platform-specific options to wget_cmd.
#
# Optional hooks:
#   NAME_prepare         Runs before wget starts (login cookies, etc.).
#   NAME_list_urls FILE  Writes post URLs to FILE when no sitemap is found.
#
# Page detection tries every generator_re first, then every marker_re,
# in PLATFORMS order.
# ===========================================================================

readonly PLATFORMS="blogspot wordpress substack"

# --- Blogspot --------------------------------------------------------------

blogspot_label="Blogspot"
blogspot_aliases="blogger"
blogspot_generator_re="<meta[^>]+content=${Q}blogger${Q}"
blogspot_marker_re='www\.blogger\.com/(static|dyn-css)/|blogblog\.com/'
blogspot_sitemaps="/sitemap.xml"
blogspot_media_domains="bp.blogspot.com,blogger.googleusercontent.com"

blogspot_match_host() {
    case $1 in
        blogspot.com|*.blogspot.com|*.blogspot.*) return 0 ;;
    esac
    return 1
}

blogspot_defaults() {
    depth=${depth:-2}
    # Blogspot has always been archived without a User-Agent header.
    if [[ $user_agent_set -eq 0 ]]; then
        user_agent=""
        user_agent_set=1
    fi
}

# Get Blogger guest-auth cookies. Some Blogspot blogs need them to serve
# full content. Failure is not fatal.
blogspot_prepare() {
    local file="$work_dir/cookies.txt" login_url auth_url re='^https?://'

    login_url="https://blogger.com/blogin.g?blogspotURL=$(urlencode "$blog_url/")"
    info "Getting Blogger session cookies..."

    auth_url=$(wget --quiet --timeout=30 --tries=2 --output-document=- "$login_url" 2>/dev/null |
        grep -m1 guestAuth | cut -d'"' -f4 | sed 's/&amp;/\&/g') || true

    if [[ $auth_url =~ $re ]] &&
        wget --quiet --timeout=30 --tries=2 \
            --output-document="$work_dir/blogin.html" \
            --save-cookies="$file" --keep-session-cookies \
            "$auth_url" 2>/dev/null &&
        grep -q '^[^#]' "$file" 2>/dev/null; then
        cookie_file=$file
    else
        warn "Could not get Blogger session cookies. Continuing without them."
    fi
}

blogspot_wget_args() {
    wget_cmd+=(
        --recursive
        --level="$depth"
        --no-parent
        --referer="$blog_url/"
        --reject='*\?*,*@*'
        --exclude-directories=/search,/feeds
    )
    if [[ -n $cookie_file ]]; then
        wget_cmd+=(--load-cookies="$cookie_file")
    fi
}

# --- WordPress -------------------------------------------------------------

wordpress_label="WordPress"
wordpress_aliases="wp"
wordpress_generator_re="<meta[^>]+content=${Q}WordPress"
wordpress_marker_re='/wp-(content|includes)/'
wordpress_sitemaps="/wp-sitemap.xml /sitemap_index.xml /sitemap.xml"
wordpress_media_domains="files.wordpress.com,i0.wp.com,i1.wp.com,i2.wp.com,i3.wp.com,s0.wp.com,s1.wp.com,s2.wp.com"

wordpress_match_host() {
    case $1 in
        wordpress.com|*.wordpress.com) return 0 ;;
    esac
    return 1
}

wordpress_defaults() {
    depth=${depth:-inf}
    rate_limit=${rate_limit:-20k}
}

wordpress_wget_args() {
    wget_cmd+=(
        --recursive
        --level="$depth"
        --no-parent
        --timestamping
        --adjust-extension
        --reject-regex='/(feed|wp-json|comments|search|embed)(/|$)|/(wp-login|xmlrpc)\.php|[?&](s|replytocom|share)='
    )
}

# --- Substack --------------------------------------------------------------
#
# Substack's /archive page loads its post list with JavaScript, so a normal
# crawl misses most posts. Instead, the post list comes from the sitemap (when
# the publication has one), then the archive API, then the RSS feed. wget then
# downloads each post and its images; it does not crawl further by default.

substack_label="Substack"
substack_aliases=""
substack_generator_re=""
substack_marker_re='substackcdn\.com/'
substack_sitemaps="/sitemap.xml"
substack_media_domains="substackcdn.com,s3.amazonaws.com"

substack_match_host() {
    case $1 in
        *.substack.com) return 0 ;;
    esac
    return 1
}

substack_defaults() {
    depth=${depth:-0}
    use_sitemap=1
}

# Substack's archive API pages with a cursor: /api/v1/archive?sort=new&cursor=X
# It is undocumented and may change, so the RSS feed (recent posts only) is
# the fallback.
substack_list_urls() {
    local out=$1 json="$work_dir/archive.json" cursor="" url before after page=0

    info "Reading the Substack archive..."
    while [[ $page -lt 2000 ]]; do
        url="$blog_origin/api/v1/archive?sort=new"
        [[ -z $cursor ]] || url="$url&cursor=$(urlencode "$cursor")"
        fetch "$url" "$json" || break

        before=$(count_lines "$out")
        { grep -o '"canonical_url":"[^"]*"' "$json" || true; } |
            cut -d'"' -f4 | sed 's#\\/#/#g' | grep '/p/' >> "$out" || true
        after=$(count_lines "$out")
        [[ $after -gt $before ]] || break
        if [[ -n $max_posts && $after -ge $max_posts ]]; then break; fi

        cursor=$(grep -o '"nextCursor":"[^"]*"' "$json" | cut -d'"' -f4) || cursor=""
        [[ -n $cursor ]] || break
        page=$((page + 1))
        if [[ $quiet -eq 0 && $((page % 10)) -eq 0 ]]; then
            info "  ...$after posts so far"
        fi
        pause
    done

    if [[ ! -s $out ]]; then
        warn "The Substack archive API did not respond. Using the RSS feed, which lists only recent posts."
        if fetch "$blog_origin/feed" "$work_dir/feed.xml"; then
            { tr '\n' ' ' < "$work_dir/feed.xml" | grep -o '<link>[^<]*</link>' || true; } |
                sed 's#</*link>##g' | grep '/p/' >> "$out" || true
        fi
    fi
    [[ -s $out ]]
}

substack_wget_args() {
    local level=$depth
    # With no post list, at least follow the links on the front page.
    if [[ -z $seed_file && $level == "0" ]]; then
        level=1
    fi
    if [[ $level != "0" ]]; then
        wget_cmd+=(--recursive --level="$level" --no-parent)
    fi
    local reject='/(action|publish|sign-in|subscribe|channel-frame|lovestack)(/|$|\?)|/p/[^/]+/comment/'
    # Pages show w_1456 post images and small fixed-size thumbnails; srcset
    # lists extra widths of each (up to 5 copies, some 10+ MB GIFs). Skip those.
    if [[ $all_image_sizes -eq 0 ]]; then
        reject="$reject"'|/image/fetch/[^/]*,w_(424|848|1272),c_limit|/image/fetch/[^/]*,w_(424|640|848|960),h_[0-9]+'
    fi
    wget_cmd+=(
        --adjust-extension
        --reject-regex="$reject"
        "$blog_origin/archive"
        "$blog_origin/about"
    )
}

# --- Platform helpers ------------------------------------------------------

# platform_var NAME FIELD -> print the value of NAME_FIELD.
platform_var() {
    local var="${1}_$2"
    printf '%s' "${!var}"
}

# platform_hook NAME HOOK [ARGS...] -> run NAME_HOOK if it is defined.
has_hook() { declare -F "${1}_$2" >/dev/null; }
platform_hook() {
    local name=$1 hook=$2
    shift 2
    if has_hook "$name" "$hook"; then
        "${name}_$hook" "$@"
    fi
}

# Set blog_type from a name or alias. Return 1 if it is not recognized.
resolve_platform() {
    local want p alias
    want=$(lowercase "$1")
    for p in $PLATFORMS; do
        if [[ $want == "$p" ]]; then blog_type=$p; return 0; fi
        for alias in $(platform_var "$p" aliases); do
            if [[ $want == "$alias" ]]; then blog_type=$p; return 0; fi
        done
    done
    return 1
}

platform_names() {
    local p out=""
    for p in $PLATFORMS; do out="${out:+$out, }$p"; done
    printf '%s' "$out"
}

platform_help() {
    local p aliases
    for p in $PLATFORMS; do
        aliases=$(platform_var "$p" aliases)
        printf '  %-11s %s%s\n' "$p" "$(platform_var "$p" label)" "${aliases:+ (also: $aliases)}"
    done
}

# ---------------------------------------------------------------------------
# Banner and help
# ---------------------------------------------------------------------------

banner() {
    local p labels=""
    [[ $quiet -eq 0 ]] && is_interactive || return 0
    for p in $PLATFORMS; do labels="${labels:+$labels, }$(platform_var "$p" label)"; done
    printf '\n%s========================================%s\n' "$BOLD$CYAN" "$RESET" >&2
    printf '%s              BLOG ARCHIVER%s\n' "$BOLD$CYAN" "$RESET" >&2
    printf '%s========================================%s\n' "$BOLD$CYAN" "$RESET" >&2
    printf '   %s\n' "$labels" >&2
    printf '          Offline Archive Tool\n' >&2
    printf '                v%s\n\n' "$VERSION" >&2
}

usage() {
    cat <<EOF
Usage: $PROG [OPTIONS] [URL] [-- WGET_ARGS...]

Archive a blog for offline viewing using GNU Wget.
If URL is omitted, you are prompted for it.

Platforms:
$(platform_help)

Options:
  -t, --type TYPE         Blog platform (default: detect from the hostname
                          or the page)
  -o, --output DIR        Archive root directory (default: ./archives)
  -w, --wait SECONDS      Delay between requests (default: 1)
  -r, --limit-rate RATE   Maximum download rate, e.g. 200k or 1m; 0 = no limit
                          (default: 20k for WordPress, otherwise no limit)
  -d, --depth N           Recursion depth, or "inf" (default: 2 for Blogspot,
                          inf for WordPress, 0 for Substack)
  -s, --sitemap           Also start from every post in the blog's sitemap.
                          This reaches posts a normal crawl can miss.
                          Always on for Substack.
  -m, --max-posts N       Archive at most N posts from the post list
                          (--sitemap or Substack). Useful for a trial run.
      --no-media-hosts    Do not download images from the platform's image
                          servers (by default they are included)
      --all-image-sizes   Substack: also keep the extra image widths listed
                          for responsive layouts (much larger archives)
  -A, --user-agent UA     User-Agent header to send
  -y, --yes               Start without asking for confirmation
  -n, --dry-run           Show the wget command without downloading anything
  -q, --quiet             Print only warnings, errors, and the final result
                          (the full wget output still goes to wget.log)
  -h, --help              Show this help and exit
  -V, --version           Show the version and exit

Arguments after "--" are passed to wget as they are.

Environment:
  BLOG_ARCHIVER_DIR       Default archive root (--output takes precedence)
  NO_COLOR                Turn off colored output

Exit status:
  0      Archive completed
  1-8    wget's exit status; 8 means some URLs returned server errors
         (often harmless 404s, so the archive is usually still usable)
  64     Usage error         69  Missing dependency
  73     Cannot create the archive directory
  75     The same blog is already being archived
  130    Interrupted

Examples:
  $PROG https://example.blogspot.com
  $PROG --type wordpress --sitemap --yes https://blog.example.org
  $PROG --max-posts 5 example.substack.com
  $PROG --dry-run example.wordpress.com
EOF
}

# ---------------------------------------------------------------------------
# Cleanup and signal handling
# ---------------------------------------------------------------------------

cleanup() {
    local rc=$?
    if [[ -n $lock_dir && -d $lock_dir ]]; then
        rmdir "$lock_dir" 2>/dev/null || true
    fi
    if [[ -n $work_dir && -d $work_dir ]]; then
        rm -rf "$work_dir"
    fi
    exit "$rc"
}

on_interrupt() {
    printf '\n' >&2
    warn "Interrupted. A partial archive may have been left behind."
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Argument parsing and validation
# ---------------------------------------------------------------------------

require_arg() {
    [[ $# -ge 2 ]] || die "Option '$1' requires an argument. See --help." "$EX_USAGE"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--type)        require_arg "$@"; blog_type=$2; shift 2 ;;
            --type=*)         blog_type=${1#*=}; shift ;;
            -o|--output)      require_arg "$@"; output_root=$2; shift 2 ;;
            --output=*)       output_root=${1#*=}; shift ;;
            -w|--wait)        require_arg "$@"; wait_seconds=$2; shift 2 ;;
            --wait=*)         wait_seconds=${1#*=}; shift ;;
            -r|--limit-rate)  require_arg "$@"; rate_limit=$2; shift 2 ;;
            --limit-rate=*)   rate_limit=${1#*=}; shift ;;
            -d|--depth)       require_arg "$@"; depth=$2; shift 2 ;;
            --depth=*)        depth=${1#*=}; shift ;;
            -m|--max-posts)   require_arg "$@"; max_posts=$2; shift 2 ;;
            --max-posts=*)    max_posts=${1#*=}; shift ;;
            -A|--user-agent)  require_arg "$@"; user_agent=$2; user_agent_set=1; shift 2 ;;
            --user-agent=*)   user_agent=${1#*=}; user_agent_set=1; shift ;;
            -s|--sitemap)     use_sitemap=1; shift ;;
            --no-media-hosts) media_hosts=0; shift ;;
            --all-image-sizes) all_image_sizes=1; shift ;;
            -y|--yes)         assume_yes=1; shift ;;
            -n|--dry-run)     dry_run=1; shift ;;
            -q|--quiet)       quiet=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            -V|--version)     printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
            --)               shift; extra_wget_args=("$@"); break ;;
            -*)               die "Unknown option: $1. See --help." "$EX_USAGE" ;;
            *)
                [[ -z $blog_url ]] || die "Unexpected argument: $1. Give only one URL." "$EX_USAGE"
                blog_url=$1
                shift
                ;;
        esac
    done
}

validate_options() {
    local re

    if [[ -n $blog_type ]] && ! resolve_platform "$blog_type"; then
        die "Unknown --type '$blog_type'. Choose one of: $(platform_names)." "$EX_USAGE"
    fi

    re='^[0-9]+(\.[0-9]+)?$'
    [[ $wait_seconds =~ $re ]] ||
        die "Invalid --wait '$wait_seconds'. Give a number of seconds." "$EX_USAGE"

    re='^[0-9]+(\.[0-9]+)?[kKmMgG]?$'
    [[ -z $rate_limit || $rate_limit =~ $re ]] ||
        die "Invalid --limit-rate '$rate_limit'. Examples: 50k, 1.5m, 0." "$EX_USAGE"

    re='^([0-9]+|inf)$'
    [[ -z $depth || $depth =~ $re ]] ||
        die "Invalid --depth '$depth'. Give a whole number or 'inf'." "$EX_USAGE"

    re='^[1-9][0-9]*$'
    [[ -z $max_posts || $max_posts =~ $re ]] ||
        die "Invalid --max-posts '$max_posts'. Give a positive whole number." "$EX_USAGE"

    [[ -n $output_root ]] || die "The archive directory cannot be empty." "$EX_USAGE"
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

check_dependencies() {
    local cmd missing="" version

    for cmd in wget awk grep sed tr tee cut head mktemp find du wc; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [[ -z $missing ]] ||
        die "Required command(s) not found:$missing. Install them and try again." "$EX_UNAVAILABLE"

    # Read the whole output so no SIGPIPE trips pipefail.
    version=$(wget --version 2>/dev/null | sed -n 1p) || true
    case $version in
        "GNU Wget2"*)
            warn "Found Wget2 ($version). It is mostly compatible, but GNU Wget 1.x is recommended."
            ;;
        "GNU Wget "*) ;;
        *)
            die "GNU Wget is required, but 'wget' looks like a different program${version:+ ($version)}. BusyBox wget cannot download recursively." "$EX_UNAVAILABLE"
            ;;
    esac
    wget_help=$(wget --help 2>/dev/null) || true
}

wget_supports() { [[ $wget_help == *"$1"* ]]; }

# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------

# Download URL $1 to file $2 quietly. Used for small files such as the front
# page, sitemaps, and API responses (not the archive itself).
fetch() {
    wget "${fetch_args[@]}" --output-document="$2" "$1" 2>/dev/null && [[ -s $2 ]]
}

setup_fetch_args() {
    fetch_args=(--quiet --timeout=30 --tries=2)
    if [[ $user_agent_set -eq 1 ]]; then
        fetch_args+=(--user-agent="$user_agent")
    fi
}

# Percent-encode a string so it can go in a query parameter.
urlencode() {
    local LC_ALL=C str=$1 out="" c i
    for (( i = 0; i < ${#str}; i++ )); do
        c=${str:i:1}
        case $c in
            [A-Za-z0-9.~_-]) out+=$c ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# URL handling
# ---------------------------------------------------------------------------

# Check and clean up a URL, then set blog_url, blog_host, and blog_origin.
normalize_url() {
    local url=$1 re scheme authority path host port=""

    # Trim surrounding whitespace.
    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    [[ -n $url ]] || die "No blog URL given." "$EX_USAGE"

    # Default to https:// when no scheme is given.
    re='^[A-Za-z][A-Za-z0-9+.-]*://'
    [[ $url =~ $re ]] || url="https://$url"

    re='^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)([^?#]*)'
    [[ $url =~ $re ]] || die "Could not parse URL: $url" "$EX_USAGE"
    scheme=$(lowercase "${BASH_REMATCH[1]}")
    authority=${BASH_REMATCH[2]}
    path=${BASH_REMATCH[3]}

    case $scheme in
        http|https) ;;
        *) die "Unsupported URL scheme '$scheme://'. Use http:// or https://." "$EX_USAGE" ;;
    esac

    authority=${authority##*@}          # remove any user:password@
    host=${authority%%:*}
    if [[ $authority == *:* ]]; then
        port=${authority#*:}
        re='^[0-9]{1,5}$'
        [[ $port =~ $re ]] || die "Invalid port in URL: '$port'" "$EX_USAGE"
    fi
    host=$(lowercase "$host")
    host=${host%.}                       # remove any trailing dot (FQDN form)

    re='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
    [[ ${#host} -le 253 && $host =~ $re ]] ||
        die "Invalid hostname in URL: '$host'" "$EX_USAGE"

    # Remove trailing slashes; one is added back where wget needs it.
    while [[ $path == */ ]]; do path=${path%/}; done

    blog_host=$host
    blog_origin="$scheme://$host${port:+:$port}"
    blog_url="$blog_origin$path"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

detect_from_hostname() {
    local p
    for p in $PLATFORMS; do
        if "${p}_match_host" "$blog_host"; then
            blog_type=$p
            return 0
        fi
    done
    return 1
}

# Fetch the front page and look for platform markers (for custom domains).
detect_from_page() {
    local page="$work_dir/probe.html" field p re

    info "Checking the front page to identify the platform..."
    fetch "$blog_url/" "$page" || return 1

    for field in generator_re marker_re; do
        for p in $PLATFORMS; do
            re=$(platform_var "$p" "$field")
            [[ -n $re ]] || continue
            if grep -Eqi -- "$re" "$page"; then
                blog_type=$p
                return 0
            fi
        done
    done
    return 1
}

prompt_for_platform() {
    local choice p i count=0
    printf '\nCould not determine the blog platform automatically.\n\n' >&2
    for p in $PLATFORMS; do
        count=$((count + 1))
        printf '  %d) %s\n' "$count" "$(platform_var "$p" label)" >&2
    done
    printf '\n' >&2

    while true; do
        read -rp "Blog type [1-$count, q to quit]: " choice || die "No input received." "$EX_USAGE"
        case $choice in
            q|Q) info "Canceled."; exit 0 ;;
            *[!0-9]*|"") ;;
            *)
                i=0
                for p in $PLATFORMS; do
                    i=$((i + 1))
                    if [[ $i -eq $choice ]]; then blog_type=$p; return 0; fi
                done
                ;;
        esac
        printf 'Enter a number from 1 to %d.\n' "$count" >&2
    done
}

determine_platform() {
    if [[ -n $blog_type ]]; then
        platform_source="--type option"
    elif detect_from_hostname; then
        platform_source="hostname"
    elif [[ $dry_run -eq 0 ]] && detect_from_page; then
        platform_source="page content"
    elif is_interactive; then
        prompt_for_platform
        platform_source="your selection"
    else
        die "Could not determine the blog platform. Give it with --type ($(platform_names))." "$EX_USAGE"
    fi
}

# ---------------------------------------------------------------------------
# Post list (sitemaps)
# ---------------------------------------------------------------------------

# Print the <loc> URLs in sitemap file $1.
extract_locs() {
    { tr '\r\n' '  ' < "$1" | grep -oE '<loc>[^<]*</loc>|<loc><!\[CDATA\[[^]]*\]\]></loc>' || true; } |
        sed -e 's#</*loc>##g' -e 's#<!\[CDATA\[##' -e 's#\]\]>##' \
            -e 's/&amp;/\&/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Append the page URLs in the sitemap at URL $1 to file $2. Follows sitemap
# indexes up to two levels deep.
fetch_sitemap() {
    local url=$1 out=$2 level=${3:-0} xml child

    xml=$(mktemp "$work_dir/sitemap.XXXXXX")
    fetch "$url" "$xml" || return 1
    grep -Eqi '<urlset|<sitemapindex' "$xml" || return 1

    if grep -qi '<sitemapindex' "$xml"; then
        [[ $level -lt 2 ]] || return 0
        while IFS= read -r child; do
            case $child in
                "") continue ;;
                *.gz) warn "Skipping compressed sitemap: $child"; continue ;;
            esac
            pause
            fetch_sitemap "$child" "$out" $((level + 1)) || true
            if [[ -n $max_posts && $(count_lines "$out") -ge $max_posts ]]; then break; fi
        done < <(extract_locs "$xml")
    else
        extract_locs "$xml" >> "$out"
    fi
}

# Keep only URLs from file $1 that are inside the blog URL; print them.
filter_blog_urls() {
    local line rest prefix=${blog_url#*://}
    while IFS= read -r line; do
        case $line in http://*|https://*) ;; *) continue ;; esac
        rest=${line#*://}
        case $rest in
            "$prefix"|"$prefix"/*|"$prefix"\?*) printf '%s\n' "$line" ;;
        esac
    done < "$1"
}

# Build the list of post URLs in seed_file. Leaves seed_file empty if none.
build_url_list() {
    local raw="$work_dir/urls.raw" listed="$work_dir/urls.listed"
    local candidates="" sm path n

    : > "$raw"
    : > "$listed"
    info "Looking for a sitemap..."

    if fetch "$blog_origin/robots.txt" "$work_dir/robots.txt"; then
        candidates=$(tr -d '\r' < "$work_dir/robots.txt" |
            sed -n 's/^[Ss][Ii][Tt][Ee][Mm][Aa][Pp]:[[:space:]]*//p') || true
    fi
    for path in $(platform_var "$blog_type" sitemaps); do
        candidates="$candidates"$'\n'"$blog_origin$path"
    done

    while IFS= read -r sm; do
        [[ -n $sm ]] || continue
        if fetch_sitemap "$sm" "$raw" && [[ -s $raw ]]; then
            info "Using sitemap: $sm"
            break
        fi
    done <<< "$candidates"

    filter_blog_urls "$raw" > "$listed"

    if [[ ! -s $listed ]] && has_hook "$blog_type" list_urls; then
        info "No sitemap found."
        platform_hook "$blog_type" list_urls "$listed" || true
    fi

    # Remove duplicates (keeping order) and apply --max-posts.
    awk 'NF && !seen[$0]++' "$listed" > "$raw"
    if [[ -n $max_posts ]]; then
        head -n "$max_posts" "$raw" > "$listed"
    else
        cp "$raw" "$listed"
    fi

    n=$(count_lines "$listed")
    if [[ $n -gt 0 ]]; then
        seed_file="$work_dir/urls.txt"
        mv "$listed" "$seed_file"
        info "Found $n post URLs."
    else
        warn "No post list found. Falling back to following links from the front page."
    fi
}

# ---------------------------------------------------------------------------
# Archive setup
# ---------------------------------------------------------------------------

abspath() {
    case $1 in
        /*|[A-Za-z]:[/\\]*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$PWD" "${1#./}" ;;
    esac
}

confirm_start() {
    local answer
    [[ $assume_yes -eq 0 && $dry_run -eq 0 ]] && is_interactive || return 0
    while true; do
        read -rp "Start archive? [Y/n]: " answer || die "No input received." "$EX_USAGE"
        case $answer in
            ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) info "Archive canceled."; exit 0 ;;
            *) printf 'Enter y or n.\n' >&2 ;;
        esac
    done
}

acquire_lock() {
    local dir="$archive_dir/.blog-archiver.lock"
    if ! mkdir "$dir" 2>/dev/null; then
        die "Another run is already archiving this blog. If it is not, delete: $dir" "$EX_TEMPFAIL"
    fi
    lock_dir=$dir
}

# ---------------------------------------------------------------------------
# wget command
# ---------------------------------------------------------------------------

build_wget_command() {
    local media

    wget_cmd=(wget
        --page-requisites
        --convert-links
        --no-host-directories
        --directory-prefix="$archive_dir"
        --tries=3
        --timeout=30
        --waitretry=10
        -e robots=off
    )

    # Retry when rate-limited or the server has a temporary problem.
    if wget_supports --retry-on-http-error; then
        wget_cmd+=(--retry-on-http-error=429,500,502,503,504)
    fi
    if [[ ! $wait_seconds =~ $RE_ZERO ]]; then
        wget_cmd+=(--wait="$wait_seconds" --random-wait)
    fi
    if [[ -n $rate_limit && ! $rate_limit =~ $RE_ZERO_RATE ]]; then
        wget_cmd+=(--limit-rate="$rate_limit")
    fi
    if [[ $user_agent_set -eq 1 ]]; then
        wget_cmd+=(--user-agent="$user_agent")
    fi

    # Windows file systems cannot store characters such as ? : * in names.
    case $(uname -s 2>/dev/null || true) in
        MINGW*|MSYS*|CYGWIN*) wget_cmd+=(--restrict-file-names=windows) ;;
    esac

    # Download images hosted on the platform's own image servers.
    media=$(platform_var "$blog_type" media_domains)
    if [[ $media_hosts -eq 1 && -n $media ]]; then
        wget_cmd+=(--span-hosts --domains="$blog_host,$media")
    fi

    "${blog_type}_wget_args"

    if [[ -n $seed_file ]]; then
        wget_cmd+=(--input-file="$seed_file")
    fi
    wget_cmd+=(${extra_wget_args[@]+"${extra_wget_args[@]}"} "$blog_url/")
}

describe_wget_status() {
    case $1 in
        1) printf 'generic error' ;;
        2) printf 'command-line parse error (check any extra wget arguments)' ;;
        3) printf 'file I/O error (is the disk full, or are permissions wrong?)' ;;
        4) printf 'network failure' ;;
        5) printf 'SSL certificate verification failure' ;;
        6) printf 'authentication failure' ;;
        7) printf 'protocol error' ;;
        8) printf 'the server returned errors for some URLs (often harmless 404s)' ;;
        *) printf 'unexpected exit status %s' "$1" ;;
    esac
}

result_banner() {
    local color=$1 text=$2
    printf '%s========================================%s\n' "$color$BOLD" "$RESET" >&2
    printf '%s%s%s\n' "$color$BOLD" "$text" "$RESET" >&2
    printf '%s========================================%s\n' "$color$BOLD" "$RESET" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local status=0 rate_display start_urls file_count archive_size

    setup_colors
    parse_args "$@"
    validate_options
    check_dependencies
    banner

    if [[ -z $blog_url ]]; then
        is_interactive || die "No blog URL given. Usage: $PROG [OPTIONS] URL (see --help)" "$EX_USAGE"
        read -rp "Blog URL: " blog_url || die "No input received." "$EX_USAGE"
    fi
    normalize_url "$blog_url"

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/blog-archiver.XXXXXX") ||
        die "Could not create a temporary directory." "$EX_CANTCREAT"

    setup_fetch_args
    determine_platform
    platform_hook "$blog_type" defaults
    setup_fetch_args   # the platform may have changed the User-Agent

    archive_dir="$(abspath "$output_root")/$blog_host"
    log_file="$archive_dir/wget.log"

    rate_display=${rate_limit:-none}
    [[ ! $rate_display =~ $RE_ZERO_RATE ]] || rate_display="none"
    start_urls="front page"
    if [[ $use_sitemap -eq 1 ]]; then
        start_urls="front page + post list${max_posts:+ (at most $max_posts posts)}"
    fi

    info ""
    info "Platform   : $(platform_var "$blog_type" label) (from $platform_source)"
    info "Blog URL   : $blog_url/"
    info "Archive    : $archive_dir"
    info "Start from : $start_urls"
    info "Depth      : $depth    Wait: ${wait_seconds}s    Rate limit: $rate_display"
    info ""

    if [[ $dry_run -eq 1 ]]; then
        if [[ $use_sitemap -eq 1 ]]; then
            seed_file="<post-list>"
            info "Dry run. Nothing will be downloaded. The post list for"
            info "--input-file is built when the archive runs."
        else
            info "Dry run. Nothing will be downloaded."
        fi
        build_wget_command
        info "The command would be:"
        info ""
        printf '%q ' "${wget_cmd[@]}"
        printf '\n'
        exit 0
    fi

    confirm_start

    mkdir -p "$archive_dir" 2>/dev/null ||
        die "Could not create the archive directory: $archive_dir" "$EX_CANTCREAT"
    [[ -w $archive_dir ]] ||
        die "Cannot write to the archive directory: $archive_dir" "$EX_CANTCREAT"
    acquire_lock

    platform_hook "$blog_type" prepare
    if [[ $use_sitemap -eq 1 ]]; then
        build_url_list
    fi
    build_wget_command

    {
        printf '# %s %s\n' "$PROG" "$VERSION"
        printf '# Started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf '# Command:'
        printf ' %q' "${wget_cmd[@]}"
        printf '\n'
        if [[ -n $seed_file ]]; then
            printf '# Post list (%s URLs):\n' "$(count_lines "$seed_file")"
            sed 's/^/#   /' "$seed_file"
        fi
        printf '\n'
    } > "$log_file" || die "Could not write the log file: $log_file" "$EX_CANTCREAT"

    info ""
    info "Archiving $(platform_var "$blog_type" label) blog. Press Ctrl-C to stop."
    info ""

    if [[ $quiet -eq 1 ]]; then
        "${wget_cmd[@]}" >> "$log_file" 2>&1 || status=$?
    else
        "${wget_cmd[@]}" 2>&1 | tee -a "$log_file" || status=$?
    fi

    printf '\n# Finished: %s (wget exit status %s)\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %z')" "$status" >> "$log_file" || true

    file_count=$(find "$archive_dir" -type f ! -name wget.log 2>/dev/null | wc -l) || file_count=0
    file_count=$((file_count + 0))
    archive_size=$(du -sh "$archive_dir" 2>/dev/null | cut -f1) || archive_size="?"

    printf '\n' >&2
    if [[ $status -eq 0 ]]; then
        result_banner "$GREEN" "Archive complete!"
    elif [[ $status -eq 8 && $file_count -gt 0 ]]; then
        result_banner "$YELLOW" "Archive complete, with warnings."
        printf 'Note: %s.\n' "$(describe_wget_status "$status")" >&2
    else
        result_banner "$RED" "Archive failed or is incomplete."
        printf 'Reason: %s.\n' "$(describe_wget_status "$status")" >&2
    fi
    printf '\nArchive : %s\n' "$archive_dir" >&2
    printf 'Files   : %s (%s)\n' "$file_count" "$archive_size" >&2
    printf 'Log     : %s\n' "$log_file" >&2

    if [[ $file_count -eq 0 ]]; then
        warn "No files were downloaded. Check the log for details."
    fi

    exit "$status"
}

main "$@"
