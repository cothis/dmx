# Release notes

One file per release, `<version>.md`, holding the "Changes since <previous>" section that
`scripts/release.py` folds into the generated NOTES.md before it writes SHA256SUMS. Only a person
can write it, and `make release` refuses to package a version without one (`--no-notes` to skip
deliberately). 0.2.2, 0.3.0 and 0.3.1 were pasted in by hand, which is the step this exists to
stop people forgetting; 0.3.0's and 0.3.1's text is kept here as it was published.
