# Blog Archiver

A Bash tool that saves **Blogspot, WordPress, and Substack** blogs as self-contained offline copies, using GNU Wget.

I read a lot, and I tend to keep the things I find interesting. I'm a bit of a data hoarder. Blogs are especially worth preserving: they're often personal and independent, and they can vanish without warning when someone stops paying for hosting, a platform changes its policies, or a site is simply abandoned.

Blog Archiver turns a blog into a folder of ordinary HTML files, images, and stylesheets that you can open in any browser, years from now, without an internet connection.

```bash
./blog-archiver.sh https://example.blogspot.com
```

## Features

* **Recognizes the platform automatically.** It checks the hostname first, then looks for Blogger, WordPress, or Substack markers in the page. That covers blogs on custom domains too.
* **Finds every post, not just the linked ones.** It can start from the blog's sitemap, and for Substack it builds the post list from the publication's archive. Older posts that aren't linked from recent pages are archived as well.
* **Gives you complete pages.** Each page is saved with its stylesheets and images, including images hosted on the platform's own image servers. Links are rewritten so the archive works offline.
* **Uses only the space it needs.** Duplicate copies of the same image at different resolutions are skipped.
* **Goes easy on servers.** It pauses between requests, limits the download rate where sensible, and backs off and retries when a server is busy or rate-limiting.
* **Works unattended.** Every prompt has a command-line equivalent, there's a dry-run mode, it uses clear exit codes, and it writes a full log for each run.
* **Handles problems well.** It checks input, checks its dependencies, refuses to archive the same blog twice at once, and cleans up after itself even when interrupted.

## Requirements

* **Bash 3.2 or later.** The version that ships with macOS works.
* **GNU Wget 1.x.**
* Standard Unix tools (`grep`, `sed`, `awk`, and so on), which come with Linux, macOS, and Git Bash on Windows.

| Platform | Install Wget |
| --- | --- |
| Debian / Ubuntu | `sudo apt install wget` |
| Fedora | `sudo dnf install wget` (see the note below) |
| macOS (Homebrew) | `brew install wget` |
| Windows | Use Git Bash or WSL, with GNU Wget on your `PATH` |

> **Note:** some distributions, including recent Fedora releases, now install **Wget2** as `wget`. The script works with Wget2 and warns you, but GNU Wget 1.x is better tested. BusyBox `wget` can't download recursively, so it isn't supported.

## Getting Started

```bash
git clone https://github.com/lanz/blog-archiver.git
cd blog-archiver
chmod +x blog-archiver.sh
./blog-archiver.sh
```

Run without arguments, it asks for a URL, shows what it's about to do, and asks you to confirm:

```text
========================================
              BLOG ARCHIVER
========================================
   Blogspot, WordPress, Substack
          Offline Archive Tool
                v2.1.0

Blog URL: example.substack.com

Platform   : Substack (from hostname)
Blog URL   : https://example.substack.com/
Archive    : /home/you/blog-archiver/archives/example.substack.com
Start from : front page + post list
Depth      : 0    Wait: 1s    Rate limit: none

Start archive? [Y/n]:
```

Everything can also be given on the command line:

```bash
# Archive a blog. The scheme is optional; https:// is assumed.
./blog-archiver.sh example.wordpress.com

# Try it on a few posts before committing to a full archive.
./blog-archiver.sh --max-posts 5 example.substack.com

# Archive a self-hosted WordPress blog completely, using its sitemap, without prompts.
./blog-archiver.sh --type wordpress --sitemap --yes https://blog.example.org

# See exactly which wget command would run, without downloading anything.
./blog-archiver.sh --dry-run https://example.blogspot.com
```

## Options

