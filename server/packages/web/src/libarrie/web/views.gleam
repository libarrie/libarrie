//// HTML views. Every container that renders user text (notebook names,
//// transcripts, snippets) carries `hx-disable` as defense in depth; Lustre
//// escapes all text and attribute values. No inline styles or scripts.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import libarrie/domain/admin.{type Role, Admin, Owner}
import libarrie/domain/api_keys.{type ApiKey}
import libarrie/domain/notebooks.{type Notebook}
import libarrie/domain/pages.{type Page}
import libarrie/web/ui
import lustre/attribute.{attribute, class}
import lustre/element.{type Element}
import lustre/element/html

pub fn user_text(tag: fn(List(attribute.Attribute(a)), List(Element(a))) -> Element(a), classes: String, text: String) -> Element(a) {
  tag([class(classes), attribute("hx-disable", "")], [html.text(text)])
}

pub fn heading(title: String, actions: List(Element(a))) -> Element(a) {
  html.div([class("page-heading")], [html.h1([], [html.text(title)]), html.div([class("actions")], actions)])
}

// Landing -----------------------------------------------------------------------------

pub fn landing() -> List(Element(a)) {
  [
    html.section([class("hero")], [
      html.img([
        attribute.src("/static/img/icon.png"),
        attribute.alt("Libarrie notebooks logo"),
        attribute("width", "96"),
        attribute("height", "96"),
      ]),
      html.h1([], [html.text("Find what you wrote.")]),
      html.p([class("lede")], [
        html.text(
          "Photograph your handwritten notebooks, then search them to find the notebook and page you need.",
        ),
      ]),
      html.a([attribute.href("/auth/login"), class("button large")], [html.text("Sign in")]),
    ]),
  ]
}

// Notebooks ---------------------------------------------------------------------------

pub fn notebooks_page(items: List(Notebook), csrf: String, error: Option(String)) -> List(Element(a)) {
  [
    heading("Notebooks", []),
    create_notebook_form(csrf, error),
    notebook_list(items),
  ]
}

pub fn notebook_list(items: List(Notebook)) -> Element(a) {
  case items {
    [] ->
      html.p([attribute.id("notebook-list"), class("empty")], [
        html.text("No notebooks yet. Create one to start adding pages."),
      ])
    _ ->
      html.ul(
        [attribute.id("notebook-list"), class("card-grid")],
        list.map(items, fn(nb) {
          html.li([class("card notebook-card")], [
            html.a([attribute.href("/notebooks/" <> nb.id), class("card-link")], [
              html.div([class("notebook-title")], [swatch(nb.color), user_text(html.h2, "notebook-name", nb.name)]),
            ]),
            case nb.description {
              "" -> element.none()
              d -> user_text(html.p, "muted", d)
            },
            html.p([class("muted small")], [
              html.text(int.to_string(nb.page_count) <> pages_word(nb.page_count)),
            ]),
          ])
        }),
      )
  }
}

fn pages_word(n: Int) -> String {
  case n {
    1 -> " page"
    _ -> " pages"
  }
}

pub fn create_notebook_form(csrf: String, error: Option(String)) -> Element(a) {
  html.form(
    [
      attribute.id("create-notebook"),
      class("card inline-form"),
      attribute.method("post"),
      attribute.action("/notebooks"),
      attribute("hx-post", "/notebooks"),
      attribute("hx-target", "#notebooks-region"),
      attribute("hx-select", "#notebooks-region"),
      attribute("hx-swap", "outerHTML"),
    ],
    [
      ui.csrf_field(csrf),
      html.label([attribute.for("notebook-name")], [html.text("New notebook")]),
      html.div([class("row")], [
        html.input([
          attribute.id("notebook-name"),
          attribute.name("name"),
          attribute("required", ""),
          attribute("maxlength", "200"),
          attribute("placeholder", "For example, Blue work notebook"),
        ]),
        html.button([attribute.type_("submit"), class("button")], [html.text("Create")]),
      ]),
      html.details([class("more-options")], [
        html.summary([], [html.text("Description and color")]),
        html.label([attribute.for("notebook-description")], [html.text("Description (optional)")]),
        html.div([attribute("hx-disable", "")], [
          html.textarea(
            [
              attribute.id("notebook-description"),
              attribute.name("description"),
              attribute("maxlength", "2000"),
              attribute("rows", "2"),
            ],
            "",
          ),
        ]),
        color_choices(None),
      ]),
      case error {
        Some(message) -> ui.alert("danger", message)
        None -> element.none()
      },
    ],
  )
}

// Notebook detail ------------------------------------------------------------------------

pub fn notebook_page(
  nb: Notebook,
  items: List(Page),
  next_cursor: Option(Int),
  csrf: String,
  message: Option(#(String, String)),
) -> List(Element(a)) {
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/notebooks")], [html.text("Notebooks")]),
    ]),
    notice(message),
    html.div([class("page-heading")], [
      html.div([class("notebook-title")], [swatch(nb.color), user_text(html.h1, "", nb.name)]),
      html.div([class("actions")], [
        html.a([attribute.href("/notebooks/" <> nb.id <> "/upload"), class("button")], [
          html.text("Add pages"),
        ]),
      ]),
    ]),
    case nb.description {
      "" -> element.none()
      d -> user_text(html.p, "muted", d)
    },
    case items {
      [] ->
        html.p([class("empty")], [
          html.text("No pages yet. Add photographs of this notebook's pages."),
        ])
      _ -> html.ol([attribute.id("page-grid"), class("page-grid")], page_tiles(nb.id, items, next_cursor))
    },
    notebook_settings(nb, csrf),
  ]
}

pub fn page_tiles(notebook_id: String, items: List(Page), next_cursor: Option(Int)) -> List(Element(a)) {
  let tiles =
    list.map(items, fn(page) {
      html.li([class("page-tile")], [
        html.a([attribute.href("/pages/" <> page.id)], [
          thumbnail(page),
          html.span([class("page-number")], [html.text("Page " <> int.to_string(page.page_number))]),
          status_badge(pages.processing_status(page)),
        ]),
      ])
    })
  case next_cursor {
    None -> tiles
    Some(cursor) ->
      list.append(tiles, [
        html.li([class("load-more")], [
          html.button(
            [
              class("button secondary"),
              attribute(
                "hx-get",
                "/notebooks/" <> notebook_id <> "/pages?cursor=" <> int.to_string(cursor),
              ),
              attribute("hx-target", "closest li"),
              attribute("hx-swap", "outerHTML"),
            ],
            [html.text("Load more pages")],
          ),
        ]),
      ])
  }
}

pub fn thumbnail(page: Page) -> Element(a) {
  case page.source_object_id, page.has_derived {
    Some(id), True ->
      html.img([
        attribute.src("/img/" <> id <> "/thumb"),
        attribute.alt("Page " <> int.to_string(page.page_number)),
        attribute("loading", "lazy"),
        class("thumb"),
      ])
    _, _ ->
      html.div([class("thumb placeholder"), attribute("aria-hidden", "true")], [
        html.text(int.to_string(page.page_number)),
      ])
  }
}

pub fn status_label(status: String) -> #(String, String) {
  case status {
    "ready" -> #("ok", "Searchable")
    "ready_empty" -> #("ok", "Blank page")
    "awaiting_processing" -> #("muted", "Waiting for processing")
    "queued" | "accepted" -> #("progress", "Queued")
    "recognizing" -> #("progress", "Reading handwriting")
    "indexing" -> #("progress", "Indexing")
    "awaiting_upload" -> #("progress", "Uploading")
    "needs_user_action" -> #("warning", "Needs your attention")
    "failed" -> #("danger", "Processing failed")
    "cancelled" -> #("muted", "Cancelled")
    other -> #("muted", string.replace(other, "_", " "))
  }
}

pub fn status_badge(status: String) -> Element(a) {
  let #(kind, label) = status_label(status)
  html.span([class("badge " <> kind)], [html.text(label)])
}

pub fn is_processing(status: String) -> Bool {
  list.contains(["queued", "recognizing", "indexing", "awaiting_upload", "accepted"], status)
}

// Page detail -----------------------------------------------------------------------------

pub type Transcript {
  Transcript(id: String, text: String, origin: String, blank: Bool)
}

