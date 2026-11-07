# web-wiki — User & Technical Requirements

## Rules
- The extension is pure Tcl. It has no C or C++ source and requires no compiler to install.
- Persist Markdown, source baselines and revisions through `tpersist`; render with `cmark_gfm` at request time.
- Render page structure through `jinja2-tcl` templates with typed JSON contexts serialized by `tjson`.
- The host owns the database connection, authentication, CSRF policy and `tpathexp` router.
- Schema initialization and directory imports are explicit maintenance operations. Mounting never initializes or imports data.

## Commandments
- Own `web_wiki_items` and `web_wiki_revisions`; scope every query by domain.
- Install independently of web-blog. Do not add a shared content package or compatibility layer.
- Do not evaluate content as Tcl, SQL or a template program.
- Keep history when a source disappears. Do not treat a missing directory as an empty source.
- Use the public mount convention in [MOUNTING.md](MOUNTING.md) for future web packages.

## Principles
- `::web::wiki` owns its schema, persistence, routes, templates and editor assets. No procedure or runtime dependency is shared with web-blog.
- Database connections and routers belong to their creating interpreter. Create one of each per server worker.
- One source directory owns each `domain` pair. A second sync for the same pair replaces its imported inventory; browser-created pages remain independent.

## Best Practices
- Use a dedicated `tpersist` connection with `-autobegin 0`; explicit import/save transactions commit atomically. If the caller already has a transaction, it owns the final commit.
- Mount specific packages before host catch-all routes.
- Back up the database before maintenance imports. Source changes deliberately supersede browser revisions while preserving their history.

## Generic Guidelines
- `library/` contains Tcl implementation; `library/mount.tcl` contains the public mount entry point.
- `assets/` contains installed templates, styles and the prebuilt Lexical bundle. `frontend/` contains the editable JavaScript source and third-party licenses.
- SQLite through `tdbc::sqlite3` is the supported and integration-tested storage backend for this release. Other `tpersist` dialects are not certified by this package.

## Dependencies and installation

`ttrek.json` declares the Tcl runtime, `tpersist`, `tpathexp`, `cmark-gfm-tcl`, `jinja2-tcl`, `tjson`, and `tdbcsqlite3` dependencies. The SQLite driver supplies its `tdbc` and `sqlite3` dependencies transitively. Lexical build dependencies remain in `package.json`. The public registry provides the native dependency recipes, including `cmark-gfm-tcl`.

Install from the public ttrek registry:

```sh
ttrek install -y web-wiki@0.1.0
```

| Dependency | Tcl package |
| --- | --- |
| Tcl 8.6 or 9.x | `Tcl` |
| tpersist 0.1.0+ | `tpersist` |
| cmark-gfm-tcl 0.1.0+ | `cmark_gfm` |
| tpathexp 1.1.0+ | `tpathexp` |
| jinja2-tcl 0.1.0+ | `jinja2` |
| tjson 1.0.26+ | `tjson` |
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
::web::wiki::initdb $db
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
| `initdb db` | Idempotent creation of the two wiki tables |
| `sync store directory` | Counts: `created`, `revised`, `reactivated`, `deactivated` |
| `load store /path` | Active page/folder dictionary, or `WEB WIKI 404` |
| `children store /folder` | Active immediate children, folders first |
| `history store /path` | Revision dictionaries, newest first, including Markdown |
| `add store /parent title markdown` | New page at a title-derived URL, with revision 1 |
| `save store /path title markdown expectedRevision` | Updated page; stale revision raises `WEB WIKI 409` |
| `mount router -store store ?options...?` | Mount configuration; see [MOUNTING.md](MOUNTING.md) |

`add` and `save` are trusted application APIs. Browser authorization and CSRF checks happen in mounted HTTP handlers. Folders are maintained by imports. Browser creation uses an existing active folder; its title determines the slug.

## Browser creation

Enable browser creation with `-config {allow_create true}` on the mount, alongside
both editor callbacks. The flag defaults to `false` and must be a boolean. It does
not enable editing by itself. The index and item pages show **New page** in edit
mode; the form uses the existing local Markdown editor. Creation is authorized,
CSRF checked and stored atomically with revision 1. Existing URLs, including
inactive items, return 409 instead of being overwritten.

Browser-created items have an empty `source_path` and are stored only in SQLite.
Sync preserves these items and their parent folders, even when a source folder
is removed. A source file colliding with a browser-created URL aborts sync with
409; it cannot silently replace that item. Source-backed items retain their
existing import/update/deactivation behavior.