| Option | Description | Default |
| --- | --- | --- |
| `-t, --type TYPE` | `blogspot`, `wordpress`, or `substack` | Auto-detect |
| `-o, --output DIR` | Folder where archives are stored | `./archives` |
| `-w, --wait SECONDS` | Pause between requests (randomized around this value) | `1` |
| `-r, --limit-rate RATE` | Bandwidth cap, e.g. `200k` or `1m`; `0` means no limit | `20k` for WordPress, none for others |
| `-d, --depth N` | How many links deep to follow, or `inf` | Blogspot `2`, WordPress `inf`, Substack `0` |
| `-s, --sitemap` | Also start from every post listed in the sitemap | Off (always on for Substack) |
| `-m, --max-posts N` | Archive at most N posts from the post list | No limit |
| `--no-media-hosts` | Skip images stored on the platform's image servers | Images included |
| `--all-image-sizes` | Substack only: keep every image resolution | Only the sizes shown are kept |
| `-A, --user-agent UA` | User-Agent header to send | Platform default |
| `-y, --yes` | Don't ask for confirmation | Ask (interactive runs only) |
| `-n, --dry-run` | Print the wget command and exit | |
| `-q, --quiet` | Show only warnings, errors, and the summary | |
| `-- ARGS...` | Pass any remaining arguments straight to `wget` | |

The `BLOG_ARCHIVER_DIR` environment variable sets the default output folder, and `NO_COLOR` turns off colored output. `./blog-archiver.sh --help` lists every option.

## How It Works

Each run goes through the same steps:

1. **Clean up the URL.** It adds a missing `https://` and removes credentials, query strings, fragments, and trailing slashes. Invalid hostnames are rejected before any network request is made.
2. **Identify the platform.** Known hostnames (`*.blogspot.com`, `*.wordpress.com`, `*.substack.com`) are recognized immediately. Anything else is checked for a platform's `<meta name="generator">` tag, then for its asset URLs (such as `/wp-content/` or `substackcdn.com`). If both fail, the script asks you.
3. **Build a post list** (Substack, or with `--sitemap`). It reads sitemaps listed in `robots.txt` plus each platform's usual sitemap paths, and follows sitemap indexes. Only URLs inside the blog are kept.
4. **Download.** wget fetches each page with its stylesheets and images, and with any image servers the platform uses. Feeds, search results, comment-reply links, login pages, and similar endless or useless URLs are skipped.
5. **Rewrite links** so the archive works from your disk, then print a summary and write a log.

### Platform notes

**Blogspot.** It first gets Blogger's guest session cookies, which some blogs need before they serve their full content. It then follows links two levels deep from the front page. That reaches recent posts and the archive pages, but very old posts on a large blog can be missed. Add `--sitemap` to reach every post. Images on `blogger.googleusercontent.com` and `*.bp.blogspot.com` are included.

**WordPress.** It crawls the whole blog, with a bandwidth cap of 20 KB/s by default to be considerate to self-hosted servers. Raise it with `--limit-rate` if you know the host can take it. It works with both WordPress.com and self-hosted sites, and includes images served through WordPress.com's image servers (`i0.wp.com` and similar).

**Substack.** Substack's `/archive` page loads its post list with JavaScript, so a normal crawler only finds a handful of posts. Instead, the script builds the list itself, trying these in order:

1. The publication's sitemap, if it has one.
2. Substack's archive API, which lists every public post.
3. The RSS feed, which has only the most recent posts. The script warns you when it falls back to this.

Each post is then downloaded with its images, along with the front, `/archive`, and `/about` pages. Substack's layouts list every image in up to five resolutions, and an animated GIF can be 10 MB or more per copy. By default, only the resolutions the pages actually display are kept. In testing, that cut image downloads by about two-thirds. Use `--all-image-sizes` to keep them all.

## Viewing an Archive

Open `index.html` in the blog's folder with any browser. Links between pages point to the local copies.

If a page doesn't display properly when opened straight from disk, serve the folder locally instead. Browsers restrict some features on `file://` pages.

```bash
python3 -m http.server --directory archives/example.substack.com 8000
# then open http://localhost:8000/
```

Archives are stored by hostname, so different blogs never mix:

```text
archives/
├── example.blogspot.com/
│   ├── index.html
│   ├── 2023/05/a-post.html
│   ├── img/ …                  images from Blogger's image servers
│   └── wget.log
└── example.substack.com/
    ├── index.html
    ├── archive.html
    ├── p/a-post.html
    ├── image/ …                images from Substack's CDN
    ├── bundle/ …               stylesheets and scripts
    └── wget.log
```