pub type Detail {
  Detail(
    transcript: Option(Transcript),
    candidate: Option(#(String, String)),
    operation_status: Option(String),
    operation_error: Option(String),
  )
}

pub fn page_detail(
  page: Page,
  detail: Detail,
  csrf: String,
  notebooks: List(Notebook),
  integrity: String,
  rescan_operation_id: String,
  account_id: String,
  message: Option(#(String, String)),
) -> List(Element(a)) {
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/notebooks")], [html.text("Notebooks")]),
      html.text(" / "),
      html.a([attribute.href("/notebooks/" <> page.notebook_id), attribute("hx-disable", "")], [
        html.text(page.notebook_name),
      ]),
    ]),
    heading("Page " <> int.to_string(page.page_number), [
      html.a([attribute.href("/pages/" <> page.id <> "/original"), class("button secondary")], [
        html.text("Open original"),
      ]),
    ]),
    notice(message),
    html.div([class("detail-layout")], [
      html.figure([class("scan-frame")], [
        case page.source_object_id, page.has_derived {
          Some(id), True ->
            html.img([
              attribute.src("/img/" <> id <> "/preview"),
              attribute.alt("Scan of page " <> int.to_string(page.page_number)),
              class("scan"),
            ])
          // Until a preview exists (or without a decoder), show the original
          // through its authorized, short-lived signed URL.
          Some(_), False ->
            html.img([
              attribute.src("/pages/" <> page.id <> "/original"),
              attribute.alt("Scan of page " <> int.to_string(page.page_number)),
              class("scan"),
            ])
          None, _ -> html.p([class("muted")], [html.text("The image is still uploading.")])
        },
      ]),
      html.div([], [
        processing_status(page, detail, False),
        transcript_panel(page, detail, csrf, None, None),
        page_location_form(page, notebooks, csrf),
        page_scan_actions(page, csrf, integrity, rescan_operation_id, account_id),
        trash_form(page, csrf),
      ]),
    ]),
  ]
}

pub fn processing_status(page: Page, detail: Detail, watching: Bool) -> Element(a) {
  let status = pages.processing_status(page)
  let polling = is_processing(status)
  let attrs = case polling {
    True -> [
      attribute("hx-get", "/pages/" <> page.id <> "/status?watching=1"),
      attribute("hx-trigger", "every 3s"),
      attribute("hx-swap", "outerHTML"),
    ]
    False -> []
  }
  let _ = watching
  html.div([attribute.id("processing-status"), class("status-line"), ..attrs], [
    status_badge(status),
    case status, detail.operation_error {
      "needs_user_action", Some("unreadable") ->
        html.p([], [html.text("The handwriting could not be read reliably. You can type the text below or rescan the page.")])
      "needs_user_action", Some("no_text_detected") ->
        html.p([], [html.text("No text was detected. If the page is blank, confirm it below; otherwise type the text.")])
      "needs_user_action", Some(_) ->
        html.p([], [html.text("This page needs your attention: the content could not be recognized.")])
      "failed", _ ->
        html.p([], [html.text("Processing failed for a temporary reason. Your allowance for this page is held for a retry.")])
      _, _ -> element.none()
    },
    case pages.indexing_pending(page) && status == "ready" {
      True -> html.p([class("muted small")], [html.text("Search is catching up with your latest edit.")])
      False -> element.none()
    },
  ])
}

/// The transcript editor. On a conflict, `conflict` explains it and
/// `unsaved` preserves the user's text so nothing is lost.
pub fn transcript_panel(
  page: Page,
  detail: Detail,
  csrf: String,
  conflict: Option(String),
  unsaved: Option(String),
) -> Element(a) {
  let current = case detail.transcript {
    Some(t) -> t.text
    None -> ""
  }
  let editable = page.revision_id != None
  html.section([attribute.id("transcript-panel"), class("card")], [
    html.h2([], [html.text("Transcript")]),
    case conflict {
      Some(message) -> ui.alert("warning", message)
      None -> element.none()
    },
    case unsaved {
      Some(text) ->
        html.details([class("unsaved")], [
          html.summary([], [html.text("Your unsaved text")]),
          html.div([attribute("hx-disable", "")], [
            html.textarea([attribute("readonly", ""), attribute("rows", "6"), class("mono")], text),
          ]),
        ])
      None -> element.none()
    },
    case detail.transcript {
      Some(t) ->
        html.p([class("muted small")], [
          html.text(case t.origin, t.blank {
            _, True -> "Confirmed blank page."
            "user", _ -> "Edited by you."
            _, _ -> "Recognized text. Recognition can make mistakes; correct anything that looks wrong."
          }),
        ])
      None -> element.none()
    },
    case editable {
      False -> element.none()
      True ->
        html.form(
          [
            attribute.method("post"),
            attribute.action("/pages/" <> page.id <> "/transcript"),
            attribute("hx-post", "/pages/" <> page.id <> "/transcript"),
            attribute("hx-target", "#transcript-panel"),
            attribute("hx-swap", "outerHTML"),
          ],
          [
            ui.csrf_field(csrf),
            hidden("source_revision_id", option.unwrap(page.revision_id, "")),
            hidden("content_version", int.to_string(page.content_version)),
            hidden("base_transcript_revision_id", option.unwrap(page.transcript_revision_id, "")),
            html.label([attribute.for("transcript-text"), class("visually-hidden")], [
              html.text("Transcript text"),
            ]),
            html.div([attribute("hx-disable", "")], [
              html.textarea(
                [
                  attribute.id("transcript-text"),
                  attribute.name("text"),
                  attribute("rows", "14"),
                  class("transcript"),
                ],
                current,
              ),
            ]),
            html.div([class("row")], [
              html.button(
                [attribute.type_("submit"), attribute.name("action"), attribute.value("save"), class("button")],
                [html.text("Save transcript")],
              ),
              html.button(
                [
                  attribute.type_("submit"),
                  attribute.name("action"),
                  attribute.value("confirm_blank"),
                  class("button secondary"),
                ],
                [html.text("Mark as blank page")],
              ),
            ]),
          ],
        )
    },
  ])
}

fn hidden(name: String, value: String) -> Element(a) {
  html.input([attribute.type_("hidden"), attribute.name(name), attribute.value(value)])
}

fn trash_form(page: Page, csrf: String) -> Element(a) {
  html.form(
    [attribute.method("post"), attribute.action("/pages/" <> page.id <> "/trash"), class("danger-zone")],
    [
      ui.csrf_field(csrf),
      hidden("version", int.to_string(page.version)),
      html.button([attribute.type_("submit"), class("button danger")], [html.text("Move page to trash")]),
    ],
  )
}

// Search --------------------------------------------------------------------------------

pub type Hit {
  Hit(
    page_id: String,
    notebook_name: String,
    page_number: Int,
    snippet: String,
    highlights: List(#(Int, Int)),
    match_kind: String,
    indexing_pending: Bool,
  )
}

pub fn search_page(notebooks: List(Notebook), csrf: String) -> List(Element(a)) {
  [
    heading("Search", []),
    html.form(
      [
        class("card search-form"),
        attribute.method("post"),
        attribute.action("/search"),
        attribute("hx-post", "/search"),
        attribute("hx-target", "#results"),
        attribute("hx-swap", "innerHTML"),
        attribute("role", "search"),
      ],
      [
        ui.csrf_field(csrf),
        html.label([attribute.for("query")], [html.text("Search your notes")]),
        html.div([class("row")], [
          html.input([
            attribute.id("query"),
            attribute.name("query"),
            attribute.type_("search"),
            attribute("required", ""),
            attribute("maxlength", "500"),
            attribute("autocomplete", "off"),
            attribute("placeholder", "A name, an ID, or what the note was about"),
          ]),
          html.select([attribute.name("notebook_id"), attribute("aria-label", "Notebook")], [
            html.option([attribute.value("")], "All notebooks"),
            ..list.map(notebooks, fn(nb) { html.option([attribute.value(nb.id)], nb.name) })
          ]),
          html.button([attribute.type_("submit"), class("button")], [html.text("Search")]),
        ]),
      ],
    ),
    html.div([attribute.id("results"), attribute("aria-live", "polite")], []),
  ]
}

pub fn search_results(mode: String, migrating: Bool, hits: List(Hit)) -> List(Element(a)) {
  [
    case mode, migrating {
      "lexical_only", _ ->
        ui.alert("info", "Showing exact-word matches only; meaning-based search is temporarily unavailable.")
      _, True -> ui.alert("info", "Search is being upgraded; some pages match by exact words only for now.")
      _, _ -> element.none()
    },
    case hits {
      [] -> html.p([class("empty")], [html.text("No matching pages found.")])
      _ ->
        html.ol(
          [class("results")],
          list.map(hits, fn(hit) {
            html.li([class("card result")], [
              html.a([attribute.href("/pages/" <> hit.page_id), class("result-link")], [
                html.span([class("result-where"), attribute("hx-disable", "")], [
                  html.text(hit.notebook_name <> " · Page " <> int.to_string(hit.page_number)),
                ]),
              ]),
              html.p([class("snippet"), attribute("hx-disable", "")], highlighted(hit.snippet, hit.highlights)),
              case hit.indexing_pending {
                True -> html.p([class("muted small")], [html.text("This page was edited since it was indexed.")])
                False -> element.none()
              },
            ])
          }),
        )
    },
  ]
}

/// Split a snippet into text and `<mark>` segments by grapheme ranges.
pub fn highlighted(snippet: String, ranges: List(#(Int, Int))) -> List(Element(a)) {
  let graphemes = string.to_graphemes(snippet)
  let total = list.length(graphemes)
  let slice = fn(from, to) { graphemes |> list.drop(from) |> list.take(to - from) |> string.concat }
  let #(parts, position) =
    list.fold(ranges, #([], 0), fn(state, range) {
      let #(parts, position) = state
      let #(start, end) = range
      case start >= position && end <= total && end > start {
        False -> state
        True -> #(
          [html.mark([], [html.text(slice(start, end))]), html.text(slice(position, start)), ..parts],
          end,
        )
      }
    })
  list.reverse([html.text(slice(position, total)), ..parts])
}

