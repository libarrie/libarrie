//// Deployment roles (ADR 0011): claiming ownership with setup and recovery
//// codes, LIBARRIE_OWNER, promoting and demoting people, the last-owner
//// rule, recent sign-in for role changes, and the audit log.

import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libarrie/api/router
import libarrie/domain/admin
import libarrie/domain/context
import libarrie/web/config
import support
import web_test
import wisp/simulate

type Res {
  Res(status: Int, location: String, body: String)
}

fn send(app: router.App, req) -> Res {
  let resp = router.handle(app, req)
  let location = case list.key_find(resp.headers, "location") {
    Ok(l) -> l
    Error(_) -> ""
  }
  Res(resp.status, location, simulate.read_body(resp))
}

fn get(app: router.App, path: String, session: String) -> Res {
  simulate.request(http.Get, path)
  |> simulate.header("cookie", session)
  |> send(app, _)
}

fn post(
  app: router.App,
  path: String,
  session: String,
  csrf: String,
  fields: List(#(String, String)),
) -> Res {
  simulate.request(http.Post, path)
  |> simulate.header("cookie", session)
  |> simulate.header("origin", "http://localhost:8080")
  |> simulate.form_body([#("csrf_token", csrf), ..fields])
  |> send(app, _)
}

type Person {
  Person(subject: String, user_id: String, session: String, csrf: String)
}

fn person(app: router.App, label: String) -> Person {
  let subject = label <> "-" <> support.random_id()
  let #(session, csrf) = web_test.sign_in(app, subject)
  let user_id =
    support.sql_str(
      app,
      "select user_id::text from identities where subject = $1",
      [subject],
    )
  Person(subject, user_id, session, csrf)
}

fn role(app: router.App, p: Person) -> String {
  support.sql_str(
    app,
    "select coalesce(role, 'none') from users where id = $1::uuid",
    [p.user_id],
  )
}

/// Start from a server nobody has claimed: no roles, no live codes.
fn unclaimed(app: router.App) -> Nil {
  support.sql(app, "update users set role = null where role is not null", [])
  support.sql(
    app,
    "update owner_setup_codes set claimed_at = now() where claimed_at is null",
    [],
  )
}

fn make(app: router.App, p: Person, r: String) -> Nil {
  support.sql(app, "update users set role = $2 where id = $1::uuid", [
    p.user_id,
    r,
  ])
}

fn change(app: router.App, actor: Person, target: Person, to: String) -> Res {
  post(
    app,
    "/admin/users/" <> target.user_id <> "/role",
    actor.session,
    actor.csrf,
    [#("to", to)],
  )
}

pub fn setup_code_claims_ownership_once_test() {
  let app = support.app()
  unclaimed(app)
  let assert Ok(Some(code)) = admin.issue_setup_code_if_needed(app.ctx)
  let ada = person(app, "setup-ada")
  // Admin pages do not exist for regular users.
  let assert 404 = get(app, "/admin", ada.session).status
  let page = get(app, "/setup", ada.session)
  let assert 200 = page.status
  let assert True = string.contains(page.body, "Setup code")
  let assert 403 =
    post(app, "/setup", ada.session, ada.csrf, [#("code", "WRONG-CODE")]).status
  // Case, spaces and dashes don't matter.
  let typed = string.lowercase(string.replace(code, "-", " "))
  let claimed = post(app, "/setup", ada.session, ada.csrf, [#("code", typed)])
  let assert 303 = claimed.status
  let assert "/admin?done=owner_claimed" = claimed.location
  let assert "owner" = role(app, ada)
  let admin_page = get(app, "/admin?done=owner_claimed", ada.session)
  let assert 200 = admin_page.status
  let assert True = string.contains(admin_page.body, "You are now an owner")
  let assert True =
    string.contains(admin_page.body, "claimed ownership with a setup code")
  // Setup is gone once an owner exists, and no new code is printed.
  let assert 404 = get(app, "/setup", ada.session).status
  let assert Ok(None) = admin.issue_setup_code_if_needed(app.ctx)
  // A setup code is single-use, and cannot add a second owner.
  let bob = person(app, "setup-bob")
  let assert Error(_) = admin.claim(app.ctx, bob.user_id, code)
  let assert "none" = role(app, bob)
}

pub fn recovery_code_works_when_owners_exist_test() {
  let app = support.app()
  unclaimed(app)
  let ada = person(app, "recover-ada")
  make(app, ada, "owner")
  let bob = person(app, "recover-bob")
  let assert 404 = get(app, "/setup", bob.session).status
  let assert Ok(code) = admin.issue_code(app.ctx, "recovery")
  let assert 200 = get(app, "/setup", bob.session).status
  let assert 303 =
    post(app, "/setup", bob.session, bob.csrf, [#("code", code)]).status
  let assert "owner" = role(app, bob)
  let assert 404 = get(app, "/setup", bob.session).status
}

pub fn admins_manage_admins_and_only_owners_manage_owners_test() {
  let app = support.app()
  unclaimed(app)
  let owner = person(app, "roles-owner")
  make(app, owner, "owner")
  let bea = person(app, "roles-bea")
  let cy = person(app, "roles-cy")
  // Regular users cannot change roles.
  let assert 404 = change(app, bea, cy, "admin").status
  // The owner confirms, then makes Bea an admin.
  let confirm =
    get(app, "/admin/users/" <> bea.user_id <> "/role?to=admin", owner.session)
  let assert 200 = confirm.status
  let assert True = string.contains(confirm.body, "an admin?")
  let made = change(app, owner, bea, "admin")
  let assert 303 = made.status
  let assert "/admin?done=role_changed" = made.location
  let assert "admin" = role(app, bea)
  // Bea now sees the admin area and can make and remove admins.
  let page = get(app, "/admin", bea.session)
  let assert 200 = page.status
  let assert True = string.contains(page.body, "href=\"/admin\"")
  let assert 303 = change(app, bea, cy, "admin").status
  let assert "admin" = role(app, cy)
  let assert 303 = change(app, bea, cy, "none").status
  let assert "none" = role(app, cy)
  // Admins never touch owners.
  let assert 403 = change(app, bea, cy, "owner").status
  let assert 403 = change(app, bea, owner, "none").status
  let assert "owner" = role(app, owner)
  // The last owner cannot step down; with a second owner they can.
  let assert 409 = change(app, owner, owner, "none").status
  let assert 303 = change(app, owner, bea, "owner").status
  let assert 303 = change(app, owner, owner, "admin").status
  let assert "admin" = role(app, owner)
  let assert "owner" = role(app, bea)
  // Every change is in the audit log.
  let assert Ok(entries) = admin.audit_log(app.ctx.db, 50)
  let assert True =
    list.count(entries, fn(e) { e.action == "role.changed" }) >= 5
}

pub fn role_changes_need_a_recent_sign_in_test() {
  let app = support.app()
  unclaimed(app)
  let owner = person(app, "recent-owner")
  make(app, owner, "owner")
  let bea = person(app, "recent-bea")
  support.sql(
    app,
    "update web_sessions set auth_time = now() - interval '10 minutes' where user_id = $1::uuid",
    [owner.user_id],
  )
  let page =
    get(app, "/admin/users/" <> bea.user_id <> "/role?to=admin", owner.session)
  let assert True = string.contains(page.body, "Sign in again")
  let assert 403 = change(app, owner, bea, "admin").status
  let assert "none" = role(app, bea)
}

pub fn the_last_owner_cannot_schedule_account_deletion_test() {
  let app = support.app()
  unclaimed(app)
  let owner = person(app, "close-owner")
  make(app, owner, "owner")
  let token = support.token_for(owner.subject, 0)
  let refused =
    support.call(
      app,
      http.Post,
      "/v1/account-deletion",
      token,
      Some(json.object([])),
      [],
    )
  let assert 409 = refused.status
  let assert "last_owner" = support.str(refused, ["error", "code"])
}

pub fn configured_owner_and_email_test() {
  let subject = "configured-" <> support.random_id() <> "@example.test"
  let base = support.app()
  unclaimed(base)
  let ctx =
    context.Context(
      ..base.ctx,
      config: context.Config(..base.ctx.config, configured_owner: Some(subject)),
    )
  let app = router.App(..base, ctx:, web: config.Web(..base.web, ctx:))
  let #(_, _) = web_test.sign_in(app, subject)
  let user_id =
    support.sql_str(
      app,
      "select user_id::text from identities where subject = $1",
      [subject],
    )
  let assert "owner" =
    support.sql_str(
      app,
      "select coalesce(role, 'none') from users where id = $1::uuid",
      [user_id],
    )
  // The development issuer sends an email-shaped subject as the email.
  let assert True =
    support.sql_str(
      app,
      "select coalesce(email, '') from users where id = $1::uuid",
      [user_id],
    )
    == subject
  let assert Ok(entries) = admin.audit_log(app.ctx.db, 10)
  let assert True = list.any(entries, fn(e) { e.action == "owner.configured" })
}

fn moderate(
  app: router.App,
  actor: Person,
  target: Person,
  action: String,
) -> Res {
  post(
    app,
    "/admin/users/" <> target.user_id <> "/" <> action,
    actor.session,
    actor.csrf,
    [#("reason", "spam")],
  )
}

fn api_status(app: router.App, p: Person, path: String) -> Int {
  support.call(app, http.Get, path, support.token_for(p.subject, 0), None, []).status
}

pub fn blocking_restricts_access_but_keeps_exports_test() {
  let app = support.app()
  unclaimed(app)
  let admin_user = person(app, "block-admin")
  make(app, admin_user, "admin")
  let dee = person(app, "block-dee")
  let confirm =
    get(app, "/admin/users/" <> dee.user_id <> "/block", admin_user.session)
  let assert 200 = confirm.status
  let assert True = string.contains(confirm.body, "Reason")
  let blocked = moderate(app, admin_user, dee, "block")
  let assert 303 = blocked.status
  let assert "/admin?done=block" = blocked.location
  let assert True =
    string.contains(get(app, "/admin", admin_user.session).body, "Blocked")
  // The web app only shows the notice and exports.
  let assert "/account" = get(app, "/notebooks", dee.session).location
  let notice = get(app, "/account", dee.session)
  let assert 200 = notice.status
  let assert True = string.contains(notice.body, "Account blocked")
  let assert 200 = get(app, "/exports", dee.session).status
  // The API refuses everything but the account and exports.
  let assert 403 = api_status(app, dee, "/v1/notebooks")
  let assert 200 = api_status(app, dee, "/v1/me")
  let assert 200 = api_status(app, dee, "/v1/exports")
  // Unblocking restores access.
  let assert 303 = moderate(app, admin_user, dee, "unblock").status
  let assert 200 = api_status(app, dee, "/v1/notebooks")
  let assert 200 = get(app, "/notebooks", dee.session).status
  let assert Ok(entries) = admin.audit_log(app.ctx.db, 50)
  let assert True = list.any(entries, fn(e) { e.action == "user.blocked" })
  let assert True = list.any(entries, fn(e) { e.action == "user.unblocked" })
}

pub fn only_owners_moderate_role_holders_test() {
  let app = support.app()
  unclaimed(app)
  let owner = person(app, "mod-owner")
  make(app, owner, "owner")
  let ann = person(app, "mod-ann")
  make(app, ann, "admin")
  let ben = person(app, "mod-ben")
  make(app, ben, "admin")
  let assert 404 = moderate(app, person(app, "mod-user"), ann, "block").status
  let assert 403 = moderate(app, ann, ben, "block").status
  let assert 403 = moderate(app, ann, owner, "block").status
  let assert 409 = moderate(app, ann, ann, "block").status
  let assert 403 = moderate(app, ann, ben, "delete").status
  // Owners can block admins, but not themselves while they are the last owner.
  let assert 303 = moderate(app, owner, ben, "block").status
  let assert 409 = moderate(app, owner, owner, "block").status
  let assert False =
    string.contains(
      get(app, "/admin", ann.session).body,
      "/users/" <> owner.user_id <> "/block",
    )
}

pub fn deleting_a_user_blocks_and_schedules_closure_test() {
  let app = support.app()
  unclaimed(app)
  let admin_user = person(app, "del-admin")
  make(app, admin_user, "admin")
  let eve = person(app, "del-eve")
  let confirm =
    get(app, "/admin/users/" <> eve.user_id <> "/delete", admin_user.session)
  let assert True = string.contains(confirm.body, "days")
  let assert 303 = moderate(app, admin_user, eve, "delete").status
  let assert "closure_scheduled" =
    support.sql_str(
      app,
      "select status from accounts where owner_user_id = $1::uuid",
      [eve.user_id],
    )
  let notice = get(app, "/account", eve.session)
  let assert True = string.contains(notice.body, "Account blocked")
  let assert 200 = api_status(app, eve, "/v1/exports")
  // Unblocking waits until the deletion is cancelled.
  let assert 409 = moderate(app, admin_user, eve, "unblock").status
  let assert 303 = moderate(app, admin_user, eve, "cancel-deletion").status
  let assert "active" =
    support.sql_str(
      app,
      "select status from accounts where owner_user_id = $1::uuid",
      [eve.user_id],
    )
  let assert 403 = api_status(app, eve, "/v1/notebooks")
  let assert 303 = moderate(app, admin_user, eve, "unblock").status
  let assert 200 = api_status(app, eve, "/v1/notebooks")
}

pub fn moderation_needs_a_recent_sign_in_test() {
  let app = support.app()
  unclaimed(app)
  let admin_user = person(app, "modrecent-admin")
  make(app, admin_user, "admin")
  let fay = person(app, "modrecent-fay")
  support.sql(
    app,
    "update web_sessions set auth_time = now() - interval '10 minutes' where user_id = $1::uuid",
    [admin_user.user_id],
  )
  let assert 403 = moderate(app, admin_user, fay, "block").status
  let assert "f" =
    support.sql_str(
      app,
      "select (suspended_at is not null)::text from accounts where owner_user_id = $1::uuid",
      [fay.user_id],
    )
    |> string.slice(0, 1)
}
