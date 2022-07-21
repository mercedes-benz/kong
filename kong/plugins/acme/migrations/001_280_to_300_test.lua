local uh = require "spec/upgrade_helpers"

if uh.database_type() == 'postgres' then
  describe("acme database migration", function()
      uh.old_after_up("has created the index", function()
          local db = uh.get_database()
          local res, err = db.connector:query("select * from pg_stat_all_indexes where relname = 'acme_storage' and indexrelname = 'acme_storage_ttl_idx'")
          assert.falsy(err)
          assert.equal(1, #res)
      end)
  end)
end
