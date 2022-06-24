local upgrade_helpers = require "spec/upgrade_helpers"

if upgrade_helpers.database_type() == 'postgres' then
  describe("acme database migration", function()
      upgrade_helpers.it_when("old_after_up", "has created the index", function()
          local db = upgrade_helpers.get_database()
          res, err = db.connector:query("select * from pg_stat_all_indexes where relname = 'acme_storage' and indexrelname = 'acme_storage_ttl_idx'")
          assert.falsy(err)
          assert.equal(1, #res)
      end)
  end)
end