// Upload --------------------------------------------------------------------------------

pub fn upload_page(nb: Notebook, start_page: Int, integrity: String, account_id: String) -> List(Element(a)) {
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/notebooks")], [html.text("Notebooks")]),
      html.text(" / "),
      html.a([attribute.href("/notebooks/" <> nb.id), attribute("hx-disable", "")], [html.text(nb.name)]),
    ]),
    heading("Add pages", []),
    html.section(
      [
        attribute.id("uploader"),
        class("card"),
        attribute.data("notebook-id", nb.id),
        attribute.data("account-id", account_id),
        attribute.data("integrity", integrity),
      ],
      [
        html.p([class("muted")], [
          html.text(
            "Choose photographs of consecutive pages. Each image becomes one page, numbered from the starting page. JPEG and PNG are supported; iPhone HEIC photos are converted when your browser can read them.",
          ),
        ]),
        html.div([class("row")], [
          html.div([], [
            html.label([attribute.for("start-page")], [html.text("Starting page number")]),
            html.input([
              attribute.id("start-page"),
              attribute.type_("number"),
              attribute("min", "1"),
              attribute.value(int.to_string(start_page)),
            ]),
          ]),
          html.div([], [
            html.label([attribute.for("files")], [html.text("Photos")]),
            html.input([
              attribute.id("files"),
              attribute.type_("file"),
              attribute("multiple", ""),
              attribute("accept", "image/jpeg,image/png,image/heic,image/heif,.heic,.heif"),
            ]),
          ]),
        ]),
        html.p([class("muted small")], [
          html.text(
            "Uploads continue only while this tab is open. Keep the original photos until pages show as uploaded.",
          ),
        ]),
        html.button([attribute.id("start-upload"), attribute.type_("button"), class("button")], [
          html.text("Upload"),
        ]),
        html.ol([attribute.id("upload-queue"), class("upload-queue"), attribute("aria-live", "polite")], []),
        html.p([], [
          html.a([attribute.href("/notebooks/" <> nb.id)], [html.text("Back to the notebook")]),
        ]),
      ],
    ),
  ]
}

// Usage and settings ----------------------------------------------------------------------

pub type Usage {
  Usage(
    stored: Int,
    stored_limit: Option(Int),
    reserved: Int,
    notebooks: Int,
    notebook_limit: Option(Int),
    processing_used: Int,
    processing_reserved: Int,
    processing_limit: Option(Int),
    warning: String,
  )
}

