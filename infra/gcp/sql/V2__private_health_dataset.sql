-- Health uploads are owner scoped. Old demo snapshot tables are never exposed by the new API.
create table if not exists health_account (
  owner_id text primary key,
  created_at timestamptz not null default now(),
  consent_version text,
  detailed_samples boolean not null default false,
  workout_reviews boolean not null default false,
  consent_granted_at timestamptz,
  last_synced_at timestamptz
);
create table if not exists health_pairing (
  code_hash text primary key,
  owner_id text not null references health_account(owner_id) on delete cascade,
  expires_at timestamptz not null
);
create index if not exists health_pairing_expiry_idx on health_pairing(expires_at);
create table if not exists health_sync_device (
  token_hash text primary key,
  owner_id text not null references health_account(owner_id) on delete cascade,
  source_device_id text not null,
  device_name text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists health_device_owner_idx on health_sync_device(owner_id);
create table if not exists health_record (
  owner_id text not null references health_account(owner_id) on delete cascade,
  record_kind text not null check(record_kind in ('daily','workout','fitness','score','quantity','sleep')),
  record_id text not null,
  observed_at timestamptz not null,
  source_device_id text not null,
  captured_at timestamptz not null,
  payload jsonb not null check(jsonb_typeof(payload)='object'),
  updated_at timestamptz not null default now(),
  primary key(owner_id,record_kind,record_id)
);
create index if not exists health_record_owner_time_idx on health_record(owner_id,observed_at desc);

-- Keep numeric daily summaries queryable without copying every raw sample into a second table.
create or replace view health_daily_aggregate as
select owner_id,
  coalesce(payload->>'date', to_char(observed_at at time zone 'UTC','YYYY-MM-DD')) as day,
  case when jsonb_typeof(payload->'sleepMinutes')='number' then (payload->>'sleepMinutes')::double precision end as sleep_minutes,
  case when jsonb_typeof(payload->'steps')='number' then (payload->>'steps')::double precision end as steps,
  case when jsonb_typeof(payload->'hrv')='number' then (payload->>'hrv')::double precision end as hrv_sdnn_ms,
  case when jsonb_typeof(payload->'restingHR')='number' then (payload->>'restingHR')::double precision end as resting_hr_bpm,
  case when jsonb_typeof(payload->'vo2Max')='number' then (payload->>'vo2Max')::double precision end as vo2_max,
  case when jsonb_typeof(payload->'weightKg')='number' then (payload->>'weightKg')::double precision end as weight_kg,
  payload as metrics
from health_record where record_kind='daily';
