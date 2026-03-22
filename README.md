# LinkedIn Applications Tracker

This repository provides tools to parse LinkedIn/job emails, sync TXT archives, and manage applications in SQL + GUI.

## Release

Current release: `0.9.3`

## What This Repository Contains

- `scripts/update_linkedin_applications.py`  
  Parses `.txt` emails and updates Obsidian markdown summaries.
- `scripts/folder_shell_sql.py`  
  SQL-backed terminal shell for browsing folder hierarchy.
- `scripts/linkedin_applications_gui_sql.py`  
  Python GUI (PySide6) with SQLite, auto-classification, and manual status control.
- `LinkInJob/`  
  Native macOS SwiftUI app that works with the same pipeline and SQLite DB.

## Project Structure

- `scripts/setup_rclone_drive.sh` — configure `rclone` remote for Google Drive.
- `scripts/sync_drive_rclone.sh` — sync TXT archive from Google Drive.
- `scripts/setup_argos_runtime.sh` — install local Argos Translate runtime.
- `scripts/update_linkedin_applications.py` — update markdown summaries.
- `scripts/folder_shell_sql.py` — terminal SQL shell.
- `scripts/linkedin_applications_gui_sql.py` — Python GUI for applications.
- `LinkInJob/scripts/build_and_install_app.sh` — build and install macOS app to `/Applications/LinkInJob.app`.

## Requirements

- Python 3
- `PySide6` (for Python GUI):

```bash
python3 -m pip install PySide6
```

- Optional: `rclone` (for Google Drive sync)
- For `LinkInJob` (SwiftUI): Xcode / Swift toolchain

## Default Paths

- TXT email archive:  
  `$HOME/Library/Application Support/DriveCVSync/LinkedIn Archive`
- Applications SQLite DB:  
  `$HOME/Library/Application Support/LinkInJob/applications.db`
- Last sync log (LinkInJob):  
  `$HOME/Library/Application Support/LinkInJob/Logs/last_sync.log`

## Usage

### 1) Update Obsidian markdown from TXT emails

```bash
python3 scripts/update_linkedin_applications.py
```

Override paths:

```bash
python3 scripts/update_linkedin_applications.py \
  --source-dir "/path/to/email-txt-files" \
  --target-file "/path/to/output.md"
```

### 2) SQL shell (terminal)

```bash
python3 scripts/folder_shell_sql.py
```

With custom source/DB:

```bash
python3 scripts/folder_shell_sql.py \
  "/path/to/source-folder" \
  --db "/path/to/hierarchy.db" \
  --sync-first
```

### 3) Python GUI for applications (PySide6)

```bash
python3 scripts/linkedin_applications_gui_sql.py \
  --source-dir "$HOME/Library/Application Support/DriveCVSync/LinkedIn Archive"
```

What it does:

- Reads `.txt` emails from `--source-dir`.
- Auto-classifies records into: `Inbox`, `Applied`, `Reject`, `Interview`, `Manual Sort`, `Archive`.
- Stores all data in SQLite (including manual status changes).
- Supports multiple job links in one email (1 link = 1 record).
- Fetches `About the job` from LinkedIn URL when available.

### 4) Native macOS app (SwiftUI)

Build and install:

```bash
cd LinkInJob
./scripts/build_and_install_app.sh
```

Installed app path:

`/Applications/LinkInJob.app`

### 5) Google Drive sync

If `rclone` is configured:

```bash
./scripts/sync_drive_rclone.sh
```

## Gmail Apps Script -> TXT Archive

A Google Apps Script in Gmail/Drive exports LinkedIn emails to plain `.txt` files.
These files are consumed by the parser/sync pipeline in this repository.

Drive archive folder:

`LinkedIn Archive`

Tracking spreadsheet:

`LinkedIn_Job_Tracker`

Current script:

```javascript
function processLinkedInArchive() {
  const now = new Date();
  const hours = now.getHours();

  // Skip from 00:00 to 08:00
  if (hours >= 0 && hours < 8) {
    console.log("Night mode. Skipping run.");
    return;
  }

  const LABEL_NAME = "LinkedIn";
  const FOLDER_NAME = "LinkedIn Archive";
  const SPREADSHEET_NAME = "LinkedIn_Job_Tracker";

  // 1. Find folder
  let folders = DriveApp.getFoldersByName(FOLDER_NAME);
  let folder = folders.hasNext() ? folders.next() : DriveApp.createFolder(FOLDER_NAME);

  // 2. Find tracking spreadsheet
  let ss;
  let files = DriveApp.getFilesByName(SPREADSHEET_NAME);
  if (files.hasNext()) {
    ss = SpreadsheetApp.open(files.next());
  } else {
    ss = SpreadsheetApp.create(SPREADSHEET_NAME);
    ss.getSheets()[0].appendRow(["Date", "Company", "Status", "Drive File"]);
  }
  let sheet = ss.getSheets()[0];

  // 3. Get emails
  let label = GmailApp.getUserLabelByName(LABEL_NAME);
  if (!label) return;

  let threads = label.getThreads(0, 15);

  threads.forEach(thread => {
    let messages = thread.getMessages();
    let lastMsg = messages[messages.length - 1];
    let subject = lastMsg.getSubject();
    let date = lastMsg.getDate();
    let formattedDate = Utilities.formatDate(date, Session.getScriptTimeZone(), "yyyy-MM-dd_HH-mm");

    let fileName = `${formattedDate} - ${subject.replace(/[/\\?%*:|"<>]/g, "")}.txt`;

    if (!folder.getFilesByName(fileName).hasNext()) {
      let content = `From: ${lastMsg.getFrom()}\nDate: ${date}\nSubject: ${subject}\n\n${lastMsg.getPlainBody()}`;
      let newFile = folder.createFile(fileName, content);

      let status = "Applied";
      let body = lastMsg.getPlainBody().toLowerCase();
      if (body.includes("viewed your application")) status = "Viewed";
      if (body.includes("unfortunately") || body.includes("not moving forward")) status = "Rejected";

      sheet.appendRow([date, subject, status, newFile.getUrl()]);
      console.log("Added: " + fileName);
    }
  });
}
```

## GitHub

Repository:  
[https://github.com/G5023890/LinkedIn](https://github.com/G5023890/LinkedIn)

## License

This project is licensed under Apache-2.0.  
See `/Users/grigorymordokhovich/Documents/Develop/LinkedIn/LICENSE`.
