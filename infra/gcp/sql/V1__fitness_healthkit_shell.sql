create table if not exists healthkit_sync_event (
  id bigserial primary key,
  source_device_id text not null,
  captured_at timestamptz not null,
  received_at timestamptz not null default now(),
  snapshot jsonb not null
);

create index if not exists healthkit_sync_event_captured_at_idx
  on healthkit_sync_event (captured_at desc);

create table if not exists daily_fitness_snapshot (
  snapshot_date date primary key,
  recovery_score integer not null check (recovery_score between 0 and 100),
  training_load integer not null check (training_load between 0 and 100),
  sleep_minutes integer not null check (sleep_minutes >= 0),
  resting_heart_rate_bpm integer not null check (resting_heart_rate_bpm >= 0),
  heart_rate_variability_ms integer not null check (heart_rate_variability_ms >= 0),
  running_km numeric(7, 2) not null default 0,
  cycling_km numeric(7, 2) not null default 0,
  strength_sessions integer not null default 0,
  training_minutes integer not null default 0,
  recommendation jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists push_device_registration (
  id bigserial primary key,
  installation_id text not null,
  platform text not null check (platform in ('ios', 'watchos')),
  device_token text not null,
  bundle_id text not null,
  environment text not null check (environment in ('development', 'production')),
  registered_at timestamptz not null,
  updated_at timestamptz not null default now(),
  unique (installation_id, platform, environment)
);

create index if not exists push_device_registration_token_idx
  on push_device_registration (device_token);