pub fn usage_page(
  usage: Usage,
  waiting: Int,
  extra: List(Element(a)),
  csrf: String,
  message: Option(#(String, String)),
) -> List(Element(a)) {
  let limit = fn(value: Option(Int)) {
    case value {
      Some(n) -> int.to_string(n)
      None -> "unlimited"
    }
  }
  [
    heading("Usage", []),
    notice(message),
    case usage.warning {
      "at_capacity" -> ui.alert("warning", "You have reached your page limit. Existing notes stay readable and searchable; new pages cannot be added.")
      "above_90_percent" -> ui.alert("warning", "You have used more than 90% of your page limit.")
      "above_80_percent" -> ui.alert("info", "You have used more than 80% of your page limit.")
      _ -> element.none()
    },
    html.dl([class("card stats")], [
      html.dt([], [html.text("Stored pages")]),
      html.dd([], [html.text(int.to_string(usage.stored) <> " of " <> limit(usage.stored_limit))]),
      html.dt([], [html.text("Uploads in progress")]),
      html.dd([], [html.text(int.to_string(usage.reserved))]),
      html.dt([], [html.text("Notebooks")]),
      html.dd([], [html.text(int.to_string(usage.notebooks) <> " of " <> limit(usage.notebook_limit))]),
      html.dt([], [html.text("Pages processed (lifetime allowance)")]),
      html.dd([], [
        html.text(int.to_string(usage.processing_used) <> " of " <> limit(usage.processing_limit)
          <> case usage.processing_reserved {
            0 -> ""
            n -> " (" <> int.to_string(n) <> " in progress)"
          }),
      ]),
    ]),
    element.fragment(extra),
    deferred_section(waiting, csrf),
  ]
}

pub fn settings_page(
  theme: String,
  auto_process_deferred: Bool,
  csrf: String,
  message: Option(#(String, String)),
) -> List(Element(a)) {
  let choice = fn(value: String, label: String) {
    html.label([class("choice")], [
      html.input([
        attribute.type_("radio"),
        attribute.name("theme"),
        attribute.value(value),
        attribute("checked", "") |> fn(a) {
          case theme == value {
            True -> a
            False -> attribute.none()
          }
        },
      ]),
      html.text(" " <> label),
    ])
  }
  [
    heading("Settings", []),
    notice(message),
    html.form([class("card"), attribute.method("post"), attribute.action("/settings/theme")], [
      ui.csrf_field(csrf),
      html.fieldset([], [
        html.legend([], [html.text("Appearance")]),
        choice("system", "System"),
        choice("light", "Light"),
        choice("dark", "Dark"),
      ]),
      html.button([attribute.type_("submit"), class("button")], [html.text("Save")]),
    ]),
    html.form([class("card"), attribute.method("post"), attribute.action("/settings/processing")], [
      ui.csrf_field(csrf),
      html.fieldset([], [
        html.legend([], [html.text("Processing")]),
        checkbox(
          "auto_process_deferred",
          "true",
          html.text(" Process pages uploaded for later automatically"),
          auto_process_deferred,
          False,
        ),
        html.p([class("muted small")], [
          html.text(
            "When processing allowance becomes available, pages you uploaded to process later start on their own, using that allowance. Off: they wait until you choose Process now on the Usage page.",
          ),
        ]),
      ]),
      html.button([attribute.type_("submit"), class("button")], [html.text("Save")]),
    ]),
    html.section([class("card")], [
      html.h2([], [html.text("AI agents")]),
      html.p([], [
        html.text("Let an AI agent search your notes and read pages, with an API key."),
      ]),
      html.a([attribute.href("/settings/api-keys"), class("button secondary")], [
        html.text("Manage API keys"),
      ]),
    ]),
  ]
}

/// API keys for the MCP server (ADR 0012). `created` is a key just made,
/// shown this once.
pub fn api_keys_page(
  keys: List(ApiKey),
  created: Option(#(ApiKey, String)),
  mcp_url: String,
  csrf: String,
  recent: Bool,
  error: Option(String),
  message: Option(#(String, String)),
) -> List(Element(a)) {
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/settings")], [html.text("Settings")]),
    ]),
    heading("API keys", []),
    notice(message),
    case error {
      Some(text) -> ui.alert("danger", text)
      None -> element.none()
    },
    case created {
      Some(#(key, secret)) ->
        html.section([class("card stack"), attribute.id("new-key")], [
          html.h2([], [html.text("Copy your new key")]),
          html.p([], [
            html.text(
              "This is the only time \"" <> key.name
              <> "\" is shown. Store it somewhere safe, like a password manager.",
            ),
          ]),
          html.label([attribute.for("new-key-value")], [html.text("API key")]),
          html.input([
            attribute.id("new-key-value"),
            attribute.value(secret),
            attribute("readonly", ""),
            attribute("autocomplete", "off"),
            attribute("spellcheck", "false"),
            class("mono"),
          ]),
        ])
      None -> element.none()
    },
    html.section([class("card stack")], [
      html.h2([], [html.text("Connect an agent")]),
      html.p([], [
        html.text(
          "Add Libarrie to your agent as a remote MCP server (Streamable HTTP) at this address, and send the key as a bearer token. The agent can search your notes and read page text; it can't change anything.",
        ),
      ]),
      html.p([], [html.code([], [html.text(mcp_url)])]),
      html.p([], [html.code([], [html.text("Authorization: Bearer lbk_…")])]),
    ]),
    html.section([class("card")], [
      html.h2([], [html.text("Your keys")]),
      case keys {
        [] -> html.p([class("muted")], [html.text("You have no API keys.")])
        keys ->
          html.div([class("table-scroll")], [
            html.table([class("data-table")], [
              html.thead([], [
                html.tr([], [
                  html.th([attribute("scope", "col")], [html.text("Name")]),
                  html.th([attribute("scope", "col")], [html.text("Key")]),
                  html.th([attribute("scope", "col")], [html.text("Created")]),
                  html.th([attribute("scope", "col")], [html.text("Last used")]),
                  html.th([attribute("scope", "col")], [html.span([class("visually-hidden")], [html.text("Actions")])]),
                ]),
              ]),
              html.tbody(
                [],
                list.map(keys, fn(key) {
                  html.tr([], [
                    html.td([], [html.text(key.name)]),
                    html.td([], [html.code([], [html.text(key.prefix <> "…")])]),
                    html.td([], [html.text(string.slice(key.created_at, 0, 10))]),
                    html.td([], [
                      html.text(case key.last_used_at {
                        Some(at) -> string.slice(at, 0, 10)
                        None -> "Never"
                      }),
                    ]),
                    html.td([], [
                      html.form(
                        [
                          attribute.method("post"),
                          attribute.action("/settings/api-keys/" <> key.id <> "/revoke"),
                        ],
                        [
                          ui.csrf_field(csrf),
                          html.button(
                            [
                              attribute.type_("submit"),
                              class("button secondary small"),
                              attribute("aria-label", "Revoke " <> key.name),
                            ],
                            [html.text("Revoke")],
                          ),
                        ],
                      ),
                    ]),
                  ])
                }),
              ),
            ]),
          ])
      },
    ]),
    case recent {
      False -> reauth_required("create an API key", "/settings/api-keys")
      True ->
        html.form(
          [attribute.method("post"), attribute.action("/settings/api-keys"), class("card stack")],
          [
            ui.csrf_field(csrf),
            html.h2([], [html.text("Create a key")]),
            html.label([attribute.for("key-name")], [html.text("Name")]),
            html.input([
              attribute.id("key-name"),
              attribute.name("name"),
              attribute("required", ""),
              attribute("maxlength", "100"),
              attribute("placeholder", "For example: Claude on my laptop"),
            ]),
            html.div([class("actions")], [
              html.button([attribute.type_("submit"), class("button")], [html.text("Create key")]),
            ]),
          ],
        )
    },
  ]
}

// Trash ---------------------------------------------------------------------------------

pub fn trash_page(
  trashed_pages: List(Page),
  trashed_notebooks: List(Notebook),
  csrf: String,
  message: Option(#(String, String)),
) -> List(Element(a)) {
  [
    heading("Trash", case trashed_pages, trashed_notebooks {
      [], [] -> []
      _, _ -> [
        html.a([attribute.href("/trash/purge?all=1"), class("button danger")], [html.text("Empty trash")]),
      ]
    }),
    notice(message),
    html.p([class("muted")], [
      html.text("Items in trash are deleted permanently after 30 days. Restoring needs free page capacity and an unused page number."),
    ]),
    case trashed_notebooks {
      [] -> element.none()
      _ ->
        html.section([], [
          html.h2([], [html.text("Notebooks")]),
          html.ul(
            [class("list")],
            list.map(trashed_notebooks, fn(nb) {
              html.li([class("card row")], [
                user_text(html.span, "", nb.name),
                html.div([class("actions")], [
                  restore_button("/notebooks/" <> nb.id <> "/restore", csrf),
                  purge_link("notebook=" <> nb.id),
                ]),
              ])
            }),
          ),
        ])
    },
    case trashed_pages {
      [] ->
        case trashed_notebooks {
          [] -> html.p([class("empty")], [html.text("Trash is empty.")])
          _ -> element.none()
        }
      _ ->
        html.section([], [
          html.h2([], [html.text("Pages")]),
          html.ul(
            [class("list")],
            list.map(trashed_pages, fn(page) {
              html.li([class("card row")], [
                html.span([attribute("hx-disable", "")], [
                  html.text(page.notebook_name <> " · Page " <> int.to_string(page.page_number)),
                ]),
                html.div([class("actions")], [
                  restore_button("/pages/" <> page.id <> "/restore", csrf),
                  purge_link("page=" <> page.id),
                ]),
              ])
            }),
          ),
        ])
    },
  ]
}

fn restore_button(action: String, csrf: String) -> Element(a) {
  html.form(
    [
      attribute.method("post"),
      attribute.action(action),
      attribute("hx-post", action),
      attribute("hx-target", "this"),
      attribute("hx-swap", "outerHTML"),
      class("inline"),
    ],
    [
      ui.csrf_field(csrf),
      html.button([attribute.type_("submit"), class("button secondary small")], [html.text("Restore")]),
    ],
  )
}

pub fn closed_account(status: Option(String)) -> List(Element(a)) {
  [
    html.section([class("card narrow")], [
      html.h1([], [html.text("Account closed")]),
      html.p([], [
        html.text(case status {
          Some(s) -> "This account is " <> string.replace(s, "_", " ") <> ". Notes can no longer be viewed."
          None -> "The account for this sign-in was closed and its notes were deleted."
        }),
      ]),
    ]),
  ]
}

/// What a blocked person sees (ADR 0011): their notes are intact and they
/// can download an export, but nothing else.
pub fn blocked_account(deletion_at: Option(String)) -> List(Element(a)) {
  [
    html.section([class("card narrow")], [
      html.h1([], [html.text("Account blocked")]),
      html.p([], [
        html.text(
          "An administrator of this server has blocked this account. Your notes have not been deleted, and you can still download a copy of them.",
        ),
      ]),
      case deletion_at {
        Some(at) ->
          ui.alert(
            "warning",
            "This account is scheduled to be deleted on "
              <> format_time(at)
              <> ". Download your notes before then.",
          )
        None -> element.none()
      },
      html.p([class("muted")], [
        html.text(
          "Contact the server's administrator if you think this is a mistake.",
        ),
      ]),
      html.a([attribute.href("/exports"), class("button")], [
        html.text("Download your notes"),
      ]),
    ]),
  ]
}

// Shared formatting -------------------------------------------------------------------

/// `2026-10-13T09:30:00.000000Z` -> `2026-10-13 09:30 UTC`.
pub fn format_time(timestamp: String) -> String {
  case string.length(timestamp) >= 16 {
    True -> string.slice(timestamp, 0, 10) <> " " <> string.slice(timestamp, 11, 5) <> " UTC"
    False -> timestamp
  }
}

pub fn format_bytes(bytes: Int) -> String {
  let scaled = fn(unit: Int, suffix: String) {
    let tenths = { bytes * 10 + unit / 2 } / unit
    int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> " " <> suffix
  }
  case bytes {
    b if b >= 1_073_741_824 -> scaled(1_073_741_824, "GB")
    b if b >= 1_048_576 -> scaled(1_048_576, "MB")
    b if b >= 1024 -> scaled(1024, "KB")
    b -> int.to_string(b) <> " bytes"
  }
}

/// `[1, 2, 3, 5, 7, 8]` -> `1–3, 5, 7–8`.
pub fn number_ranges(numbers: List(Int)) -> String {
  let close = fn(start: Int, end: Int) {
    case start == end {
      True -> int.to_string(start)
      False -> int.to_string(start) <> "–" <> int.to_string(end)
    }
  }
  let #(done, open) =
    list.fold(numbers, #([], None), fn(state, n) {
      case state {
        #(done, Some(#(start, end))) if n == end + 1 -> #(done, Some(#(start, n)))
        #(done, Some(#(start, end))) -> #([close(start, end), ..done], Some(#(n, n)))
        #(done, None) -> #(done, Some(#(n, n)))
      }
    })
  let done = case open {
    Some(#(start, end)) -> [close(start, end), ..done]
    None -> done
  }
  done |> list.reverse |> string.join(", ")
}

/// Flash messages after a redirect (`?done=...`), never containing user text.
pub fn notice(message: Option(#(String, String))) -> Element(a) {
  case message {
    Some(#(kind, text)) -> ui.alert(kind, text)
    None -> element.none()
  }
}

/// Sensitive actions require a sign-in within the last five minutes
/// (section 6); the identity provider is asked to re-authenticate.
pub fn reauth_required(action: String, return_to: String) -> Element(a) {
  html.section([attribute.id("reauth"), class("card")], [
    html.h2([], [html.text("Confirm it's you")]),
    html.p([], [html.text("For your security, sign in again before you " <> action <> ".")]),
    html.a(
      [
        attribute.href("/auth/login?reauth=1&return_to=" <> ui.uri_encode(return_to)),
        class("button"),
      ],
      [html.text("Sign in again")],
    ),
  ])
}

fn checkbox(name: String, value: String, label: Element(a), checked: Bool, required: Bool) -> Element(a) {
  html.label([class("choice")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.name(name),
      attribute.value(value),
      case checked {
        True -> attribute("checked", "")
        False -> attribute.none()
      },
      case required {
        True -> attribute("required", "")
        False -> attribute.none()
      },
    ]),
    label,
  ])
}

// Notebook colors ---------------------------------------------------------------------

/// Identifying colors offered by the web UI. Colors are rendered with CSS
/// attribute selectors (no inline styles under the CSP); a color set by
/// another client outside this palette is kept but not shown.
pub const palette = [
  #("#0e2444", "Navy"),
  #("#2f6f9f", "Blue"),
  #("#0d3f2e", "Green"),
  #("#5b3a8c", "Purple"),
  #("#a43e28", "Brick"),
  #("#c2185b", "Rose"),
  #("#f5bc2f", "Gold"),
  #("#887861", "Stone"),
]

pub fn swatch(color: Option(String)) -> Element(a) {
  case color {
    Some(c) ->
      case list.key_find(palette, string.lowercase(c)) {
        Ok(name) ->
          html.span([class("swatch"), attribute.data("color", string.lowercase(c))], [
            html.span([class("visually-hidden")], [html.text(name <> " notebook")]),
          ])
        Error(_) -> element.none()
      }
    None -> element.none()
  }
}

fn color_choices(selected: Option(String)) -> Element(a) {
  let selected = option.map(selected, string.lowercase)
  let choice = fn(value: String, label: Element(a), checked: Bool) {
    html.label([class("choice color-choice")], [
      html.input([
        attribute.type_("radio"),
        attribute.name("color"),
        attribute.value(value),
        case checked {
          True -> attribute("checked", "")
          False -> attribute.none()
        },
      ]),
      label,
    ])
  }
  html.fieldset([class("colors")], [
    html.legend([], [html.text("Color (optional)")]),
    choice("", html.text("None"), selected == None),
    ..list.map(palette, fn(entry) {
      let #(value, name) = entry
      choice(
        value,
        html.span([], [
          html.span([class("swatch"), attribute.data("color", value), attribute("aria-hidden", "true")], []),
          html.text(" " <> name),
        ]),
        selected == Some(value),
      )
    })
  ])
}

fn notebook_fields(prefix: String, name: String, description: String, color: Option(String), required: Bool) -> List(Element(a)) {
  [
    html.label([attribute.for(prefix <> "-name")], [html.text("Name")]),
    html.input([
      attribute.id(prefix <> "-name"),
      attribute.name("name"),
      attribute.value(name),
      attribute("maxlength", "200"),
      case required {
        True -> attribute("required", "")
        False -> attribute.none()
      },
    ]),
    html.label([attribute.for(prefix <> "-description")], [html.text("Description (optional)")]),
    html.div([attribute("hx-disable", "")], [
      html.textarea(
        [
          attribute.id(prefix <> "-description"),
          attribute.name("description"),
          attribute("maxlength", "2000"),
          attribute("rows", "2"),
          attribute("placeholder", "Something that helps you recognize it, such as \"Green Moleskine, 2025\""),
        ],
        description,
      ),
    ]),
    color_choices(color),
  ]
}

// Notebook settings -------------------------------------------------------------------

pub fn notebook_settings(nb: Notebook, csrf: String) -> Element(a) {
  html.details([attribute.id("notebook-settings"), class("card")], [
    html.summary([], [html.text("Notebook settings")]),
    html.form(
      [attribute.method("post"), attribute.action("/notebooks/" <> nb.id <> "/edit"), class("stack")],
      [
        ui.csrf_field(csrf),
        hidden("version", int.to_string(nb.version)),
        ..list.append(notebook_fields("edit-notebook", nb.name, nb.description, nb.color, True), [
          html.button([attribute.type_("submit"), class("button")], [html.text("Save changes")]),
        ])
      ],
    ),
    html.hr([]),
    html.h3([], [html.text("Page numbers")]),
    html.p([class("muted")], [
      html.text("Off by one, or skipped a page? Shift a range of page numbers in one step."),
    ]),
    html.a([attribute.href("/notebooks/" <> nb.id <> "/renumber"), class("button secondary")], [
      html.text("Renumber pages"),
    ]),
    html.hr([]),
    html.h3([], [html.text("Move to trash")]),
    html.p([class("muted")], [
      html.text("The notebook and its pages move to trash. You can restore them for 30 days."),
    ]),
    html.form([attribute.method("post"), attribute.action("/notebooks/" <> nb.id <> "/trash")], [
      ui.csrf_field(csrf),
      hidden("version", int.to_string(nb.version)),
      html.button([attribute.type_("submit"), class("button danger")], [html.text("Move notebook to trash")]),
    ]),
  ])
}

// Renumbering --------------------------------------------------------------------------

pub type ShiftForm {
  ShiftForm(from: String, to: String, by: String)
}

pub fn renumber_page(
  nb: Notebook,
  numbering_revision: Int,
  numbers: List(Int),
  csrf: String,
  error: Option(String),
  values: ShiftForm,
) -> List(Element(a)) {
  let field = fn(id: String, label: String, value: String, hint: String) {
    html.div([], [
      html.label([attribute.for(id)], [html.text(label)]),
      html.input([
        attribute.id(id),
        attribute.name(id),
        attribute.type_("number"),
        attribute("required", ""),
        attribute.value(value),
        attribute("aria-describedby", id <> "-hint"),
      ]),
      html.p([attribute.id(id <> "-hint"), class("muted small")], [html.text(hint)]),
    ])
  }
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/notebooks")], [html.text("Notebooks")]),
      html.text(" / "),
      html.a([attribute.href("/notebooks/" <> nb.id), attribute("hx-disable", "")], [html.text(nb.name)]),
    ]),
    heading("Renumber pages", []),
    html.section([class("card")], [
      html.h2([], [html.text("Current page numbers")]),
      case numbers {
        [] -> html.p([class("empty")], [html.text("This notebook has no pages yet.")])
        _ -> html.p([class("mono")], [html.text(number_ranges(numbers))])
      },
    ]),
    html.form(
      [attribute.method("post"), attribute.action("/notebooks/" <> nb.id <> "/renumber"), class("card")],
      [
        ui.csrf_field(csrf),
        hidden("numbering_revision", int.to_string(numbering_revision)),
        html.h2([], [html.text("Shift a range")]),
        html.p([class("muted")], [
          html.text(
            "Every page numbered from the first to the last number moves by the same amount. For example, from 12 to 40 by 1 makes room for a skipped page 12. All pages move together, or none do.",
          ),
        ]),
        case error {
          Some(message) -> ui.alert("danger", message)
          None -> element.none()
        },
        html.div([class("row")], [
          field("from", "First page", values.from, "The lowest page number to move."),
          field("to", "Last page", values.to, "The highest page number to move."),
          field("by", "Move by", values.by, "Positive moves pages later; negative moves them earlier."),
        ]),
        html.button([attribute.type_("submit"), class("button")], [html.text("Renumber")]),
      ],
    ),
  ]
}

