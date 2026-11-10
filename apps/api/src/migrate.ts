import pg from "pg";
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";

if (!process.env.DATABASE_URL) throw new Error("DATABASE_URL is required for migrations.");
const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();
try {
  await client.query("select pg_advisory_lock(84219301)");
  await client.query("create table if not exists robur_schema_migration(name text primary key, checksum text not null, applied_at timestamptz not null default now())");
  const directory = resolve(process.env.MIGRATIONS_DIR ?? "infra/gcp/sql");
  const names = (await readdir(directory)).filter(name => /^V\d+__.*\.sql$/.test(name)).sort((a,b) => Number(a.match(/^V(\d+)/)![1])-Number(b.match(/^V(\d+)/)![1]));
  for (const name of names) {
    const sql = await readFile(resolve(directory, name), "utf8"), checksum = createHash("sha256").update(sql).digest("hex");
    const prior = await client.query<{ checksum: string }>("select checksum from robur_schema_migration where name=$1", [name]);
    if (prior.rows[0]) {
      if (prior.rows[0].checksum !== checksum) throw new Error(`Applied migration changed: ${name}`);
      continue;
    }
    await client.query("begin");
    try { await client.query(sql); await client.query("insert into robur_schema_migration(name,checksum) values($1,$2)", [name,checksum]); await client.query("commit"); }
    catch (error) { await client.query("rollback"); throw error; }
    console.log(`Applied ${name}`);
  }
  const role = process.env.APP_DATABASE_ROLE;
  if (role) {
    if (!/^[a-z_][a-z0-9_]{0,62}$/.test(role)) throw new Error("APP_DATABASE_ROLE is invalid.");
    const quoted = `"${role}"`;
    await client.query(`alter role ${quoted} nocreatedb nocreaterole`);
    await client.query(`revoke cloudsqlsuperuser from ${quoted}`);
    await client.query("revoke create on schema public from public");
    const database = await client.query<{ name: string }>("select current_database() as name");
    await client.query(`grant connect on database "${database.rows[0].name.replaceAll('"', '""')}" to ${quoted}`);
    await client.query(`grant usage on schema public to ${quoted}`);
    await client.query(`grant select,insert,update,delete on health_account,health_pairing,health_sync_device,health_record to ${quoted}`);
    await client.query(`grant select on health_daily_aggregate to ${quoted}`);
    await client.query(`revoke all on robur_schema_migration from ${quoted}`);
    console.log("Application database role restricted to health dataset DML.");
  }
} finally { await client.end(); }
