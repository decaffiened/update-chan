# update-chan
(currently a) Windows Powershell utility to fetch and install multiple operating system ISO installers onto any Ventoy disk and keep them updated. Simple, easy, and clean!

# how to use update-chan
1. Clone the repository anywhere. I have mine inside the Ventoy drive -> /ventoy folder -> custom /tools folder.
Clone it by getting Git or Git For Windows and running `git clone https://github.com/decaffiened/update-chan` in your Windows Terminal, Command Prompt or Powershell.

2. Open Powershell, `cd` to where ever you cloned the repository, and run ./update-chan.ps1.
If it gives you an ExecutionPolicy error saying you can't run .ps1 files on your computer, set your ExecutionPolicy for `update-chan.ps1` to Unsigned, or else it won't run. Alternatively, set your system-wide ExecutionPolicy to Unsigned, but that's risky. Find out how to do this [here.](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-executionpolicy?view=powershell-7.6)

3. Enjoy! All the options should be pretty clear.

# okay, but there aren't enough options!
The best solution is to contribute! Find out the latest download links for whatever it is you want to get, and add it to the `sources.json` file. Before starting a pull request, ensure that it works and is downloading the latest version, and that you properly categorized it.

# how do i edit sources.json? i don't even know what it even does, and how it works!
update-chan automatically loads all its options from `sources.json`. It contains every download link, mirror and the like from there.

# `sources.json` structure and editing guide

`sources.json` is the only file you need to edit to add, remove, or update download entries. update-chan reads it on startup and builds the entire menu from it automatically — no code changes needed.

## structure

Every downloadable ISO boils down to one of these:

**Direct entries** - you know the exact URL:
`{ "url": "https://example.com/path/to/file.iso", "file": "filename-to-save-as.iso" }`

**Scraped entries** - the filename changes with each release (e.g. rolling distros), so update-chan fetches a directory listing and picks the latest match:
`{ "page_url": "https://example.com/releases/", "regex": "distroname-[0-9.]+-amd64\\.iso" }`

