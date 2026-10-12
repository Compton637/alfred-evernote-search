# Evernote Search for Alfred

<img src="Workflow/icon.png" width="128" alt="Workflow icon: an elephant with a magnifying glass">

Search your Evernote notes from [Alfred](https://www.alfredapp.com) without an API key.

Evernote removed AppleScript support in version 10, which broke the older Alfred workflows for Evernote. This workflow reads the database that the Evernote app keeps on your Mac instead. It needs no sign-in, no API key and no network access.

## Install

1. Download [Evernote-Search.alfredworkflow](https://github.com/Compton637/alfred-evernote-search/releases/latest/download/Evernote-Search.alfredworkflow) from the [latest release](https://github.com/Compton637/alfred-evernote-search/releases/latest).
2. Double-click the file and choose Import in Alfred.

Requires Alfred 5 with the Powerpack and the Evernote app (version 10 or later) installed and synced on the same Mac.

## Setup

The workflow reads the database which the Evernote app keeps on your Mac. When macOS asks if Alfred may access data from other apps, choose Allow. If the workflow reports that it is not allowed to read Evernote's data, grant Alfred Full Disk Access in System Settings → Privacy & Security.

## Usage

Search your Evernote notes via the `ens` keyword. It looks in titles, note text, tags, notebook names, and the text of attachments.

* <kbd>↩</kbd> Open note in Evernote.
* <kbd>⌘</kbd><kbd>↩</kbd> Open note on evernote.com.
* <kbd>⌥</kbd><kbd>↩</kbd> Copy link to note.

Search note titles only via the `ent` keyword.

Type several words to narrow the results; every word must be found in the note. A word matches the beginning of words, so `insur` finds `insurance`. Put a star in front of a word to find it inside longer words: `*port` finds `airport`. Use either keyword without words to list the notes changed most recently.

Results that have every word in the title come first, then those with every word in the note text, then the rest. Within each group the most recently changed notes come first.

## Settings

Open the workflow in Alfred and choose Configure Workflow.

| Setting | Default | What it does |
| --- | --- | --- |
| Search Keyword | `ens` | Keyword for the full search. |
| Title Search Keyword | `ent` | Keyword for the title search. |
| Attachments | On | Also searches the text Evernote has extracted from PDFs and scanned images. |
| Inside words | On | Finds words of three or more letters inside longer words, without typing a star. |
| Database file | Empty | A specific Evernote database to search. Leave empty to use the most recently modified one, which is right for a Mac with one Evernote account. |

## How it works

* The workflow is one shell script, [`Workflow/search.sh`](Workflow/search.sh). It uses only tools that ship with macOS: `bash`, `sqlite3`, `sed`, `tr`, `paste`, `iconv` and `open`. There are no binaries and nothing is downloaded.
* It reads Evernote's local SQLite database and uses the full-text indexes Evernote already keeps there.
* The database is opened read-only and without locks, so Evernote is never held up. The workflow never writes to it.
* Nothing leaves your Mac.

## Limitations

* Only notes that Evernote has synced to this Mac can be found.
* Evernote does not document its database. An Evernote update can change it, and the workflow then needs an update too. When tables it relies on are missing, it reports that this Evernote version stores notes differently.
* Because the database is read without locks, a search made at the moment Evernote saves can show incomplete results. The workflow then searches again, and tells you if Evernote is still saving.
* Up to 40 notes are shown and the first eight words are used.
* Matching inside longer words covers titles and note text, not tags, notebook names or attachment text, and ignores capitals for the letters A to Z only.
* There are no search operators such as `notebook:`, `tag:`, quoted phrases or exclusions.

## Tested with

Evernote 11.35 from the Mac App Store. The workflow also looks in the place where the direct-download version of Evernote keeps its data, but that version, Evernote Teams, shared notebooks and several accounts on one Mac have not been tested. Reports are welcome in the [issues](https://github.com/Compton637/alfred-evernote-search/issues).

## Build from source

The `Workflow` folder holds everything Alfred needs. To package it yourself:

```sh
cd Workflow
zip -r "../Evernote-Search.alfredworkflow" . -x "*.DS_Store"
```

## License and trademarks

Released under the [MIT License](LICENSE).

This workflow is not affiliated with or endorsed by Evernote. Evernote is a trademark of its owner. The icon is an original drawing and does not use Evernote's logo.
