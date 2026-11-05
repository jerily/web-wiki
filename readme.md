# web-wiki — User & Technical Requirements

## Rules
- The extension is pure Tcl. It has no C or C++ source and requires no compiler to install.
- Persist Markdown, source baselines and revisions through `tpersist`; render with `cmark_gfm` at request time.
- The host owns the database connection, authentication, CSRF policy and `tpathexp` router.
- Schema initialization and directory imports are explicit maintenance operations. Mounting never initializes or imports data.

## Commandments
- Keep all queries scoped by collection and domain.
- Do not evaluate content as Tcl, SQL or a template program.
- Keep history when a source disappears. Do not treat a missing directory as an empty source.
- Use the public mount convention in [MOUNTING.md](MOUNTING.md) for future web packages.

## Principles
- `::web::wiki` owns wiki behavior; shared publishing code lives in `::web::content` inside this distribution. `web-blog` depends on this package and reuses that code and the editor assets.
- Database connections and routers belong to their creating interpreter. Create one of each per server worker.
- One source directory owns each `(collection, domain)` pair. A second sync for the same pair replaces its published inventory.

## Best Practices
- Use a dedicated `tpersist` connection with `-autobegin 0`; explicit import/save transactions commit atomically. If the caller already has a transaction, it owns the final commit.
- Mount specific packages before host catch-all routes.
- Back up the database before maintenance imports. Source changes deliberately supersede browser revisions while preserving their history.

## Generic Guidelines
- `library/` contains Tcl implementation; `library/mount.tcl` contains the public mount entry point.
- `assets/` contains installed templates, styles and the prebuilt Lexical bundle. `frontend/` contains the editable JavaScript source and third-party licenses.
- SQLite through `tdbc::sqlite3` is the supported and integration-tested storage backend for this release. Other `tpersist` dialects are not certified by this package.

## Dependencies and installation

`ttrek.json` declares the Tcl runtime, `tpersist`, `tpathexp`, `cmark-gfm-tcl`, and `tdbcsqlite3` dependencies. The SQLite driver supplies its `tdbc` and `sqlite3` dependencies transitively. Lexical build dependencies remain in `package.json`. The selected ttrek registry must contain a `cmark-gfm-tcl` recipe; it is not present in the current local registry.

| Dependency | Tcl package |
| --- | --- |
| Tcl 8.6 or 9.x | `Tcl` |
| tpersist 0.1.0+ | `tpersist` |
| cmark-gfm-tcl 0.1.0+ | `cmark_gfm` |
| tpathexp 1.1.0+ | `tpathexp` |
| SQLite TDBC adapter | `tdbc::sqlite3` |

Native dependencies must match the Tcl host ABI. This package itself is sourced Tcl and works with either loadable dependencies or dependencies registered statically by an embedded host.

Use the source checkout by adding its directory to `auto_path`/`TCLLIBPATH`, or install it:

```sh
cmake -S . -B build -DTCLSH=tclsh9.1
cmake --install build --prefix "$PWD/stage"
```

The result is `stage/lib/web-wiki0.1.0`. Add `stage/lib` and dependency package locations to `TCLLIBPATH`. CMake uses `LANGUAGES NONE`; Node is unnecessary for installation or runtime. CTest needs the runtime dependencies on the Tcl search path.

## Usage

```tcl
package require web-wiki 0.1.0
set db [::tpersist::db_connect -database company.sqlite -autobegin 0]

# Maintenance only; do this before starting request workers.
::web::wiki::init_schema $db
set wiki [::web::wiki::create -connection $db -domain example.com -title {Company Wiki}]
::web::wiki::sync $wiki ./content/wiki

# The host may already have this router and other routes.
set router [::tpathexp::router]
::web::wiki::mount $router -store $wiki -prefix /wiki
set response [$router dispatch {method GET path /wiki}]

$router destroy
::tpersist::db_disconnect $db
```

`create` returns an immutable Tcl dictionary describing the caller-owned connection and collection. It does not allocate a connection or create tables. There is no store destructor.

