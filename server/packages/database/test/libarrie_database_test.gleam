import gleeunit
import libarrie/database/migrate

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn split_respects_quotes_and_dollar_bodies_test() {
  let sql =
    "-- users' notes; comment\ncreate table a (x text default ';');\n"
    <> "do $$ begin perform 1; end $$;\n"
    <> "create function f() returns int language sql as $body$ select 1; $body$;"
  let assert [
    "create table a (x text default ';')",
    "do $$ begin perform 1; end $$",
    "create function f() returns int language sql as $body$ select 1; $body$",
  ] = migrate.split_statements(sql)
}