// Page actions ---------------------------------------------------------------------------

/// Change a page's number or move it to another notebook.
pub fn page_location_form(page: Page, notebooks: List(Notebook), csrf: String) -> Element(a) {
  html.form(
    [attribute.method("post"), attribute.action("/pages/" <> page.id <> "/move"), class("card")],
    [
      html.h2([], [html.text("Page number and notebook")]),
      ui.csrf_field(csrf),
      hidden("version", int.to_string(page.version)),
      hidden("current_page_number", int.to_string(page.page_number)),
      hidden("current_notebook_id", page.notebook_id),
      html.div([class("row")], [
        html.div([], [
          html.label([attribute.for("page-number")], [html.text("Page number")]),
          html.input([
            attribute.id("page-number"),
            attribute.name("page_number"),
            attribute.type_("number"),
            attribute("min", "1"),
            attribute("required", ""),
            attribute.value(int.to_string(page.page_number)),
          ]),
        ]),
        html.div([], [
          html.label([attribute.for("page-notebook")], [html.text("Notebook")]),
          html.select(
            [attribute.id("page-notebook"), attribute.name("notebook_id")],
            list.map(notebooks, fn(nb) {
              html.option(
                [
                  attribute.value(nb.id),
                  case nb.id == page.notebook_id {
                    True -> attribute("selected", "")
                    False -> attribute.none()
                  },
                ],
                nb.name,
              )
            }),
          ),
        ]),
        html.button([attribute.type_("submit"), class("button secondary")], [html.text("Save")]),
      ]),
    ],
  )
}

