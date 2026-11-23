# web-wiki mount and schema contract

The package provides `::web::wiki::mount` in `library/mount.tcl` and
`::web::wiki::initdb` in `library/initdb.tcl`. The package loader sources both.
The implementations, persistence, rendering, templates and assets belong to
web-wiki. No other web application package or commons content package is required.

```tcl
package require web-wiki 1.0.0
::web::wiki::initdb $connection
set store [::web::wiki::create -connection $connection -domain example.test]
::web::wiki::mount $router -store $store -prefix /wiki
```

`initdb connection` creates only `web_wiki_items` and `web_wiki_revisions` and is
safe to repeat. It does not open/close connections, import content, register routes,
or commit a caller's transaction. Rows are isolated by domain within these tables.
There is no compatibility API, shared-table reader, or automatic migration.

`mount router ?options...?` registers fully qualified package handlers on an
existing `tpathexp` router and returns its configuration. It never opens sockets,
creates schema, imports content, commits transactions, or owns the router.
Mount during worker initialization, with specific prefixes before catch-all
routes. Destroy the router to release registrations; there is no unmount API.

| Option | Contract |
| --- | --- |
| `-store` | Required store from this package; connection remains caller-owned |
| `-prefix` | Default `/wiki`; canonical absolute slug path, or `/` |
| `-authorize` | Command prefix required with `-csrf` to enable editing |
| `-csrf` | Command prefix required with `-authorize` |
| `-navigation` | List of `{label /local-path}` links |
| `-config` | Dict with optional `master_template`, `templates`, and boolean `allow_create` (default `false`) |

`create` accepts `-connection`, optional `-domain` and optional `-title`.
`master_template` overrides `page.html.jinja` for this mount's index, item and editor.
It provides `{% block body %}{% endblock %}` and should retain the package's CSS
links and conditional editor script. The template context includes `title`,
`brand`, `home`, `assets`, `navigation` and `editing`. Templates are trusted host
configuration, never request/Markdown data. Unknown config keys and invalid
templates fail before route registration. Other mounts keep their own defaults.

| Relative route | Method | Behavior |
| --- | --- | --- |
| `/` and the bare prefix | GET/HEAD | Wiki folder index |
| `/<path>` | GET/HEAD | Render an active item |
| `/_assets/<asset>` | GET/HEAD | Serve a package-owned allowlisted asset |
| `/_new` or `/_new/<parent>` | GET/HEAD | Authorized creation form; requires `allow_create true` |
| `/_new` or `/_new/<parent>` | POST | Authorized, CSRF-checked creation and 303 redirect |
| `/_edit/<path>` | GET/HEAD | Authorized editor form |
| `/_edit/<path>` | POST | Authorized, CSRF-checked revision save and 303 redirect |

Request handlers receive `request context params` and return dictionaries with
`statusCode`, `headers`, and `body`. The router handles HEAD bodies and 404/405.
The underscore route segments are reserved. Hosts retain the original request
fields, authentication context and headers during dispatch.

Authorization callback: `callback request context action path` returns a boolean.
Action is `edit` or `save` for existing items, or `create` for both creation-form and creation-POST requests. For `create`, path identifies the existing parent folder; other actions identify the item. Paths are canonical and relative to the mount.
CSRF callback: `callback issue request context {}` returns a nonempty session token;
`callback verify request context submittedToken` returns a boolean. The host owns
identity, session/token generation, and login challenges. Callback errors propagate.
Denied authorization/CSRF returns 403; missing editor policy returns 404.

POST accepts URL-encoded `title`, `markdown`, `revision`, and `csrf`. Base64 Lambda
bodies are supported. Duplicate/missing fields, invalid encodings and oversized
content are rejected. Package errors use `{WEB WIKI <HTTP-status>}`; handlers
convert these to responses while unexpected errors propagate to the host.

Creation POST accepts URL-encoded `title`, `markdown`, and `csrf`. It has no revision field. Creation requires both editor callbacks and `allow_create true`; otherwise it returns 404. The title determines the URL. A duplicate URL returns 409. The new item and initial revision commit atomically.

## Properties from the host on each request

The optional `-context commandPrefix` callback receives `request context` and
returns a dictionary of **typed Jinja values**, using `tjson` notation (`S`,
`BOOL`, `N`, `L`, `M`). It runs once for each page request, including editor
pages, and does not run for assets. Its values override the package's template
values for that request only. This lets a host supply navigation, member details,
feature flags, or other properties without coupling the package to a host.

```tcl
proc site_properties {request context} {
    set signedIn [dict exists $context member]
    dict create show_edit_controls [list BOOL $signedIn] \
        site_name [list S {Our neighborhood}]
}
# Add this option to the mount call:
# -context ::site_properties
```

`show_edit_controls` defaults to `{BOOL 1}`. Set it to `{BOOL 0}` to hide the
add/edit links in the built-in templates. Links are generated only when
`-authorize` allows `edit` for the item or `create` for its parent. Creation also
requires `allow_create true`. The callback is evaluated on page views as well as
editor routes and should have no side effects. Visibility does not grant access:
authorization and CSRF are checked again on every editor request. Only trusted
host code may supply template properties; do not
merge arbitrary request fields into them. Invalid callback results are host
configuration errors and propagate to the host's error handler.

## Editor colors

The editor supplies fallback colors for its border, background, text and focus
outline. Host HSL theme variables remain optional and override those defaults.
Visual and Markdown source modes share the same visible content-area styling.

## Shared image rendering

`-render-markdown` accepts a trusted command prefix taking Markdown and returning
safe HTML. The host can pass `::web::static::wiki::render_content` bound to an
`image_store`, so editable pages use the same validated local/CDN image URLs as
static content. The callback also validates new and edited pages before saving.
Expected validation errors use `{WEB CONTENT status}`. The callback must render
raw HTML and unsafe URLs safely, as the default cmark-gfm renderer does.

## Editing permissions with web-user

Bind `wiki.edit` to the authorization callback for creating and editing wiki
content. Sign-in alone and `forum.moderate` do not supply this grant.

```tcl
::web::wiki::mount $router -store $contentStore \
    -authorize [list ::web::user::authorize_permission $accountMount wiki.edit] \
    -csrf [list ::web::user::csrf $accountMount] -config {allow_create true}
```

Assign the permission through web-user's groups configuration and synchronize it
through the host's initialization or maintenance task. The package uses the same
authorizer for visible controls and server access checks, including submission
of an editor form opened before permission was revoked.
