//// Private notebooks over REST (ADR 0017): the flag on notebooks, and search
//// results that say where a private page matched but never the text.

import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import libarrie/api/router
import support.{call, str}

fn private_flag(reply: support.Reply) -> Bool {
  support.get(reply, ["private"], decode.bool)
}

fn version(reply: support.Reply) -> Int {
  support.get(reply, ["version"], decode.int)
}

fn patch(
  app: router.App,
  token: String,
  notebook_id: String,
  fields: List(#(String, json.Json)),
  version: Option(Int),
) -> support.Reply {
  let headers = case version {
    Some(v) -> [#("if-match", "\"v" <> int.to_string(v) <> "\"")]
    None -> []
  }
  call(app, http.Patch, "/v1/notebooks/" <> notebook_id, token, Some(json.object(fields)), headers)
}

fn notebook(app: router.App, token: String, notebook_id: String) -> support.Reply {
  call(app, http.Get, "/v1/notebooks/" <> notebook_id, token, None, [])
}

pub fn notebook_private_flag_test() {
  let app = support.app()
  let token = support.user(app)
  let create = fn(fields) {
    call(app, http.Post, "/v1/notebooks", token, Some(json.object(fields)), [])
  }
  // Omitted means not private.
  let a = create([#("name", json.string("A"))])
  let assert 201 = a.status
  let assert False = private_flag(a)
  support.raise_limits(app, token)
  let b = create([#("name", json.string("B")), #("private", json.bool(True))])
  let assert 201 = b.status
  let assert True = private_flag(b)
  let b_id = str(b, ["id"])
  let assert True = private_flag(notebook(app, token, b_id))
  let listed =
    support.get(
      call(app, http.Get, "/v1/notebooks", token, None, []),
      ["notebooks"],
      decode.list({
        use id <- decode.field("id", decode.string)
        use private <- decode.field("private", decode.bool)
        decode.success(#(id, private))
      }),
    )
  let assert Ok(True) = list.key_find(listed, b_id)
  let assert Ok(False) = list.key_find(listed, str(a, ["id"]))
  // So does null.
  let c = create([#("name", json.string("C")), #("private", json.null())])
  let assert 201 = c.status
  let assert False = private_flag(c)

  // On update, an omitted or null flag is no change.
  let renamed = patch(app, token, b_id, [#("name", json.string("B2"))], Some(version(b)))
  let assert 200 = renamed.status
  let assert True = private_flag(renamed)
  let nulled = patch(app, token, b_id, [#("private", json.null())], Some(version(renamed)))
  let assert 200 = nulled.status
  let assert True = private_flag(nulled)
  let assert 400 =
    patch(app, token, b_id, [#("private", json.string("yes"))], Some(version(nulled))).status
  // Clearing it follows the usual If-Match rules.
  let cleared = patch(app, token, b_id, [#("private", json.bool(False))], Some(version(nulled)))
  let assert 200 = cleared.status
  let assert False = private_flag(cleared)
  let assert True = version(cleared) == version(nulled) + 1
  let assert 412 =
    patch(app, token, b_id, [#("private", json.bool(True))], Some(version(nulled))).status
  let assert 428 = patch(app, token, b_id, [#("private", json.bool(True))], None).status
  let assert False = private_flag(notebook(app, token, b_id))

  // Existing notebooks read false after the migration.
  let assert "boolean NO false" =
    support.sql_str(
      app,
      "select data_type || ' ' || is_nullable || ' ' || column_default
       from information_schema.columns
       where table_schema = current_schema() and table_name = 'notebooks'
         and column_name = 'private'",
      [],
    )

  // Trash and restore keep the flag.
  let private_again =
    patch(app, token, b_id, [#("private", json.bool(True))], Some(version(cleared)))
  let assert True = private_flag(private_again)
  let trashed = call(app, http.Delete, "/v1/notebooks/" <> b_id, token, None, [])
  let assert 202 = trashed.status
  let assert True = support.get(trashed, ["notebook", "private"], decode.bool)
  let in_trash =
    support.get(
      call(app, http.Get, "/v1/trash", token, None, []),
      ["notebooks"],
      decode.list({
        use id <- decode.field("id", decode.string)
        use private <- decode.field("private", decode.bool)
        decode.success(#(id, private))
      }),
    )
  let assert Ok(True) = list.key_find(in_trash, b_id)
  support.maintain(app, "journal")
  let restored =
    call(app, http.Post, "/v1/notebooks/" <> b_id <> "/restore", token, Some(json.object([])), [])
  let assert 202 = restored.status
  let assert True = support.get(restored, ["notebook", "private"], decode.bool)
  support.maintain(app, "journal")
  let assert True = private_flag(notebook(app, token, b_id))
}

/// Each result's page ID with its sorted keys.
fn result_keys(reply: support.Reply) -> List(#(String, List(String))) {
  support.get(
    reply,
    ["results"],
    decode.list({
      use page_id <- decode.field("page_id", decode.string)
      use all <- decode.then(decode.dict(decode.string, decode.dynamic))
      decode.success(#(page_id, dict.keys(all) |> list.sort(string.compare)))
    }),
  )
}

/// Each result's page ID with what it says about the match.
type Found {
  Found(
    notebook_id: String,
    notebook_name: String,
    page_number: Int,
    index_generation_id: String,
    indexing_pending: Bool,
    snippet: Option(String),
    highlights: Int,
  )
}

fn found(reply: support.Reply) -> List(#(String, Found)) {
  support.get(
    reply,
    ["results"],
    decode.list({
      use page_id <- decode.field("page_id", decode.string)
      use notebook_id <- decode.subfield(["notebook", "id"], decode.string)
      use notebook_name <- decode.subfield(["notebook", "name"], decode.string)
      use page_number <- decode.field("page_number", decode.int)
      use index_generation_id <- decode.field("index_generation_id", decode.string)
      use indexing_pending <- decode.field("indexing_pending", decode.bool)
      // Absent, never null: null fails this decoder.
      use snippet <- decode.optional_field("snippet", None, decode.map(decode.string, Some))
      use highlights <- decode.optional_field("highlights", [], decode.list(decode.dynamic))
      decode.success(#(
        page_id,
        Found(
          notebook_id:,
          notebook_name:,
          page_number:,
          index_generation_id:,
          indexing_pending:,
          snippet:,
          highlights: list.length(highlights),
        ),
      ))
    }),
  )
}

const private_keys = [
  "index_generation_id", "indexing_pending", "match_kind", "notebook",
  "page_id", "page_number", "revision_id", "transcript_revision_id",
]

pub fn search_omits_text_from_private_notebooks_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let work = support.notebook(app, token, "Work")
  support.raise_limits(app, token)
  let diary = support.notebook(app, token, "Diary")
  let #(_, work_page) =
    support.upload_page(app, token, work, 1, Some("Met Grace Hopper about the compiler budget"), "immediate")
  let #(_, diary_page) =
    support.upload_page(app, token, diary, 4, Some("Grace Hopper birthday surprise"), "immediate")
  support.drain(app)
  support.set_private(app, token, diary, True)
  let search = fn(fields) {
    let reply = call(app, http.Post, "/v1/search", token, Some(json.object(fields)), [])
    let assert 200 = reply.status
    reply
  }
  let hidden = fn(reply: support.Reply) {
    !string.contains(reply.body, "birthday") && !string.contains(reply.body, "surprise")
  }

  // A mixed response: the private hit says where, the other is unchanged.
  let both = search([#("query", json.string("Hopper"))])
  let assert [_, _] = found(both)
  let assert Ok(keys) = list.key_find(result_keys(both), diary_page)
  let assert True = keys == private_keys
  let assert Ok(Found(notebook_id:, notebook_name: "Diary", page_number: 4, snippet: None, ..)) =
    list.key_find(found(both), diary_page)
  let assert True = notebook_id == diary
  let assert Ok(keys) = list.key_find(result_keys(both), work_page)
  let assert True =
    keys == list.sort(["highlights", "snippet", ..private_keys], string.compare)
  let assert Ok(Found(notebook_name: "Work", snippet: Some(snippet), highlights:, ..)) =
    list.key_find(found(both), work_page)
  let assert True = string.contains(snippet, "Hopper")
  let assert True = highlights > 0
  let assert True = hidden(both)

  // The same when the notebook filter names the private notebook.
  let filtered = search([#("query", json.string("Hopper")), #("notebook_id", json.string(diary))])
  let assert [#(page, Found(notebook_name: "Diary", page_number: 4, snippet: None, ..))] =
    found(filtered)
  let assert True = page == diary_page
  let assert [#(_, keys)] = result_keys(filtered)
  let assert True = keys == private_keys
  let assert True = hidden(filtered)

  // The owner's own reads still return the text (out of scope).
  let detail = call(app, http.Get, "/v1/pages/" <> diary_page, token, None, [])
  let assert 200 = detail.status
  let assert "Grace Hopper birthday surprise" = str(detail, ["transcript", "text"])

  // Toggling takes effect on the next search, from the same index
  // generation, with nothing reindexed.
  let assert Ok(Found(index_generation_id: generation, ..)) =
    list.key_find(found(both), diary_page)
  let count_jobs = fn() {
    support.sql_int(app, "select count(*)::int from jobs where account_id = $1::uuid", [account])
  }
  let jobs = count_jobs()
  support.set_private(app, token, diary, False)
  let shown = search([#("query", json.string("Hopper"))])
  let assert Ok(Found(snippet: Some(snippet), index_generation_id: again, ..)) =
    list.key_find(found(shown), diary_page)
  let assert True = string.contains(snippet, "birthday")
  let assert True = again == generation
  support.set_private(app, token, diary, True)
  let hidden_again = search([#("query", json.string("Hopper"))])
  let assert Ok(Found(snippet: None, index_generation_id: again, ..)) =
    list.key_find(found(hidden_again), diary_page)
  let assert True = again == generation
  let assert True = hidden(hidden_again)
  let assert True = count_jobs() == jobs

  // A correction waiting to be indexed doesn't bring the old text back.
  let page = call(app, http.Get, "/v1/pages/" <> diary_page, token, None, [])
  let content = support.get(page, ["page", "content_version"], decode.int)
  let assert 200 =
    call(
      app,
      http.Put,
      "/v1/pages/" <> diary_page <> "/transcript",
      token,
      Some(json.object([
        #("source_revision_id", json.string(str(page, ["page", "revision_id"]))),
        #("text", json.string("Grace Hopper anniversary dinner")),
      ])),
      [#("if-match", "\"c" <> int.to_string(content) <> "\"")],
    ).status
  let pending = search([#("query", json.string("Hopper"))])
  let assert Ok(Found(indexing_pending: True, snippet: None, ..)) =
    list.key_find(found(pending), diary_page)
  let assert True = hidden(pending)
  let assert False = string.contains(pending.body, "anniversary")

  // A page follows its current notebook: moved into Diary, it loses its
  // snippet.
  let page = call(app, http.Get, "/v1/pages/" <> work_page, token, None, [])
  let page_version = support.get(page, ["page", "version"], decode.int)
  let assert 200 =
    call(
      app,
      http.Patch,
      "/v1/pages/" <> work_page,
      token,
      Some(json.object([#("notebook_id", json.string(diary))])),
      [#("if-match", "\"v" <> int.to_string(page_version) <> "\"")],
    ).status
  let moved = search([#("query", json.string("compiler"))])
  let assert Ok(Found(notebook_name: "Diary", snippet: None, ..)) =
    list.key_find(found(moved), work_page)
  let assert False = string.contains(moved.body, "budget")
}