/// Rescan (read the handwriting again) and replacement-scan upload. The
/// operation ID is minted when the form renders, so a double submission is
/// one rescan.
pub fn page_scan_actions(page: Page, csrf: String, integrity: String, rescan_operation_id: String, account_id: String) -> Element(a) {
  let status = pages.processing_status(page)
  case page.revision_id {
    None -> element.none()
    Some(revision) ->
      html.section([attribute.id("scan-actions"), class("card")], [
        html.h2([], [html.text("Scan")]),
        case is_processing(status) {
          True ->
            html.p([class("muted")], [
              html.text("This page is being processed. Rescanning and replacing are available when it finishes."),
            ])
          False ->
            html.div([], [
              html.form(
                [attribute.method("post"), attribute.action("/pages/" <> page.id <> "/rescan")],
                [
                  ui.csrf_field(csrf),
                  hidden("operation_id", rescan_operation_id),
                  hidden("source_revision_id", revision),
                  hidden("content_version", int.to_string(page.content_version)),
                  html.p([class("muted small")], [
                    html.text(
                      "Read the handwriting in this photo again. Uses one page of processing allowance; your edits stay in the page history.",
                    ),
                  ]),
                  html.button([attribute.type_("submit"), class("button secondary")], [
                    html.text("Rescan this photo"),
                  ]),
                ],
              ),
              html.div(
                [
                  attribute.id("replacer"),
                  class("replacer"),
                  attribute.data("page-id", page.id),
                  attribute.data("account-id", account_id),
                  attribute.data("content-version", int.to_string(page.content_version)),
                  attribute.data("integrity", integrity),
                ],
                [
                  html.label([attribute.for("replace-file")], [html.text("Replace with a new photo")]),
                  html.p([attribute.id("replace-hint"), class("muted small")], [
                    html.text(
                      "The new photo is processed right away. The previous scan stays in the page history until you delete it.",
                    ),
                  ]),
                  html.div([class("row")], [
                    html.input([
                      attribute.id("replace-file"),
                      attribute.type_("file"),
                      attribute("accept", "image/jpeg,image/png,image/heic,image/heif,.heic,.heif"),
                      attribute("aria-describedby", "replace-hint"),
                    ]),
                    html.button(
                      [attribute.id("start-replace"), attribute.type_("button"), class("button secondary")],
                      [html.text("Upload replacement")],
                    ),
                  ]),
                  html.ol(
                    [attribute.id("replace-queue"), class("upload-queue"), attribute("aria-live", "polite")],
                    [],
                  ),
                ],
              ),
            ])
        },
      ])
  }
}

// Deferred processing -----------------------------------------------------------------

pub fn deferred_section(waiting: Int, csrf: String) -> Element(a) {
  case waiting {
    0 -> element.none()
    n ->
      html.section([attribute.id("deferred"), class("card")], [
        html.h2([], [html.text("Waiting for processing")]),
        html.p([], [
          html.text(
            int.to_string(n) <> pages_word(n)
            <> " uploaded to be processed later. They are stored and viewable, but not yet searchable.",
          ),
        ]),
        html.form([attribute.method("post"), attribute.action("/pages/process-deferred")], [
          ui.csrf_field(csrf),
          html.button([attribute.type_("submit"), class("button")], [html.text("Process now")]),
          html.p([class("muted small")], [
            html.text("Up to 100 pages start per click, as far as your processing allowance reaches."),
          ]),
        ]),
      ])
  }
}

// Exports ------------------------------------------------------------------------------

pub type ExportPart {
  ExportPart(number: Int, items: Int, bytes: Option(Int))
}

pub type Export {
  Export(
    id: String,
    state: String,
    include_trash: Bool,
    item_count: Int,
    total_bytes: Int,
    created_at: String,
    expires_at: Option(String),
    error_code: Option(String),
    parts: List(ExportPart),
  )
}

pub fn exports_page(
  notebooks: List(Notebook),
  exports: List(Export),
  csrf: String,
  message: Option(#(String, String)),
) -> List(Element(a)) {
  [
    heading("Exports", []),
    notice(message),
    html.p([class("muted")], [
      html.text(
        "Download a copy of your notes: every original photo with its transcript, in ZIP files. Downloads stay available for 7 days.",
      ),
    ]),
    html.form([attribute.method("post"), attribute.action("/exports"), class("card")], [
      ui.csrf_field(csrf),
      html.h2([], [html.text("New export")]),
      case notebooks {
        [] -> element.none()
        _ ->
          html.fieldset([], [
            html.legend([], [html.text("Notebooks (leave all unchecked to export everything)")]),
            html.div([attribute("hx-disable", "")], list.map(notebooks, fn(nb) {
              checkbox("notebook_id", nb.id, html.text(" " <> nb.name), False, False)
            })),
          ])
      },
      checkbox("include_trash", "true", html.text(" Include pages in trash"), False, False),
      html.button([attribute.type_("submit"), class("button")], [html.text("Start export")]),
    ]),
    html.h2([], [html.text("Your exports")]),
    export_list(exports),
  ]
}

pub fn export_list(exports: List(Export)) -> Element(a) {
  let polling = list.any(exports, fn(e) { e.state == "assembling" })
  let attrs = case polling {
    True -> [
      attribute("hx-get", "/exports"),
      attribute("hx-trigger", "every 5s"),
      attribute("hx-select", "#export-list"),
      attribute("hx-target", "this"),
      attribute("hx-swap", "outerHTML"),
    ]
    False -> []
  }
  case exports {
    [] -> html.p([attribute.id("export-list"), class("empty")], [html.text("No exports yet.")])
    _ ->
      html.ul([attribute.id("export-list"), class("list"), ..attrs], list.map(exports, export_item))
  }
}

fn export_item(export: Export) -> Element(a) {
  let #(kind, label) = case export.state {
    "assembling" -> #("progress", "Preparing")
    "completed" -> #("ok", "Ready")
    "expired" -> #("muted", "Expired")
    "failed" -> #("danger", "Failed")
    other -> #("muted", string.replace(other, "_", " "))
  }
  html.li([class("card export")], [
    html.div([class("row export-summary")], [
      html.strong([], [html.text("Export of " <> format_time(export.created_at))]),
      html.span([class("badge " <> kind)], [html.text(label)]),
    ]),
    html.p([class("muted small")], [
      html.text(
        int.to_string(export.item_count) <> pages_word(export.item_count)
        <> case export.total_bytes {
          0 -> ""
          b -> " · " <> format_bytes(b)
        }
        <> case export.include_trash {
          True -> " · includes trash"
          False -> ""
        }
        <> case export.state, export.expires_at {
          "completed", Some(at) -> " · available until " <> format_time(at)
          _, _ -> ""
        },
      ),
    ]),
    case export.state {
      "assembling" ->
        html.p([class("small")], [html.text("Preparing your files. This page updates when they are ready.")])
      "failed" ->
        html.p([class("small")], [html.text("This export could not be completed. Start a new export to try again.")])
      "completed" ->
        html.ul(
          [class("parts")],
          list.map(export.parts, fn(part) {
            html.li([], [
              html.a(
                [
                  attribute.href(
                    "/exports/" <> export.id <> "/parts/" <> int.to_string(part.number),
                  ),
                  class("button secondary small"),
                  attribute("download", ""),
                ],
                [html.text("Download part " <> int.to_string(part.number))],
              ),
              html.span([class("muted small")], [
                html.text(
                  " " <> int.to_string(part.items) <> pages_word(part.items)
                  <> case part.bytes {
                    Some(b) -> ", " <> format_bytes(b)
                    None -> ""
                  },
                ),
              ]),
            ])
          }),
        )
      _ -> element.none()
    },
  ])
}

// Permanent deletion ------------------------------------------------------------------

pub fn purge_confirm_page(
  description: String,
  fields: List(#(String, String)),
  csrf: String,
  recent: Bool,
  return_to: String,
  error: Option(String),
) -> List(Element(a)) {
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/trash")], [html.text("Trash")]),
    ]),
    heading("Delete permanently", []),
    case error {
      Some(message) -> ui.alert("danger", message)
      None -> element.none()
    },
    html.section([class("card")], [
      html.p([attribute("hx-disable", "")], [html.text(description)]),
      html.p([], [
        html.text(
          "Permanent deletion removes the photos, transcripts and search data. It cannot be undone, and the pages cannot be restored afterward.",
        ),
      ]),
    ]),
    case recent {
      False -> reauth_required("permanently delete notes", return_to)
      True ->
        html.form([attribute.method("post"), attribute.action("/trash/purge"), class("card")], [
          ui.csrf_field(csrf),
          ..list.append(list.map(fields, fn(f) { hidden(f.0, f.1) }), [
            checkbox(
              "confirm",
              "yes",
              html.text(" I understand this cannot be undone"),
              False,
              True,
            ),
            html.div([class("row")], [
              html.button([attribute.type_("submit"), class("button danger")], [html.text("Delete permanently")]),
              html.a([attribute.href("/trash"), class("button secondary")], [html.text("Cancel")]),
            ]),
          ])
        ])
    },
  ]
}

fn purge_link(query: String) -> Element(a) {
  html.a([attribute.href("/trash/purge?" <> query), class("button danger small")], [
    html.text("Delete permanently"),
  ])
}

// Account ------------------------------------------------------------------------------

pub type AccountStatus {
  AccountStatus(
    status: String,
    milestone: String,
    lifecycle_revision: Int,
    effective_at: Option(String),
  )
}

