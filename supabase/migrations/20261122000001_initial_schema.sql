-- =============================================================================
-- Migration 001: Initial Schema for GoldenHour (NIRMAN 2026 / HackNation 2026)
-- Pre-arrival emergency coordination layer for hospital emergency departments
-- Database: Supabase / PostgreSQL 15+
-- =============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- 1. ENUMS AND CUSTOM TYPES
-- -----------------------------------------------------------------------------

-- The 4 strict red-flag emergency categories (Capability, never diagnosis)
DO $$ BEGIN
    CREATE TYPE emergency_category AS ENUM (
        'chest_pain',
        'stroke_signs',
        'severe_bleeding',
        'severe_breathlessness'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Alert lifecycle status
DO $$ BEGIN
    CREATE TYPE alert_status AS ENUM (
        'created',        -- Raised by family or 108 operator
        'acknowledged',   -- Hospital screen has seen/acknowledged the alert
        'ready',          -- All 4 tasks have been claimed by hospital staff
        'arrived',        -- Patient reached the gate (freezes escalation clock)
        'closed',         -- Doctor completed record / discharge sign-off
        'diverted',       -- Hospital rejected/diverted case (refusal is a feature)
        'cancelled'       -- Family cancelled with one tap
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Preparation task status
DO $$ BEGIN
    CREATE TYPE task_status AS ENUM (
        'unclaimed',
        'claimed',
        'completed'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Hospital staff operational roles (The 7 hospital roles)
DO $$ BEGIN
    CREATE TYPE task_role AS ENUM (
        'reception',      -- Ops Wall / Coordinator
        'doctor',         -- Emergency Doctor
        'nurse',          -- ER Nursing staff
        'pharmacy',       -- ER Pharmacy team
        'equipment',      -- Equipment / Biomedical technician
        'transport',      -- Stretcher bearer / Gate transport
        'counter',        -- Front Desk / Arrival verification
        'in_charge',      -- Duty lead / Bed & Team In-Charge
        'admin'           -- Hospital Administrator
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Escalation urgency level (Server clock calculated)
DO $$ BEGIN
    CREATE TYPE escalation_level AS ENUM (
        'normal',         -- 0 to 89 seconds
        'amber',          -- 90 to 179 seconds (Duty lead alerted)
        'red'             -- 180+ seconds (Critical risk flag)
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Reason for diversion/refusal when a hospital cannot accept
DO $$ BEGIN
    CREATE TYPE refusal_reason AS ENUM (
        'no_bed',
        'no_team',
        'equipment_unavailable',
        'at_capacity',
        'other'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- 2. CORE TABLES
-- -----------------------------------------------------------------------------

-- Hospital Profile Table
CREATE TABLE IF NOT EXISTS hospitals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(50) UNIQUE NOT NULL,                       -- e.g. 'CAPITAL_HOSP_BBS'
    name VARCHAR(255) NOT NULL,                             -- e.g. 'Capital Hospital, Bhubaneswar'
    short_name VARCHAR(100) NOT NULL,
    district VARCHAR(100) NOT NULL DEFAULT 'Khordha',
    state VARCHAR(100) NOT NULL DEFAULT 'Odisha',
    address TEXT NOT NULL,
    latitude NUMERIC(9,6) NOT NULL,
    longitude NUMERIC(9,6) NOT NULL,
    phone_number VARCHAR(20) NOT NULL,
    emergency_phone VARCHAR(20) NOT NULL,
    entrance_notes TEXT,                                    -- Directions to emergency gate / trauma bay
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

-- Hospital Capability Table (Capability, not general bed count)
CREATE TABLE IF NOT EXISTS hospital_capabilities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    category emergency_category NOT NULL,
    is_available BOOLEAN NOT NULL DEFAULT true,             -- Can hospital treat this category right now?
    ct_scanner_active BOOLEAN NOT NULL DEFAULT true,
    cath_lab_active BOOLEAN NOT NULL DEFAULT false,
    blood_bank_active BOOLEAN NOT NULL DEFAULT true,
    ventilator_active BOOLEAN NOT NULL DEFAULT true,
    oxygen_supply_active BOOLEAN NOT NULL DEFAULT true,
    last_confirmed_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    confirmed_by VARCHAR(100) NOT NULL DEFAULT 'Duty In-Charge',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    CONSTRAINT uq_hospital_category UNIQUE (hospital_id, category)
);

-- Hospital Resource Capacity (Bed holds & capacity tracking)
CREATE TABLE IF NOT EXISTS hospital_resources (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE UNIQUE,
    total_emergency_beds INTEGER NOT NULL DEFAULT 10 CHECK (total_emergency_beds >= 0),
    available_emergency_beds INTEGER NOT NULL DEFAULT 5 CHECK (available_emergency_beds >= 0),
    held_beds INTEGER NOT NULL DEFAULT 0 CHECK (held_beds >= 0),
    active_teams_count INTEGER NOT NULL DEFAULT 3 CHECK (active_teams_count >= 0),
    last_updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    updated_by VARCHAR(100) DEFAULT 'System',
    CONSTRAINT chk_bed_capacity CHECK (available_emergency_beds + held_beds <= total_emergency_beds + 5) -- small emergency surge leeway
);

-- Hospital Staff Members (PIN authentication for demo/tablet screens)
CREATE TABLE IF NOT EXISTS staff_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    name VARCHAR(150) NOT NULL,
    role task_role NOT NULL,
    pin_hash VARCHAR(255) NOT NULL,                         -- SHA-256 or bcrypt hash of 4-digit PIN
    is_duty_lead BOOLEAN NOT NULL DEFAULT false,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

-- Customizable Task Templates per Category (Exactly 4 preparation tasks per hospital)
CREATE TABLE IF NOT EXISTS task_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE, -- NULL means system-wide default
    category emergency_category NOT NULL,
    task_sequence INTEGER NOT NULL CHECK (task_sequence BETWEEN 1 AND 4),
    role_required task_role NOT NULL,
    title_en VARCHAR(200) NOT NULL,
    title_or VARCHAR(200) NOT NULL,                         -- Odia language title
    instructions_en TEXT,
    instructions_or TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    CONSTRAINT uq_task_template_slot UNIQUE (hospital_id, category, task_sequence)
);

-- Core Alerts Table (One alert, two views, clock lives on database)
CREATE TABLE IF NOT EXISTS alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_code VARCHAR(6) UNIQUE NOT NULL,                  -- 6-character code (e.g. A3F2C1)
    access_token UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE, -- Ephemeral bearer token for family status URL
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE RESTRICT,
    category emergency_category NOT NULL,
    status alert_status NOT NULL DEFAULT 'created',
    
    -- Location & Travel metrics (No continuous GPS tracking, only arrival routing)
    origin_latitude NUMERIC(9,6),
    origin_longitude NUMERIC(9,6),
    origin_area_name VARCHAR(150),
    estimated_distance_km NUMERIC(5,2),
    estimated_drive_minutes INTEGER,
    
    -- Resource Hold
    bed_held BOOLEAN NOT NULL DEFAULT false,
    bed_held_expires_at TIMESTAMPTZ,                        -- Auto-expires if not confirmed/arrived
    
    -- Diversion / Refusal info (Refusing is a feature)
    diversion_reason refusal_reason,
    diversion_notes TEXT,
    diverted_to_hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    
    -- Cancellation info
    cancellation_reason VARCHAR(255),
    
    -- The Server Clock & State Timestamps (Never client-side)
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    acknowledged_at TIMESTAMPTZ,
    all_tasks_claimed_at TIMESTAMPTZ,
    arrived_at TIMESTAMPTZ,                                 -- "Arriving always wins" freezes escalation
    closed_at TIMESTAMPTZ,
    closed_by UUID REFERENCES staff_members(id) ON DELETE SET NULL,
    closure_summary TEXT,                                   -- Doctor notes upon closure
    
    -- Client deduplication key (network retry resilience for 2G)
    client_request_id VARCHAR(100) UNIQUE
);

-- Preparation Tasks Table (Exactly 4 tasks per alert)
CREATE TABLE IF NOT EXISTS alert_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id UUID NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    task_sequence INTEGER NOT NULL CHECK (task_sequence BETWEEN 1 AND 4),
    role_required task_role NOT NULL,
    title_en VARCHAR(200) NOT NULL,
    title_or VARCHAR(200) NOT NULL,
    status task_status NOT NULL DEFAULT 'unclaimed',
    
    -- Ownership (Claimed by a named person or role)
    claimed_by UUID REFERENCES staff_members(id) ON DELETE SET NULL,
    claimed_by_name VARCHAR(150),
    claimed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    -- Escalation tracking
    escalation_level escalation_level NOT NULL DEFAULT 'normal',
    amber_escalated_at TIMESTAMPTZ,                         -- Populated when 90 seconds pass unclaimed
    red_escalated_at TIMESTAMPTZ,                           -- Populated when 180 seconds pass unclaimed
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now()),
    
    CONSTRAINT uq_alert_task_sequence UNIQUE (alert_id, task_sequence)
);

-- Append-Only Audit Log (Strictly INSERT only, no UPDATE or DELETE permitted)
CREATE TABLE IF NOT EXISTS audit_logs (
    id BIGSERIAL PRIMARY KEY,
    alert_id UUID NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    action VARCHAR(100) NOT NULL,                           -- e.g. 'ALERT_CREATED', 'TASK_CLAIMED', 'TASK_ESCALATED_AMBER'
    actor_type VARCHAR(50) NOT NULL,                        -- 'family', 'staff', 'system_escalation', 'admin'
    actor_id VARCHAR(100),                                  -- Staff UUID, 'family_token', or 'system'
    actor_role VARCHAR(50),                                 -- Role at time of action
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now())
);

-- -----------------------------------------------------------------------------
-- 3. INDEXES FOR HIGH-SPEED QUERYING AND REALTIME
-- -----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_alerts_hospital_status ON alerts(hospital_id, status);
CREATE INDEX IF NOT EXISTS idx_alerts_alert_code ON alerts(alert_code);
CREATE INDEX IF NOT EXISTS idx_alerts_access_token ON alerts(access_token);
CREATE INDEX IF NOT EXISTS idx_alerts_created_at ON alerts(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_alert_tasks_alert_id ON alert_tasks(alert_id);
CREATE INDEX IF NOT EXISTS idx_alert_tasks_status ON alert_tasks(status);
CREATE INDEX IF NOT EXISTS idx_audit_logs_alert_id ON audit_logs(alert_id);
CREATE INDEX IF NOT EXISTS idx_hospital_capabilities_match ON hospital_capabilities(category, is_available);
CREATE INDEX IF NOT EXISTS idx_staff_members_pin ON staff_members(hospital_id, pin_hash);
