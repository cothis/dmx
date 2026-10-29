# One-time distribution upload, 2026-10-29

The maintainer explicitly approved an exception to the no-GitHub-CI decision for one manual,
upload-only job. Application builds, signing, notarization and acceptance tests stayed on the Mac.
The active workflow is removed after this job; `workflow.yml` here is an inactive evidence copy.

[Run 40888198984](https://github.com/cothis/dmx/actions/runs/40888198984) succeeded at head
`b13b0216ebdfd98548659bf62be2d53f5eb22786`. The pinned previous public source archive is unchanged
in its source payloads. Only the outer archive root and three README version references change.
Local reconstruction and the GitHub job both produced the exact qualified v0.4.0 archive:
496,209,920 bytes, SHA256 `ff958e5f94157f84c34c64fda74ab5fbdcc3726627740c0dfd29bf898b882579`.
The upload goes only to the existing draft release ID 427835061. Publication and downloaded
acceptance remain with the local release process.

Actual `claude-opus-5-5` first identified a tag-based target lookup. The corrected job validates
the release ID, tag and draft status, then uploads through that ID's fixed `upload_url`.
The final read-only review approved it. Original reports and model identity are included here.
There is no repository checkout, third-party action, signing key or custom token in this job;
its standard ephemeral token has contents-write only on the one manual job.