The regex is matched against the raw HTML of page_url. Results are sorted descending so the latest version wins. Use \\. to escape dots (it's a JSON string inside a regex).

### how entries are grouped

Everything lives under `"linux"` at the top level. Inside that, you nest **group nodes** and **leaf nodes.** A group node has a `"label"` and either `"children"`, `"releases"`, or `"variants"` (or bare named keys). A leaf node is the `{ "url", "file" }` or `{ "page_url", "regex" }` pair above.

linux
└── my_group          ← group node (shows as [+] in menu, navigates into)
    └── my_distro     ← group node
        └── releases / variants / bare keys
            └── { url, file }   ← leaf node (shows as [ISO], downloads)
            
update-chan recognises three ways to organise leaves under a distro node:

**`"releases"` — versioned releases with variants**

Use this when you want to show a version number and a variant (desktop, server, minimal…) as separate menu items.
```json
"ubuntu": {
  "label": "Ubuntu",
  "releases": {
    "24.04.4": {
      "desktop": { "url": "https://releases.ubuntu.com/noble/ubuntu-24.04.4-desktop-amd64.iso", "file": "ubuntu-24.04.4-desktop-amd64.iso" },
      "server":  { "url": "https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso", "file": "ubuntu-24.04.4-live-server-amd64.iso" }
    },
    "22.04.5": {
      "desktop": { "url": "https://releases.ubuntu.com/jammy/ubuntu-22.04.5-desktop-amd64.iso", "file": "ubuntu-22.04.5-desktop-amd64.iso" }
    }
  }
}
```

Menu shows: `24.04.4 - desktop [ISO]`, `24.04.4 - server [ISO]`, `22.04.5 - desktop [ISO]`
Releases are sorted by version number, newest first.

**`"variants"` - flat list of editions**

Use this when there's only one version but multiple flavours, or for rolling releases where the version is embedded in the filename.

```json
"manjaro": {
  "label": "Manjaro",
  "variants": {
    "kde":  { "url": "https://download.manjaro.org/kde/latest/manjaro-kde-latest.iso",  "file": "manjaro-kde-latest.iso" },
    "xfce": { "url": "https://download.manjaro.org/xfce/latest/manjaro-xfce-latest.iso", "file": "manjaro-xfce-latest.iso" }
  }
}
```

Menu shows: `kde [ISO]`, `xfce [ISO]`

**Bare named keys — single-download distros**

Use this for distros that only have one ISO worth keeping. Just put the key name directly on the distro node (not inside releases or variants). Common names: `"latest"`, `"install"`, `"dvd"`, `"live"`.

```json
"arch": {
  "label": "Arch Linux",
  "latest": { "url": "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso", "file": "archlinux-x86_64.iso" }
}
```

Menu shows: `latest [ISO]`

### `"children"` - submenus

Use this to group related distros under a collapsible submenu. The value of each child key is itself a full distro node (which can have its own `releases`, `variants`, `bare keys`, or even further `children`).

```json
"ubuntu_family": {
  "label": "Ubuntu Family",
  "children": {
    "ubuntu":   { "label": "Ubuntu",   "releases": { ... } },
    "kubuntu":  { "label": "Kubuntu",  "variants": { ... } },
    "lubuntu":  { "label": "Lubuntu",  "latest": { ... } }
  }
}
```

## full example — adding a new distro from scratch

Say you want to add **Linux Lite**, which has a single direct download:

1. Find the direct download URL from the official site. Use the permanent/versioned link, not a redirect like `/latest`. Example: `https://osdn.net/dl/linuxlite/linux-lite-7.4-64bit.iso`

2. Decide where it belongs. Linux Lite is Ubuntu-based, so it fits under `ubuntu_family` -> children. Or add it under `independent` if you prefer.

3. Add the entry:

```json
"linux-lite": {
  "label": "Linux Lite",
  "latest": {
    "url": "https://osdn.net/dl/linuxlite/linux-lite-7.4-64bit.iso",
    "file": "linux-lite-7.4-64bit.iso"
  }
}
```

4. Drop that block inside the appropriate `"children": { }` object, add a comma after the previous entry if needed, and save.

5. Run update-chan and navigate to the entry. Verify it appears and downloads correctly before submitting a pull request.

### for rolling/scraped entries

Some distros update their filenames with every release (Arch, Kali, EndeavourOS…). Instead of having to update `sources.json` every time, use the scraper:

```json
"endeavouros": {
  "label": "EndeavourOS",
  "latest": {
    "page_url": "https://mirror.alpix.eu/endeavouros/repo/endeavouros/x86_64/",
    "regex": "EndeavourOS_.*\\.iso"
  }
}
```

Tips for writing the regex:

- `[0-9.]+` matches a version number like `2025.04.15`
- `.*` matches anything (use sparingly — be specific enough to avoid matching checksums or torrent files)
- Always escape dots as `\\.` in JSON since `\` itself needs escaping
- Test your regex against the actual page source before committing

### reserved key names

These keys are used internally by update-chan and **will** be ignored or skipped if you use them as entry names:


| Key  | Purpose |
| ------------- | ------------- |
| `label`  | Human-readable display name (optional but recommended)  |
| `type`  | Reserved for future use  |
| `children`  | Triggers submenu rendering  |
| `releases`  | Triggers versioned release rendering  |
| `variants`  | Triggers flat variant rendering  |
| `url`  | Marks a node as a direct download leaf  |
| `file`  | The filename to save the ISO as  |
| `page_url`  | Marks a node as a scraped download leaf  |
| `regex`  | Pattern used with `page_url`  |

# before submitting a pull request, make sure:
- URL loads the correct file when pasted into a browser (no login walls, no redirects to a different file)
- `"file"` name matches what the server actually sends (check `Content-Disposition` or the URL's filename)
- Distro is placed in a logical category
- Version number in `"file"` and `"url"` matches the latest release
- For scraped entries: regex tested against the live page and matches only the ISO, not checksums or torrents
- JSON is valid — run it through [jsonlint](https://jsonlint.com/) if unsure

# wait, this is v8.0, but it's the first thing here. why?
Uh.... I was too lazy to show all versions of update-chan here and I made the repository late.

# and a note from me
Thank you for reading all this! If some of this code looks AI, know that it was partially vibecoded. Don't worry, though- I still coded almost all of it!

Enjoy using update-chan,

decaffiened.
[Check out my website!](https://decaffiened.neocities.org)
