# RFC 8785 (JCS) test vectors

The `*.input.json` / `*.output.json` pairs in this folder are copied unchanged, only renamed, from the `testdata`
folder of https://github.com/cyberphone/json-canonicalization (`testdata/input/<name>.json` becomes
`<name>.input.json`, `testdata/output/<name>.json` becomes `<name>.output.json`).

Copyright 2018 Anders Rundgren. Licensed under the Apache License, Version 2.0
(http://www.apache.org/licenses/LICENSE-2.0). The files are provided "AS IS", without warranties or conditions of any
kind. This notice replaces the license header the upstream repository keeps in its root `LICENSE`; the same pairs are
read by the Swift JCS tests (slice m3-02). Output files have no trailing newline: compare bytes exactly.
