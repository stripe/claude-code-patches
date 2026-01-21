This is a project that is solely a GitHub workflow, a shell script, and GitHub releases.

The goal is to:

- download the latest stable version of Claude Code, and the previous 3 stable versions.
- run bsdiff from each old version to the latest version
- store the bsdiff in a GitHub release tagged with the latest version number
    - e.g. from-$oldVersionNumber.bsdiff is the filename, at v$latest
- before storing the bsdiff, make sure the bspatch applies and produces the correct shasum from the manifest