Each `wget.log` starts with a header that records the script version, the start time, the exact wget command, and the post list used. It ends with the finish time and exit status. Check it first if something looks wrong.

## Updating an Archive

Run the same command again to refresh an archive. New posts are added and existing pages are replaced with current copies. Old copies are not kept. If you want snapshots, use a different `--output` folder for each run.

For regular backups, run it from cron or another scheduler:

```bash
# Every Sunday at 03:00
0 3 * * 0  /path/to/blog-archiver.sh --yes --quiet --output /backups/blogs example.wordpress.com
```

## Exit Status

| Code | Meaning |
| --- | --- |
| `0` | Archive complete |
| `8` | Archive complete, but some URLs returned server errors (usually missing pages). The archive is normally usable. |
| `1`–`7` | wget failed: `3` disk or permission problem, `4` network failure, `5` SSL problem |
| `64` | Invalid option or URL |
| `69` | A required program (such as GNU Wget) is missing |
| `73` | The archive folder or log can't be created |
| `75` | Another run is already archiving this blog |
| `130` | Interrupted with Ctrl-C |

## Troubleshooting

| Symptom | What to try |
| --- | --- |
| "Could not determine the blog platform" | Give it explicitly with `--type`. |
| "Another run is already archiving this blog" | If no other run is active, a previous run was killed. Delete the `.blog-archiver.lock` folder that the message names. |
| Many `403` or `429` errors in the log | The server is rate-limiting you. Increase `--wait` (for example `--wait 5`) and try again later. |
| Older posts are missing | Add `--sitemap`, or increase `--depth`. |
| Substack archive only has recent posts | The archive API didn't respond, so the script used the RSS feed. The log says so. Try again later. |
| Pages look unstyled offline | Look in `wget.log` for stylesheets that failed to download, or view the archive through a local web server as described above. |

## Responsible Use

Blog Archiver is meant for preserving content you're allowed to keep: your own blogs, blogs whose authors permit archiving, and personal reference copies where the law allows.

* **Its defaults are polite.** It waits about one second between requests (randomized), caps WordPress bandwidth, and backs off when a server reports it's overloaded. Please keep these defaults unless you know the host can take more.
* **It ignores `robots.txt`.** Blogging platforms commonly use `robots.txt` to block all automated clients, including personal archiving tools. Blog Archiver makes up for this with the limits above and by skipping feeds, search pages, and other endless URLs. Make sure your use respects the site's terms of service.
* **Paid content is not bypassed.** Subscriber-only Substack posts are saved as the public preview. If you're a paying subscriber, you can pass your own browser cookies to wget, for example `-- --load-cookies=cookies.txt`.

## Limitations

* It works best with traditional, server-rendered blogs. Sites built mostly with JavaScript, such as Medium, Wix, and Squarespace, don't archive well with wget.
* Comments are archived only when they're part of the page's HTML. Substack comment threads load separately and are not saved.
* Substack's archive API isn't documented and has changed before. If it changes again, the script falls back to the RSS feed and says so in its output.
* Very long image URLs can hit path-length limits on Windows file systems. Archiving to a short path, such as `--output C:/a`, helps.

## Adding a Platform

Each platform is one self-contained block in the "Platforms" section of `blog-archiver.sh`. To add one:

1. Add its name to `PLATFORMS`.
2. Define its variables: `NAME_label`, `NAME_aliases`, `NAME_generator_re`, `NAME_marker_re`, `NAME_sitemaps`, and `NAME_media_domains`.
3. Define its functions: `NAME_match_host`, `NAME_defaults`, and `NAME_wget_args`.
4. Optionally, define the hooks `NAME_prepare` (runs before wget starts) and `NAME_list_urls` (lists posts when there is no sitemap).

Detection, `--type`, the platform prompt, and `--help` pick up the new platform automatically. The comment at the top of the section documents each item, and the existing blocks are working examples. `--dry-run` is a quick way to check the wget command a new platform builds.

## License

Copyright (C) 2026 [Lance Duvall](https://github.com/lanz).

Licensed under the [ GNU Affero General Public License v3.0](LICENSE) or later.
