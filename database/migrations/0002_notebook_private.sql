-- Private notebooks (libarrie#1). Search results from a private notebook
-- carry no snippet, and MCP get_text refuses its pages. Existing notebooks
-- read false. The lock timeout bounds how long notebook, page and search
-- requests queue behind this statement while it waits for its lock; on a
-- timeout the file rolls back and migrate can be run again.
set local lock_timeout = '5s';
alter table notebooks add column private boolean not null default false;
