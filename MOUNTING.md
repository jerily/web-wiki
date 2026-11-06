# web-wiki mount and schema contract

The package provides `::web::wiki::mount` in `library/mount.tcl` and
`::web::wiki::initdb` in `library/initdb.tcl`. The package loader sources both.
The implementations, persistence, rendering, templates and assets belong to
web-wiki. No other web application package or commons content package is required.

```tcl
package require web-wiki 0.1.0
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
| `-config` | Dict with optional `master_template` source and `templates` name/source dict |

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
| `/_edit/<path>` | GET/HEAD | Authorized editor form |
| `/_edit/<path>` | POST | Authorized, CSRF-checked revision save and 303 redirect |

Request handlers receive `request context params` and return dictionaries with
`statusCode`, `headers`, and `body`. The router handles HEAD bodies and 404/405.
The underscore route segments are reserved. Hosts retain the original request
fields, authentication context and headers during dispatch.

Authorization callback: `callback request context action path` returns a boolean.
Action is `edit` or `save`; path is canonical and relative to the mount.
CSRF callback: `callback issue request context {}` returns a nonempty session token;
`callback verify request context submittedToken` returns a boolean. The host owns
identity, session/token generation, and login challenges. Callback errors propagate.
Denied authorization/CSRF returns 403; missing editor policy returns 404.

POST accepts URL-encoded `title`, `markdown`, `revision`, and `csrf`. Base64 Lambda
bodies are supported. Duplicate/missing fields, invalid encodings and oversized
content are rejected. Package errors use `{WEB WIKI <HTTP-status>}`; handlers
convert these to responses while unexpected errors propagate to the host.