| Command | Result |
| --- | --- |
| `create -connection db ?-domain default? ?-title Wiki?` | Store configuration |
| `init_schema db` | Idempotent creation of the two shared tables |
| `sync store directory` | Counts: `created`, `revised`, `reactivated`, `deactivated` |
| `load store /path` | Active page/folder dictionary, or `WEB CONTENT 404` |
| `children store /folder` | Active immediate children, folders first |
| `history store /path` | Revision dictionaries, newest first, including Markdown |
| `save store /path title markdown expectedRevision` | Updated page; stale revision raises `WEB CONTENT 409` |
| `mount router -store store ?options...?` | Mount configuration; see [MOUNTING.md](MOUNTING.md) |

`save` is a trusted application API. Browser authorization and CSRF checks happen in mounted HTTP handlers. Pages are created from source files; the initial editor revises existing pages only. Folders are maintained by imports.

## Source and persistence behavior

The source root contains Markdown directly; choose a domain-specific subdirectory when importing a larger tree. Both `.md` and `.markdown` files are read recursively. Dotfiles are ignored. Symlinks under the source root are rejected. Empty folders become items too.

The first ATX heading supplies the title, falling back to the filename stem. Folder names and titles become lowercase ASCII slugs: whitespace/dashes collapse, punctuation is removed, and an empty result becomes `wiki-item`. `Policies/Privacy.md` headed `# Privacy Policy` becomes `/policies/privacy-policy`, independent of the mount prefix. Duplicate canonical paths abort the entire import. Changing a source heading changes its URL; the prior URL is deactivated with its history intact.

Tables are `web_content_items` and `web_content_revisions`, keyed by collection, domain, path and (for revisions) revision number. No HTML is stored. Removing files marks rows inactive. Re-adding a URL reactivates it. An unchanged source baseline preserves browser edits; changed source Markdown adds a revision and becomes current. Browser title changes leave the URL fixed. Unchanged saves and imports do not add revisions. Markdown line endings are normalized to LF.

Imports validate the complete tree before writing, then run in a transaction. Browser saves check the expected revision and update it conditionally in the same transaction as the history insert. A source file or submitted Markdown is limited to 1 MiB; URL-encoded form bodies are limited to 4 MiB. The host should also bound requests before reading them.

## Visual editor

The locally bundled Lexical editor supports paragraphs, headings, quotes, bold/italic text, lists, links, undo/redo and a Markdown source toggle. It enhances `textarea[data-markdown-editor]`; the plain textarea works without JavaScript. Opening and saving does not rewrite an unchanged document.

GFM tables render through `cmark_gfm`. Tables, code, images, raw HTML and other constructs outside this rich editor's transformer set automatically stay in source mode, with an explanation shown in the form. This prevents lossy conversions; rich table editing is not implemented.

To rebuild the shipped bundle after editing `frontend/markdown-editor.js`:

```sh
npm ci
npm run build
```

Versions and transitive dependencies are pinned in `package-lock.json`. Third-party MIT licenses are under `frontend/`. No CDN is used.

## Verification

```sh
tclsh9.1 tests/all.tcl
ctest --test-dir build --output-on-failure
```

Tests exercise real `tpersist`, SQLite, `cmark_gfm` and `tpathexp`, including source lifecycle, revisions, routing, Lambda body adaptation and request protection. The example site contains an optional browser integration test. Tcl 9.1 is exercised in the complete integration suite; Tcl 8.6 requires matching native dependencies and its SQLite TDBC driver.

## Security
### Surface
Public content/folder routes, an allowlist of local assets, and optional editor forms. Source directories and database connections are trusted host configuration.

### Protections
Editing is disabled unless both authorization and CSRF callbacks are supplied. Every editor GET and POST checks authorization. POST verifies CSRF and expected revision. SQL values are bound by `tpersist`; metadata is HTML-escaped; content is rendered with cmark's default safe HTML mode. Request paths reject traversal, invalid UTF-8 and encoded separators. Responses carry a restrictive CSP and `nosniff`.

### Pending
Production identity/session management, TLS, rate limiting and transport body limits remain host responsibilities. This release has no upload API, creation form, revision restore UI, search, pagination, scheduled publishing or non-SQLite certification.
