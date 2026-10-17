//// The worker's stage execution, fencing and maintenance are exercised by
//// the API integration suite, which drives `libarrie_worker.drain` and
//// `libarrie_worker.maintenance` against real Postgres and object storage.

import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn worker_module_loads_test() {
  Nil
}