pub fn account_page(
  name: String,
  account: AccountStatus,
  csrf: String,
  recent: Bool,
  grace_days: Int,
  message: Option(#(String, String)),
) -> List(Element(a)) {
  [
    heading("Account", []),
    notice(message),
    html.section([class("card")], [
      html.h2([], [html.text("Signed in")]),
      user_text(html.p, "", name),
    ]),
    html.section([class("card")], [
      html.h2([], [html.text("Your data")]),
      html.p([], [
        html.text("Download every photo and transcript at any time, including before deleting your account."),
      ]),
      html.a([attribute.href("/exports"), class("button secondary")], [html.text("Export your notes")]),
    ]),
    case account.status {
      "closure_scheduled" ->
        html.section([attribute.id("account-deletion"), class("card danger-zone")], [
          html.h2([], [html.text("Account deletion scheduled")]),
          ui.alert(
            "warning",
            "Your account will be deleted "
              <> case account.effective_at {
                Some(at) -> "on " <> format_time(at)
                None -> "soon"
              }
              <> ". Until then you can read, search and export your notes, but not add or change them.",
          ),
          case account.milestone {
            "closure_scheduled_awaiting_confirmation" ->
              html.p([class("muted small")], [html.text("Recording the request. This takes a moment.")])
            _ -> element.none()
          },
          case recent {
            False -> reauth_required("cancel account deletion", "/account")
            True ->
              html.form([attribute.method("post"), attribute.action("/account/delete/cancel")], [
                ui.csrf_field(csrf),
                hidden("lifecycle_revision", int.to_string(account.lifecycle_revision)),
                html.button([attribute.type_("submit"), class("button")], [html.text("Keep my account")]),
              ])
          },
        ])
      _ ->
        html.section([attribute.id("account-deletion"), class("card danger-zone")], [
          html.h2([], [html.text("Delete account")]),
          html.p([], [
            html.text(
              "Deletion takes effect after " <> int.to_string(grace_days) <> days_word(grace_days)
              <> ". You can cancel until then. Afterward all notebooks, photos and transcripts are deleted permanently.",
            ),
          ]),
          html.a([attribute.href("/account/delete"), class("button danger")], [html.text("Delete account…")]),
        ])
    },
  ]
}

fn days_word(n: Int) -> String {
  case n {
    1 -> " day"
    _ -> " days"
  }
}

pub fn delete_account_page(
  csrf: String,
  recent: Bool,
  grace_days: Int,
  acknowledgement: Option(String),
  error: Option(String),
) -> List(Element(a)) {
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/account")], [html.text("Account")]),
    ]),
    heading("Delete account", []),
    case error {
      Some(message) -> ui.alert("danger", message)
      None -> element.none()
    },
    html.section([class("card")], [
      html.h2([], [html.text("What happens")]),
      html.ul([], [
        html.li([], [
          html.text("Right away, you can no longer add or change notes. Uploads and processing in progress stop."),
        ]),
        html.li([], [
          html.text(
            "For " <> int.to_string(grace_days) <> days_word(grace_days)
            <> ", you can still read, search and export your notes, and cancel the deletion.",
          ),
        ]),
        html.li([], [
          html.text("After that, all notebooks, photos, transcripts and exports are deleted permanently."),
        ]),
      ]),
      html.p([], [
        html.a([attribute.href("/exports")], [html.text("Export your notes first")]),
        html.text(" if you want to keep a copy."),
      ]),
    ]),
    case recent {
      False -> reauth_required("delete your account", "/account/delete")
      True ->
        html.form([attribute.method("post"), attribute.action("/account/delete"), class("card")], [
          ui.csrf_field(csrf),
          case acknowledgement {
            Some(message) ->
              html.div([], [
                ui.alert("warning", message),
                checkbox(
                  "acknowledge_coverage_end",
                  "true",
                  html.text(" I understand"),
                  False,
                  True,
                ),
              ])
            None -> element.none()
          },
          checkbox(
            "confirm",
            "yes",
            html.text(" I want to delete my account and all of my notes"),
            False,
            True,
          ),
          html.div([class("row")], [
            html.button([attribute.type_("submit"), class("button danger")], [html.text("Delete account")]),
            html.a([attribute.href("/account"), class("button secondary")], [html.text("Cancel")]),
          ]),
        ])
    },
  ]
}

// Setup and admin ---------------------------------------------------------------------------

pub fn setup_page(
  csrf: String,
  recent: Bool,
  error: Option(String),
) -> List(Element(a)) {
  [
    heading("Claim ownership", []),
    case error {
      Some(message) -> ui.alert("danger", message)
      None -> element.none()
    },
    html.section([class("card")], [
      html.p([], [
        html.text(
          "Owners and admins manage this server and who else can administer it. They never see anyone's notes.",
        ),
      ]),
      html.p([class("muted")], [
        html.text(
          "The setup code is printed in the server log when the server starts. With Docker Compose, run ",
        ),
        html.code([], [html.text("docker compose logs api")]),
        html.text("."),
      ]),
    ]),
    case recent {
      False -> reauth_required("claim ownership", "/setup")
      True ->
        html.form(
          [
            attribute.method("post"),
            attribute.action("/setup"),
            class("card stack"),
          ],
          [
            ui.csrf_field(csrf),
            html.label([attribute.for("setup-code")], [html.text("Setup code")]),
            html.input([
              attribute.id("setup-code"),
              attribute.name("code"),
              attribute.type_("text"),
              attribute("autocomplete", "off"),
              attribute("spellcheck", "false"),
              attribute("required", ""),
              class("mono"),
            ]),
            html.button([attribute.type_("submit"), class("button")], [
              html.text("Become owner"),
            ]),
          ],
        )
    },
  ]
}

fn role_badge(role: Option(Role)) -> Element(a) {
  case role {
    Some(Owner) -> html.span([class("badge ok")], [html.text("Owner")])
    Some(Admin) -> html.span([class("badge progress")], [html.text("Admin")])
    None -> html.span([class("muted")], [html.text("—")])
  }
}