## Source and persistence behavior

The source root contains Markdown directly; choose a domain-specific subdirectory when importing a larger tree. Both `.md` and `.markdown` files are read recursively. Dotfiles are ignored. Symlinks under the source root are rejected. Empty folders become items too.

The first ATX heading supplies the title, falling back to the filename stem. Folder names and titles become lowercase ASCII slugs: whitespace/dashes collapse, punctuation is removed, and an empty result becomes `wiki-item`. `Policies/Privacy.md` headed `# Privacy Policy` becomes `/policies/privacy-policy`, independent of the mount prefix. Duplicate canonical paths abort the entire import. Changing a source heading changes its URL; the prior URL is deactivated with its history intact.

Tables are `web_wiki_items` and `web_wiki_revisions`, keyed by domain, path and (for revisions) revision number. Wiki has no blog publication-date or collection column. No HTML is stored. Removing files marks rows inactive. Re-adding a URL reactivates it. An unchanged source baseline preserves browser edits; changed source Markdown adds a revision and becomes current. Browser title changes leave the URL fixed. Unchanged saves and imports do not add revisions. Markdown line endings are normalized to LF.

Imports validate the complete tree before writing, then run in a transaction. Browser saves check the expected revision and update it conditionally in the same transaction as the history insert. A source file or submitted Markdown is limited to 1 MiB; URL-encoded form bodies are limited to 4 MiB. The host should also bound requests before reading them.

## Page templates

The saved title supplies the visible page heading. Rendering omits a leading Markdown H1 to avoid a duplicate title; stored Markdown and browser-edited URLs remain unchanged.

`assets/*.html.jinja` owns all HTML structure. The folder index, content view and editor extend `page.html.jinja`; the index includes the card template inside a loop. Navigation, revision history, editor scripts and empty states are also rendered in templates. Tcl handlers supply data instead of concatenating HTML.

`library/templates.tcl` loads and validates the trusted templates once per interpreter, then calls `jinja2::render` with a template dictionary and path. Context strings, arrays and booleans are explicitly typed through `tjson::typed_to_json`. Ordinary values are automatically escaped exactly once. Only `markdown_html`, produced by the safe-mode cmark renderer, uses `|safe`; raw Markdown, titles, form values and navigation labels never do. Content is data and is never parsed as a template. A host can supply its own trusted child template, as the company homepage does, to inherit the same layout.

## Visual editor

The locally bundled Lexical editor supports paragraphs, headings, quotes, bold/italic text, lists, links, undo/redo and a Markdown source toggle. It enhances `textarea[data-markdown-editor]`; the plain textarea works without JavaScript. Opening and saving does not rewrite an unchanged document.

GFM tables render through `cmark_gfm`. Tables, code, images, raw HTML and other constructs outside this rich editor's transformer set automatically stay in source mode, with an explanation shown in the form. This prevents lossy conversions; rich table editing is not implemented.

To rebuild the shipped bundle after editing `frontend/markdown-editor.js`:

```sh
npm ci
npm run build
```

Versions and transitive dependencies are pinned in `package-lock.json`. Third-party MIT licenses are under `frontend/`. No CDN is used.

Mount accepts `-config [dict create master_template $trustedTemplateSource]` to
replace the package page layout for that instance. The optional `templates` config
key supplies additional named template sources. See the mount contract for the
layout blocks and context. `library/initdb.tcl` supplies the public `initdb`
entry point; hosts invoke it explicitly before importing wiki content.

## Schema contract

Version remains `0.1.0`. This implementation uses only wiki-owned tables and
`::web::wiki` procedures. It has no legacy-table reads, migrations or compatibility
wrappers. Initialize the new schema explicitly and import the desired sources;
old browser revisions are not copied automatically.

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
Editing is disabled unless both authorization and CSRF callbacks are supplied. Every editor GET and POST checks authorization. Creation requires `allow_create true`. Every write verifies CSRF; updates also verify the expected revision. SQL values are bound by `tpersist`; metadata is HTML-escaped; content is rendered with cmark's default safe HTML mode. Request paths reject traversal, invalid UTF-8 and encoded separators. Responses carry a restrictive CSP and `nosniff`.

### Pending
Production identity/session management, TLS, rate limiting and transport body limits remain host responsibilities. This release has no upload API, revision restore UI, search, pagination, scheduled publishing or non-SQLite certification.
