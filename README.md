# Blog Archiver

A small Bash utility for archiving **Blogspot and WordPress blogs** for offline viewing using `wget`.

I read a lot. I also have a tendency to save things that I find interesting because, well, **I'm a bit of a data hoarder**. Blogs are especially worth preserving: they're often personal, independent, and full of information that can disappear when someone stops paying for hosting, a platform changes, or a site simply vanishes.

## Features

* Archives **Blogspot and WordPress.com** blogs with `wget`.
* Automatically detects the blog platform, with manual selection as a fallback.
* Preserves pages and required resources for offline viewing.
* Keeps each blog in its own archive directory.
* Shows download progress and saves a `wget.log`.

## Requirements

The script requires:

* Bash
* GNU `wget`

On Debian/Ubuntu:

```bash
sudo apt install wget
```

On Fedora:

```bash
sudo dnf install wget
```

On macOS with Homebrew:

```bash
brew install wget
```

## Usage

Clone the repository:

```bash
git clone https://github.com/lanz/blog-archiver.git
cd blog-archiver
```

Make the script executable:

```bash
chmod +x blog-archiver.sh
```

Run it:

```bash
./blog-archiver.sh
```

You'll be prompted for the blog URL:

```text
========================================
              BLOG ARCHIVER
========================================
       Blogspot & WordPress
       Offline Archive Tool
              v1.0

Blog URL: https://example.blogspot.com/
```

The script will determine the platform automatically.

For domains it doesn't recognize, you'll be given the option to select Blogspot or WordPress manually.

## Archive Layout

Archives are stored in an `archives` directory using the blog's hostname:

```text
archives/
├── example.blogspot.com/
│   ├── index.html
│   ├── ...
│   └── wget.log
│
└── example.wordpress.com/
    ├── index.html
    ├── ...
    └── wget.log
```

This makes it possible to archive multiple blogs without their files getting mixed together.

## Limitations

It works best with traditional, server-rendered blogs. Modern websites that depend heavily on JavaScript, client-side rendering, APIs, authentication, or dynamically generated content may not archive correctly.

If something doesn't look right in the offline archive, check the corresponding `wget.log` for missing CSS, JavaScript, images, fonts, or other resources.

## License

This project is licensed under the **GNU General Public License, version 3 or any later version (GPL-3.0-or-later)**.

See the `LICENSE` file for the full license text.

## Disclaimer

This tool is intended for archiving content that you are permitted to download and preserve.

Please respect copyright, terms of service, and applicable laws when using it. Be considerate of the servers you're downloading from, particularly when archiving large sites.