/// The role changes `actor` may make for someone with `current`.
fn role_actions(
  actor: Option(Role),
  current: Option(Role),
) -> List(#(String, String)) {
  let manage_owners = admin.can(actor, admin.ManageOwners)
  case current {
    Some(Owner) if manage_owners -> [
      #("admin", "Make admin instead"),
      #("none", "Remove owner"),
    ]
    Some(Owner) -> []
    Some(Admin) ->
      list.flatten([
        case manage_owners {
          True -> [#("owner", "Make owner")]
          False -> []
        },
        [#("none", "Remove admin")],
      ])
    None ->
      list.flatten([
        [#("admin", "Make admin")],
        case manage_owners {
          True -> [#("owner", "Make owner")]
          False -> []
        },
      ])
  }
}

fn audit_text(entry: admin.AuditEntry) -> String {
  let who = option.unwrap(entry.actor, "Server configuration")
  let whom = option.unwrap(entry.target, "someone")
  case entry.action {
    "owner.claimed" -> who <> " claimed ownership with a setup code"
    "owner.configured" -> whom <> " became an owner through LIBARRIE_OWNER"
    "user.blocked" -> who <> " blocked " <> whom
    "user.unblocked" -> who <> " unblocked " <> whom
    "user.deletion_scheduled" ->
      who <> " scheduled " <> whom <> "'s account for deletion"
    "user.deletion_cancelled" ->
      who <> " cancelled the deletion of " <> whom <> "'s account"
    "role.changed" ->
      who
      <> " changed "
      <> whom
      <> "'s role from "
      <> option.unwrap(entry.from, "none")
      <> " to "
      <> option.unwrap(entry.to, "none")
    other -> who <> ": " <> other
  }
}

/// Block and delete actions `actor` may take on `user` (ADR 0011).
fn moderation_actions(
  actor: Option(Role),
  actor_id: String,
  user: admin.User,
) -> List(#(String, String)) {
  let allowed =
    user.user_id != actor_id
    && admin.can(actor, admin.BlockUsers)
    && case user.role {
      None -> True
      Some(_) -> actor == Some(Owner)
    }
  case allowed, user.blocked, user.deletion_at {
    False, _, _ -> []
    True, True, Some(_) -> [#("cancel-deletion", "Cancel deletion")]
    True, True, None -> [#("unblock", "Unblock"), #("delete", "Delete account")]
    True, False, None -> [#("block", "Block"), #("delete", "Delete account")]
    // Deletion the person asked for themselves: not an admin's to undo.
    True, False, Some(_) -> [#("block", "Block")]
  }
}

pub fn admin_page(
  users: List(admin.User),
  query: String,
  audit: List(admin.AuditEntry),
  actor: Option(Role),
  actor_id: String,
  message: Option(#(String, String)),
) -> List(Element(a)) {
  [
    heading("Admin", []),
    notice(message),
    html.section([class("card")], [
      html.h2([], [html.text("People")]),
      html.form(
        [
          attribute.method("get"),
          attribute.action("/admin"),
          class("row search-form"),
        ],
        [
          html.div([class("grow")], [
            html.label([attribute.for("admin-query")], [
              html.text("Search by name, email or sign-in ID"),
            ]),
            html.input([
              attribute.id("admin-query"),
              attribute.name("q"),
              attribute.type_("search"),
              attribute.value(query),
            ]),
          ]),
          html.button([attribute.type_("submit"), class("button secondary")], [
            html.text("Search"),
          ]),
        ],
      ),
      case users {
        [] ->
          html.p([class("empty")], [html.text("No one matches that search.")])
        _ ->
          html.div([class("table-scroll")], [
            html.table([class("data-table")], [
              html.thead([], [
                html.tr([], [
                  html.th([attribute("scope", "col")], [html.text("Name")]),
                  html.th([attribute("scope", "col")], [html.text("Email")]),
                  html.th([attribute("scope", "col")], [html.text("Sign-in ID")]),
                  html.th([attribute("scope", "col")], [html.text("Account")]),
                  html.th([attribute("scope", "col")], [html.text("Role")]),
                  html.th([attribute("scope", "col")], [
                    html.span([class("visually-hidden")], [html.text("Actions")]),
                  ]),
                ]),
              ]),
              html.tbody(
                [],
                list.map(users, fn(u) {
                  html.tr([], [
                    html.td([attribute("hx-disable", "")], [
                      html.text(case u.display_name {
                        "" -> "(no name)"
                        name -> name
                      }),
                    ]),
                    html.td([attribute("hx-disable", "")], [
                      html.text(option.unwrap(u.email, "—")),
                    ]),
                    html.td([class("mono small"), attribute("hx-disable", "")], [
                      html.text(option.unwrap(u.subject, "—")),
                    ]),
                    html.td([], [account_cell(u)]),
                    html.td([], [role_badge(u.role)]),
                    html.td([], [
                      html.div(
                        [class("actions")],
                        list.append(
                          list.map(role_actions(actor, u.role), fn(action) {
                            html.a(
                              [
                                attribute.href(
                                  "/admin/users/"
                                  <> u.user_id
                                  <> "/role?to="
                                  <> action.0,
                                ),
                                class("button secondary small"),
                              ],
                              [html.text(action.1)],
                            )
                          }),
                          list.map(
                            moderation_actions(actor, actor_id, u),
                            fn(action) {
                              html.a(
                                [
                                  attribute.href(
                                    "/admin/users/"
                                    <> u.user_id
                                    <> "/"
                                    <> action.0,
                                  ),
                                  class("button secondary small"),
                                ],
                                [html.text(action.1)],
                              )
                            },
                          ),
                        ),
                      ),
                    ]),
                  ])
                }),
              ),
            ]),
          ])
      },
    ]),
    html.section([class("card")], [
      html.h2([], [html.text("Recent changes")]),
      case audit {
        [] -> html.p([class("muted")], [html.text("No changes yet.")])
        _ ->
          html.ul(
            [class("audit-log")],
            list.map(audit, fn(entry) {
              html.li([], [
                html.span([attribute("hx-disable", "")], [
                  html.text(audit_text(entry)),
                ]),
                html.time(
                  [
                    attribute("datetime", entry.created_at),
                    class("muted small"),
                  ],
                  [
                    html.text(string.replace(
                      string.slice(entry.created_at, 0, 16),
                      "T",
                      " ",
                    )),
                  ],
                ),
              ])
            }),
          )
      },
    ]),
  ]
}

fn account_cell(user: admin.User) -> Element(a) {
  case user.blocked, user.deletion_at {
    _, Some(at) ->
      html.span([class("badge danger")], [
        html.text("Deleting " <> string.slice(at, 0, 10)),
      ])
    True, None -> html.span([class("badge warning")], [html.text("Blocked")])
    False, None -> html.text(account_status_label(user.account_status))
  }
}

fn account_status_label(status: String) -> String {
  case status {
    "active" -> "Active"
    "closure_scheduled" -> "Deletion scheduled"
    "closing" -> "Closing"
    other -> other
  }
}

fn role_description(to: String) -> String {
  case to {
    "owner" ->
      "Owners can do everything admins can, and can also make and remove owners."
    "admin" ->
      "Admins can see who uses this server and can make and remove admins. They cannot see anyone's notes."
    _ -> "They will lose access to the admin area."
  }
}

pub fn role_confirm_page(
  user: admin.User,
  to: String,
  csrf: String,
  recent: Bool,
  error: Option(String),
) -> List(Element(a)) {
  let name = case user.display_name {
    "" -> "this person"
    n -> n
  }
  let question = case to {
    "owner" -> "Make " <> name <> " an owner?"
    "admin" -> "Make " <> name <> " an admin?"
    _ -> "Remove " <> name <> "'s role?"
  }
  let path = "/admin/users/" <> user.user_id <> "/role?to=" <> to
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/admin")], [html.text("Admin")]),
    ]),
    heading("Change role", []),
    case error {
      Some(message) -> ui.alert("danger", message)
      None -> element.none()
    },
    html.section([class("card")], [
      html.h2([attribute("hx-disable", "")], [html.text(question)]),
      html.p([], [html.text(role_description(to))]),
    ]),
    case recent {
      False -> reauth_required("change someone's role", path)
      True ->
        html.form(
          [
            attribute.method("post"),
            attribute.action("/admin/users/" <> user.user_id <> "/role"),
            class("card"),
          ],
          [
            ui.csrf_field(csrf),
            hidden("to", to),
            html.div([class("actions")], [
              html.button(
                [
                  attribute.type_("submit"),
                  class(case to {
                    "none" -> "button danger"
                    _ -> "button"
                  }),
                ],
                [html.text("Confirm")],
              ),
              html.a([attribute.href("/admin"), class("button secondary")], [
                html.text("Cancel"),
              ]),
            ]),
          ],
        )
    },
  ]
}

pub fn moderation_confirm_page(
  user: admin.User,
  action: String,
  grace_days: Int,
  csrf: String,
  recent: Bool,
  error: Option(String),
) -> List(Element(a)) {
  let name = case user.display_name {
    "" -> "this person"
    n -> n
  }
  let #(title, question, explanation, button, danger) = case action {
    "block" -> #(
      "Block account",
      "Block " <> name <> "?",
      "They will be signed out of everything except a notice and their exports. Their notes stay intact and processing pauses. You can unblock them at any time.",
      "Block",
      True,
    )
    "unblock" -> #(
      "Unblock account",
      "Unblock " <> name <> "?",
      "They get full access to their account again, and paused processing resumes.",
      "Unblock",
      False,
    )
    "delete" -> #(
      "Delete account",
      "Delete " <> name <> "'s account?",
      "The account is blocked now and deleted permanently "
        <> case grace_days {
        0 -> "right away"
        1 -> "in 1 day"
        n -> "in " <> int.to_string(n) <> " days"
      }
        <> ", with all notebooks, photos and transcripts. Until then they can still download their notes, and you can cancel the deletion.",
      "Delete account",
      True,
    )
    _ -> #(
      "Cancel deletion",
      "Cancel the deletion of " <> name <> "'s account?",
      "Nothing is deleted. The account stays blocked until you unblock it.",
      "Cancel deletion",
      False,
    )
  }
  let path = "/admin/users/" <> user.user_id <> "/" <> action
  [
    html.nav([class("breadcrumbs"), attribute("aria-label", "Breadcrumb")], [
      html.a([attribute.href("/admin")], [html.text("Admin")]),
    ]),
    heading(title, []),
    case error {
      Some(message) -> ui.alert("danger", message)
      None -> element.none()
    },
    html.section([class("card")], [
      html.h2([attribute("hx-disable", "")], [html.text(question)]),
      html.p([], [html.text(explanation)]),
    ]),
    case recent {
      False -> reauth_required(string.lowercase(title), path)
      True ->
        html.form(
          [
            attribute.method("post"),
            attribute.action(path),
            class("card stack"),
          ],
          [
            ui.csrf_field(csrf),
            case action {
              "block" ->
                html.div([class("stack")], [
                  html.label([attribute.for("reason")], [
                    html.text("Reason (optional, shown only to admins)"),
                  ]),
                  html.textarea(
                    [
                      attribute.id("reason"),
                      attribute.name("reason"),
                      attribute("rows", "2"),
                    ],
                    "",
                  ),
                ])
              _ -> element.none()
            },
            html.div([class("actions")], [
              html.button(
                [
                  attribute.type_("submit"),
                  class(case danger {
                    True -> "button danger"
                    False -> "button"
                  }),
                ],
                [html.text(button)],
              ),
              html.a([attribute.href("/admin"), class("button secondary")], [
                html.text("Back"),
              ]),
            ]),
          ],
        )
    },
  ]
}
