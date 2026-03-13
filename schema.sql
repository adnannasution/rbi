-- ============================================================
-- RBI APPLICATION DATABASE SCHEMA
-- Based on API RP 580 (3rd Ed, 2016) & API RP 581 (3rd Ed, 2016)
-- PostgreSQL 15+
-- ============================================================

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- 1. USER MANAGEMENT & RBAC
-- ============================================================

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(255) NOT NULL,
    role VARCHAR(50) NOT NULL CHECK (role IN (
        'admin', 'team_leader', 'inspector', 'corrosion_specialist',
        'process_engineer', 'risk_analyst', 'operator', 'viewer'
    )),
    department VARCHAR(100),
    certification VARCHAR(255),  -- e.g. 'API 580 Certified, API 510'
    is_active BOOLEAN DEFAULT true,
    last_login TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE audit_log (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID REFERENCES users(id),
    action VARCHAR(50) NOT NULL,  -- CREATE, UPDATE, DELETE, CALCULATE, APPROVE
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID,
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 2. ASSET HIERARCHY
-- Facility > Plant > Process Unit > System/Loop > Equipment > Component
-- ============================================================

CREATE TABLE facilities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    code VARCHAR(50) UNIQUE NOT NULL,
    location VARCHAR(255),
    latitude DECIMAL(10, 7),
    longitude DECIMAL(10, 7),
    climate_type VARCHAR(50) CHECK (climate_type IN ('arid', 'temperate', 'humid', 'marine', 'arctic')),
    regulatory_jurisdiction VARCHAR(255),
    commissioned_date DATE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE plants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    facility_id UUID NOT NULL REFERENCES facilities(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    code VARCHAR(50) NOT NULL,
    plant_type VARCHAR(100),  -- refinery, petrochemical, gas processing, etc.
    status VARCHAR(20) DEFAULT 'operating' CHECK (status IN ('operating', 'shutdown', 'decommissioned', 'construction')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(facility_id, code)
);

CREATE TABLE process_units (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    plant_id UUID NOT NULL REFERENCES plants(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    code VARCHAR(50) NOT NULL,
    unit_type VARCHAR(100),  -- CDU, VDU, FCC, HDS, reformer, etc.
    daily_production_value DECIMAL(15, 2),  -- USD/day for business interruption calc
    turnaround_cycle_months INTEGER DEFAULT 48,
    last_turnaround_date DATE,
    next_turnaround_date DATE,
    status VARCHAR(20) DEFAULT 'operating',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(plant_id, code)
);

CREATE TABLE corrosion_loops (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    process_unit_id UUID NOT NULL REFERENCES process_units(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    code VARCHAR(50) NOT NULL,
    description TEXT,
    process_fluid VARCHAR(255),
    operating_temp_min DECIMAL(8, 2),  -- °C
    operating_temp_max DECIMAL(8, 2),
    operating_temp_normal DECIMAL(8, 2),
    operating_pressure_min DECIMAL(10, 2),  -- kPa
    operating_pressure_max DECIMAL(10, 2),
    operating_pressure_normal DECIMAL(10, 2),
    material_of_construction VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(process_unit_id, code)
);

-- ============================================================
-- 3. EQUIPMENT & COMPONENTS
-- ============================================================

CREATE TABLE equipment (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    corrosion_loop_id UUID NOT NULL REFERENCES corrosion_loops(id) ON DELETE CASCADE,
    process_unit_id UUID NOT NULL REFERENCES process_units(id),
    tag_number VARCHAR(100) NOT NULL,  -- e.g. V-101, P-201A
    name VARCHAR(255) NOT NULL,
    equipment_type VARCHAR(50) NOT NULL CHECK (equipment_type IN (
        'vessel', 'column', 'drum', 'reactor', 'heat_exchanger',
        'pipe', 'tank', 'pump', 'compressor', 'boiler',
        'heater', 'fin_fan', 'filter', 'prd'
    )),
    status VARCHAR(20) DEFAULT 'in_service' CHECK (status IN (
        'in_service', 'out_of_service', 'standby', 'decommissioned', 'new'
    )),
    -- Design Data
    design_code VARCHAR(100),  -- ASME VIII Div 1, B31.3, etc.
    design_pressure DECIMAL(10, 2),  -- kPa
    design_temperature DECIMAL(8, 2),  -- °C
    mawp DECIMAL(10, 2),  -- Maximum Allowable Working Pressure, kPa
    -- Dates
    fabrication_date DATE,
    installation_date DATE,
    commissioning_date DATE,
    -- Physical
    diameter_mm DECIMAL(10, 2),
    length_mm DECIMAL(10, 2),
    weight_kg DECIMAL(12, 2),
    -- Notes
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(process_unit_id, tag_number)
);

CREATE TABLE components (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    equipment_id UUID NOT NULL REFERENCES equipment(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    component_type VARCHAR(30) NOT NULL,  -- API 581 COMPTYPE: DRUM, PIPE-4, COLBTM, etc.
    -- Material
    material_spec VARCHAR(100),  -- SA-516 Gr70, SA-240 TP304, etc.
    material_group VARCHAR(50),  -- carbon_steel, low_alloy, stainless_300, stainless_400, nickel_alloy
    -- Thickness
    nominal_thickness_mm DECIMAL(8, 3) NOT NULL,
    minimum_required_thickness_mm DECIMAL(8, 3) NOT NULL,
    corrosion_allowance_mm DECIMAL(8, 3),
    -- Current Condition
    measured_thickness_mm DECIMAL(8, 3),
    measurement_date DATE,
    -- Corrosion
    corrosion_rate_mm_yr DECIMAL(8, 4),
    corrosion_rate_source VARCHAR(50) CHECK (corrosion_rate_source IN ('measured', 'calculated', 'estimated', 'published')),
    corrosion_rate_confidence VARCHAR(10) CHECK (corrosion_rate_confidence IN ('low', 'medium', 'high')),
    -- External
    has_insulation BOOLEAN DEFAULT false,
    insulation_type VARCHAR(100),
    has_coating BOOLEAN DEFAULT false,
    coating_condition VARCHAR(20) CHECK (coating_condition IN ('good', 'fair', 'poor', 'none')),
    -- Flags
    is_cml BOOLEAN DEFAULT false,  -- Condition Monitoring Location
    cml_id VARCHAR(50),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 4. PROCESS CONDITIONS & IOW
-- ============================================================

CREATE TABLE process_conditions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    equipment_id UUID NOT NULL REFERENCES equipment(id) ON DELETE CASCADE,
    condition_type VARCHAR(30) NOT NULL CHECK (condition_type IN (
        'normal', 'startup', 'shutdown', 'idle', 'upset', 'emergency', 'cyclic'
    )),
    -- Operating Parameters
    temperature_c DECIMAL(8, 2),
    pressure_kpa DECIMAL(10, 2),
    flow_rate DECIMAL(12, 4),
    flow_rate_unit VARCHAR(20),
    -- Fluid
    fluid_reference VARCHAR(10),  -- API 581 reference fluid key: C1, C3, C6, H2S, etc.
    fluid_phase VARCHAR(10) CHECK (fluid_phase IN ('gas', 'liquid', 'two_phase', 'vapor')),
    fluid_composition TEXT,
    -- Contaminants
    h2s_content_ppm DECIMAL(10, 2),
    co2_content_pct DECIMAL(8, 4),
    chloride_content_ppm DECIMAL(10, 2),
    water_content_pct DECIMAL(8, 4),
    h2_partial_pressure_kpa DECIMAL(10, 2),
    amine_concentration_pct DECIMAL(8, 4),
    caustic_concentration_pct DECIMAL(8, 4),
    acid_concentration_pct DECIMAL(8, 4),
    -- Inventory
    inventory_kg DECIMAL(12, 2),
    inventory_source VARCHAR(50),  -- 'between_valves', 'estimated', 'calculated'
    -- Mitigation Systems
    detection_type CHAR(1) DEFAULT 'C' CHECK (detection_type IN ('A', 'B', 'C')),
    isolation_type CHAR(1) DEFAULT 'C' CHECK (isolation_type IN ('A', 'B', 'C')),
    -- Active flag
    is_current BOOLEAN DEFAULT true,
    effective_date DATE DEFAULT CURRENT_DATE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE integrity_operating_windows (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    corrosion_loop_id UUID REFERENCES corrosion_loops(id),
    equipment_id UUID REFERENCES equipment(id),
    parameter_name VARCHAR(100) NOT NULL,
    parameter_unit VARCHAR(30),
    -- Limits
    critical_low DECIMAL(12, 4),
    standard_low DECIMAL(12, 4),
    informational_low DECIMAL(12, 4),
    informational_high DECIMAL(12, 4),
    standard_high DECIMAL(12, 4),
    critical_high DECIMAL(12, 4),
    -- Metadata
    affected_damage_mechanism VARCHAR(100),
    response_action TEXT,
    monitoring_method VARCHAR(255),
    monitoring_frequency VARCHAR(100),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE iow_exceedances (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    iow_id UUID NOT NULL REFERENCES integrity_operating_windows(id),
    exceedance_type VARCHAR(20) NOT NULL CHECK (exceedance_type IN (
        'critical_low', 'standard_low', 'informational_low',
        'informational_high', 'standard_high', 'critical_high'
    )),
    actual_value DECIMAL(12, 4) NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    duration_hours DECIMAL(10, 2),
    action_taken TEXT,
    rbi_reassessment_triggered BOOLEAN DEFAULT false,
    reported_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 5. DAMAGE MECHANISMS
-- ============================================================

CREATE TABLE damage_mechanisms (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    component_id UUID NOT NULL REFERENCES components(id) ON DELETE CASCADE,
    mechanism_type VARCHAR(50) NOT NULL CHECK (mechanism_type IN (
        -- Thinning
        'thinning_general', 'thinning_localized',
        -- External
        'external_corrosion', 'cui_ferritic', 'cui_austenitic_clscc',
        -- Cracking - SCC family
        'caustic_cracking', 'amine_cracking', 'ssc',
        'hic_sohic_h2s', 'hic_sohic_hf', 'clscc',
        'hsc_hf', 'pascc', 'acscc',
        -- High Temp
        'htha', 'creep',
        -- Metallurgical
        'temper_embrittlement', '885f_embrittlement', 'sigma_embrittlement',
        'brittle_fracture',
        -- Mechanical
        'mechanical_fatigue', 'thermal_fatigue',
        -- Lining
        'lining_damage',
        -- Other
        'erosion', 'other'
    )),
    -- Status
    is_active BOOLEAN DEFAULT true,
    is_credible BOOLEAN DEFAULT true,
    -- Damage Parameters
    susceptibility VARCHAR(20) CHECK (susceptibility IN ('none', 'low', 'medium', 'high', 'very_high')),
    damage_rate DECIMAL(8, 4),  -- mm/yr for thinning
    damage_rate_unit VARCHAR(20),
    -- Assessment
    assessed_by UUID REFERENCES users(id),
    assessed_date DATE,
    basis TEXT,  -- Basis for assessment
    -- API 571 Reference
    api_571_reference VARCHAR(50),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 6. INSPECTION HISTORY
-- ============================================================

CREATE TABLE inspections (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    component_id UUID NOT NULL REFERENCES components(id) ON DELETE CASCADE,
    equipment_id UUID NOT NULL REFERENCES equipment(id),
    -- Inspection Info
    inspection_date DATE NOT NULL,
    inspection_type VARCHAR(50) NOT NULL CHECK (inspection_type IN (
        'internal', 'external', 'on_stream', 'turnaround', 'baseline'
    )),
    -- What was inspected for
    target_damage_mechanism VARCHAR(50) NOT NULL,
    -- NDE Methods used
    nde_methods VARCHAR(255),  -- 'UT, VT, RT' etc.
    -- Coverage
    coverage_percent DECIMAL(5, 2),  -- % of area examined
    coverage_description TEXT,
    -- Effectiveness (API 581 Annex 2.C)
    effectiveness CHAR(1) NOT NULL CHECK (effectiveness IN ('A', 'B', 'C', 'D', 'E')),
    -- Findings
    findings_summary TEXT,
    thickness_measured DECIMAL(8, 3),
    max_corrosion_rate_found DECIMAL(8, 4),
    defects_found BOOLEAN DEFAULT false,
    defect_description TEXT,
    -- Fitness for Service
    ffs_required BOOLEAN DEFAULT false,
    ffs_reference VARCHAR(100),
    ffs_result VARCHAR(50),
    -- Personnel
    inspector_name VARCHAR(255),
    inspector_certification VARCHAR(255),
    reviewed_by UUID REFERENCES users(id),
    -- Status
    status VARCHAR(20) DEFAULT 'completed' CHECK (status IN ('planned', 'in_progress', 'completed', 'cancelled')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 7. MANAGEMENT SYSTEMS EVALUATION
-- ============================================================

CREATE TABLE management_system_evaluations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    facility_id UUID NOT NULL REFERENCES facilities(id),
    evaluation_date DATE NOT NULL,
    evaluated_by UUID REFERENCES users(id),
    -- Scores per API 581 Part 2, Annex 2.A (13 areas, max 1000 total)
    leadership_score INTEGER DEFAULT 0 CHECK (leadership_score BETWEEN 0 AND 70),
    psi_score INTEGER DEFAULT 0 CHECK (psi_score BETWEEN 0 AND 80),
    pha_score INTEGER DEFAULT 0 CHECK (pha_score BETWEEN 0 AND 100),
    moc_score INTEGER DEFAULT 0 CHECK (moc_score BETWEEN 0 AND 80),
    procedures_score INTEGER DEFAULT 0 CHECK (procedures_score BETWEEN 0 AND 80),
    safe_work_score INTEGER DEFAULT 0 CHECK (safe_work_score BETWEEN 0 AND 85),
    training_score INTEGER DEFAULT 0 CHECK (training_score BETWEEN 0 AND 100),
    mi_score INTEGER DEFAULT 0 CHECK (mi_score BETWEEN 0 AND 120),
    pssr_score INTEGER DEFAULT 0 CHECK (pssr_score BETWEEN 0 AND 60),
    emergency_score INTEGER DEFAULT 0 CHECK (emergency_score BETWEEN 0 AND 65),
    incident_score INTEGER DEFAULT 0 CHECK (incident_score BETWEEN 0 AND 75),
    contractors_score INTEGER DEFAULT 0 CHECK (contractors_score BETWEEN 0 AND 45),
    audits_score INTEGER DEFAULT 0 CHECK (audits_score BETWEEN 0 AND 40),
    -- Calculated
    total_score INTEGER GENERATED ALWAYS AS (
        leadership_score + psi_score + pha_score + moc_score +
        procedures_score + safe_work_score + training_score + mi_score +
        pssr_score + emergency_score + incident_score + contractors_score + audits_score
    ) STORED,
    pscore DECIMAL(5, 2) GENERATED ALWAYS AS (
        (leadership_score + psi_score + pha_score + moc_score +
        procedures_score + safe_work_score + training_score + mi_score +
        pssr_score + emergency_score + incident_score + contractors_score + audits_score)::DECIMAL / 10.0
    ) STORED,
    -- Status
    is_current BOOLEAN DEFAULT true,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 8. RBI ASSESSMENT RESULTS
-- ============================================================

CREATE TABLE rbi_assessments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    -- Scope
    process_unit_id UUID REFERENCES process_units(id),
    assessment_type VARCHAR(30) NOT NULL CHECK (assessment_type IN ('qualitative', 'semi_quantitative', 'quantitative')),
    -- Dates
    assessment_date DATE NOT NULL,
    effective_date DATE NOT NULL,
    expiry_date DATE,
    plan_period_years DECIMAL(4, 1) DEFAULT 5.0,
    -- Status
    status VARCHAR(20) DEFAULT 'draft' CHECK (status IN ('draft', 'review', 'approved', 'superseded', 'expired')),
    -- Team
    team_leader_id UUID REFERENCES users(id),
    approved_by UUID REFERENCES users(id),
    approved_date DATE,
    -- Basis
    methodology_description TEXT,
    assumptions TEXT,
    boundary_description TEXT,
    -- Management System
    mgmt_evaluation_id UUID REFERENCES management_system_evaluations(id),
    fms_factor DECIMAL(6, 4),
    -- Metadata
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE rbi_assessment_team (
    assessment_id UUID NOT NULL REFERENCES rbi_assessments(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id),
    role VARCHAR(100) NOT NULL,
    PRIMARY KEY (assessment_id, user_id)
);

CREATE TABLE rbi_component_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    assessment_id UUID NOT NULL REFERENCES rbi_assessments(id) ON DELETE CASCADE,
    component_id UUID NOT NULL REFERENCES components(id),
    equipment_id UUID NOT NULL REFERENCES equipment(id),
    -- Damage Factors (API 581 Part 2)
    df_thinning DECIMAL(12, 4) DEFAULT 1.0,
    df_external DECIMAL(12, 4) DEFAULT 1.0,
    df_scc_governing DECIMAL(12, 4) DEFAULT 1.0,
    df_htha DECIMAL(12, 4) DEFAULT 1.0,
    df_brittle DECIMAL(12, 4) DEFAULT 1.0,
    df_temper_embrittlement DECIMAL(12, 4) DEFAULT 1.0,
    df_885f DECIMAL(12, 4) DEFAULT 1.0,
    df_sigma DECIMAL(12, 4) DEFAULT 1.0,
    df_fatigue DECIMAL(12, 4) DEFAULT 1.0,
    df_lining DECIMAL(12, 4) DEFAULT 1.0,
    df_total DECIMAL(12, 4) NOT NULL,
    -- POF
    gff_total DECIMAL(12, 8),
    fms DECIMAL(6, 4),
    pof DECIMAL(12, 8) NOT NULL,  -- Pf(t) = gff × FMS × Df
    pof_category INTEGER CHECK (pof_category BETWEEN 1 AND 5),
    -- COF
    cof_area_flam DECIMAL(12, 2),    -- ft²
    cof_area_toxic DECIMAL(12, 2),
    cof_area_nfnt DECIMAL(12, 2),
    cof_area_total DECIMAL(12, 2) NOT NULL,
    cof_financial DECIMAL(15, 2),     -- USD
    cof_category CHAR(1) CHECK (cof_category IN ('A', 'B', 'C', 'D', 'E')),
    -- Risk
    risk_area DECIMAL(15, 6),         -- ft²/yr
    risk_financial DECIMAL(15, 2),    -- USD/yr
    risk_level VARCHAR(20) CHECK (risk_level IN ('Low', 'Medium', 'Medium-High', 'High')),
    risk_acceptable BOOLEAN,
    risk_driver VARCHAR(20) CHECK (risk_driver IN ('pof', 'cof', 'both')),
    -- Remaining Life
    remaining_life_years DECIMAL(8, 2),
    art_parameter DECIMAL(6, 4),
    -- Calculation Details (full JSON for audit)
    calculation_details JSONB,
    -- Notes
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 9. INSPECTION PLANNING
-- ============================================================

CREATE TABLE inspection_plans (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    assessment_id UUID NOT NULL REFERENCES rbi_assessments(id),
    component_id UUID NOT NULL REFERENCES components(id),
    equipment_id UUID NOT NULL REFERENCES equipment(id),
    -- For which damage mechanism
    target_damage_mechanism VARCHAR(50) NOT NULL,
    -- Inspection Strategy
    inspection_method VARCHAR(255) NOT NULL,  -- e.g. 'UT scanning', 'WFMT', 'RT profile'
    required_effectiveness CHAR(1) NOT NULL CHECK (required_effectiveness IN ('A', 'B', 'C', 'D')),
    coverage_percent DECIMAL(5, 2),
    coverage_description TEXT,
    -- Timing
    inspection_interval_months INTEGER,
    next_inspection_date DATE NOT NULL,
    due_date DATE NOT NULL,
    -- Risk Before/After
    risk_before DECIMAL(15, 6),
    risk_after_planned DECIMAL(15, 6),
    pof_before DECIMAL(12, 8),
    pof_after_planned DECIMAL(12, 8),
    -- Priority
    priority VARCHAR(10) CHECK (priority IN ('critical', 'high', 'medium', 'low')),
    -- Execution Status
    status VARCHAR(20) DEFAULT 'planned' CHECK (status IN (
        'planned', 'scheduled', 'in_progress', 'completed', 'deferred', 'cancelled'
    )),
    completed_inspection_id UUID REFERENCES inspections(id),
    -- Approval
    approved_by UUID REFERENCES users(id),
    approved_date DATE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 10. MITIGATION ACTIONS (Non-Inspection)
-- ============================================================

CREATE TABLE mitigation_actions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    assessment_id UUID REFERENCES rbi_assessments(id),
    equipment_id UUID NOT NULL REFERENCES equipment(id),
    component_id UUID REFERENCES components(id),
    -- Action Type
    action_type VARCHAR(50) NOT NULL CHECK (action_type IN (
        'repair', 'replacement', 'material_upgrade', 'process_change',
        'chemical_treatment', 'coating_application', 'insulation_change',
        'redesign', 'rerate', 'emergency_isolation', 'depressurize',
        'inventory_reduction', 'detection_upgrade', 'iow_implementation',
        'monitoring_addition', 'other'
    )),
    description TEXT NOT NULL,
    -- Impact
    risk_reduction_pct DECIMAL(5, 2),
    affects_pof BOOLEAN DEFAULT false,
    affects_cof BOOLEAN DEFAULT false,
    -- Costs
    estimated_cost DECIMAL(15, 2),
    actual_cost DECIMAL(15, 2),
    -- Timeline
    target_date DATE,
    completed_date DATE,
    -- Status
    status VARCHAR(20) DEFAULT 'open' CHECK (status IN (
        'open', 'in_progress', 'completed', 'deferred', 'cancelled'
    )),
    -- Tracking
    assigned_to UUID REFERENCES users(id),
    approved_by UUID REFERENCES users(id),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 11. MOC (MANAGEMENT OF CHANGE) INTEGRATION
-- ============================================================

CREATE TABLE moc_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    moc_number VARCHAR(50) UNIQUE NOT NULL,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    change_type VARCHAR(50) CHECK (change_type IN (
        'process', 'equipment', 'material', 'operating_conditions',
        'chemical', 'personnel', 'organizational', 'temporary'
    )),
    -- Affected Items
    affected_equipment_ids UUID[],
    affected_process_unit_id UUID REFERENCES process_units(id),
    -- RBI Impact
    rbi_reassessment_required BOOLEAN DEFAULT false,
    reassessment_id UUID REFERENCES rbi_assessments(id),
    -- Status
    status VARCHAR(20) DEFAULT 'open' CHECK (status IN (
        'open', 'review', 'approved', 'implemented', 'closed', 'rejected'
    )),
    initiated_by UUID REFERENCES users(id),
    approved_by UUID REFERENCES users(id),
    implemented_date DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 12. REFERENCE DATA TABLES
-- ============================================================

CREATE TABLE ref_gff (
    component_type VARCHAR(30) PRIMARY KEY,
    equipment_type VARCHAR(100) NOT NULL,
    gff_small DECIMAL(12, 10) NOT NULL,
    gff_medium DECIMAL(12, 10) NOT NULL,
    gff_large DECIMAL(12, 10) NOT NULL,
    gff_rupture DECIMAL(12, 10) NOT NULL,
    gff_total DECIMAL(12, 10) NOT NULL,
    hole_size_small_mm DECIMAL(6, 2) DEFAULT 6.35,
    hole_size_medium_mm DECIMAL(6, 2) DEFAULT 25.4,
    hole_size_large_mm DECIMAL(6, 2) DEFAULT 101.6,
    hole_size_rupture_mm DECIMAL(6, 2) DEFAULT 406.4,
    source VARCHAR(100) DEFAULT 'API 581 Table 3.1'
);

CREATE TABLE ref_fluids (
    fluid_key VARCHAR(10) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    molecular_weight DECIMAL(8, 2),
    boiling_point_c DECIMAL(8, 2),
    auto_ignition_temp_c DECIMAL(8, 2),
    normal_phase VARCHAR(10),
    is_flammable BOOLEAN DEFAULT false,
    is_toxic BOOLEAN DEFAULT false,
    liquid_density_kg_m3 DECIMAL(10, 2),
    ideal_gas_cp DECIMAL(8, 4),
    nbp_k DECIMAL(8, 2),
    source VARCHAR(100) DEFAULT 'API 581 Part 3 Table 4.1'
);

CREATE TABLE ref_inspection_effectiveness (
    category CHAR(1) PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    pof_reduction_factor DECIMAL(6, 4) NOT NULL,
    description TEXT
);

-- ============================================================
-- 13. INDEXES FOR PERFORMANCE
-- ============================================================

CREATE INDEX idx_equipment_unit ON equipment(process_unit_id);
CREATE INDEX idx_equipment_loop ON equipment(corrosion_loop_id);
CREATE INDEX idx_equipment_type ON equipment(equipment_type);
CREATE INDEX idx_equipment_status ON equipment(status);
CREATE INDEX idx_components_equipment ON components(equipment_id);
CREATE INDEX idx_components_type ON components(component_type);
CREATE INDEX idx_damage_mechanisms_component ON damage_mechanisms(component_id);
CREATE INDEX idx_damage_mechanisms_type ON damage_mechanisms(mechanism_type);
CREATE INDEX idx_inspections_component ON inspections(component_id);
CREATE INDEX idx_inspections_date ON inspections(inspection_date);
CREATE INDEX idx_inspections_equipment ON inspections(equipment_id);
CREATE INDEX idx_rbi_results_assessment ON rbi_component_results(assessment_id);
CREATE INDEX idx_rbi_results_risk ON rbi_component_results(risk_level);
CREATE INDEX idx_rbi_results_pof ON rbi_component_results(pof_category);
CREATE INDEX idx_inspection_plans_date ON inspection_plans(next_inspection_date);
CREATE INDEX idx_inspection_plans_status ON inspection_plans(status);
CREATE INDEX idx_inspection_plans_priority ON inspection_plans(priority);
CREATE INDEX idx_iow_exceedances_iow ON iow_exceedances(iow_id);
CREATE INDEX idx_audit_log_entity ON audit_log(entity_type, entity_id);
CREATE INDEX idx_audit_log_user ON audit_log(user_id);
CREATE INDEX idx_process_conditions_equipment ON process_conditions(equipment_id);

-- ============================================================
-- 14. VIEWS FOR COMMON QUERIES
-- ============================================================

-- Risk ranking view across all assessed components
CREATE OR REPLACE VIEW v_risk_ranking AS
SELECT
    r.id as result_id,
    a.id as assessment_id,
    f.name as facility_name,
    pu.name as unit_name,
    e.tag_number,
    e.name as equipment_name,
    c.name as component_name,
    c.component_type,
    r.df_total,
    r.pof,
    r.pof_category,
    r.cof_area_total,
    r.cof_financial,
    r.cof_category,
    r.risk_area,
    r.risk_financial,
    r.risk_level,
    r.risk_acceptable,
    r.risk_driver,
    r.remaining_life_years,
    a.assessment_date,
    a.status as assessment_status
FROM rbi_component_results r
JOIN rbi_assessments a ON r.assessment_id = a.id
JOIN components c ON r.component_id = c.id
JOIN equipment e ON r.equipment_id = e.id
JOIN process_units pu ON e.process_unit_id = pu.id
JOIN plants p ON pu.plant_id = p.id
JOIN facilities f ON p.facility_id = f.id
WHERE a.status = 'approved'
ORDER BY r.risk_financial DESC NULLS LAST;

-- Upcoming inspections view
CREATE OR REPLACE VIEW v_upcoming_inspections AS
SELECT
    ip.id as plan_id,
    e.tag_number,
    e.name as equipment_name,
    c.name as component_name,
    ip.target_damage_mechanism,
    ip.inspection_method,
    ip.required_effectiveness,
    ip.next_inspection_date,
    ip.due_date,
    ip.priority,
    ip.status,
    pu.name as unit_name,
    CASE
        WHEN ip.due_date < CURRENT_DATE THEN 'OVERDUE'
        WHEN ip.due_date < CURRENT_DATE + INTERVAL '30 days' THEN 'DUE_SOON'
        WHEN ip.due_date < CURRENT_DATE + INTERVAL '90 days' THEN 'UPCOMING'
        ELSE 'FUTURE'
    END as urgency
FROM inspection_plans ip
JOIN components c ON ip.component_id = c.id
JOIN equipment e ON ip.equipment_id = e.id
JOIN process_units pu ON e.process_unit_id = pu.id
WHERE ip.status IN ('planned', 'scheduled')
ORDER BY ip.due_date ASC;

-- Equipment risk summary
CREATE OR REPLACE VIEW v_equipment_risk_summary AS
SELECT
    e.id as equipment_id,
    e.tag_number,
    e.name,
    e.equipment_type,
    pu.name as unit_name,
    COUNT(DISTINCT c.id) as component_count,
    MAX(r.pof) as max_pof,
    MAX(r.cof_area_total) as max_cof_area,
    MAX(r.risk_financial) as max_risk_financial,
    MAX(r.risk_level) as highest_risk_level,
    MIN(r.remaining_life_years) as min_remaining_life,
    COUNT(CASE WHEN r.risk_level = 'High' THEN 1 END) as high_risk_count,
    COUNT(CASE WHEN r.risk_level = 'Medium-High' THEN 1 END) as medium_high_risk_count
FROM equipment e
JOIN process_units pu ON e.process_unit_id = pu.id
LEFT JOIN components c ON c.equipment_id = e.id
LEFT JOIN rbi_component_results r ON r.equipment_id = e.id
    AND r.assessment_id = (
        SELECT a2.id FROM rbi_assessments a2
        WHERE a2.process_unit_id = e.process_unit_id
        AND a2.status = 'approved'
        ORDER BY a2.assessment_date DESC LIMIT 1
    )
GROUP BY e.id, e.tag_number, e.name, e.equipment_type, pu.name;

-- ============================================================
-- 15. SEED REFERENCE DATA
-- ============================================================

-- Insert GFF reference data (API 581 Table 3.1)
INSERT INTO ref_gff VALUES
('COMPC', 'Compressor Centrifugal', 8.00E-06, 2.00E-05, 2.00E-06, 0, 3.00E-05),
('COMPR', 'Compressor Reciprocating', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('HEXSS', 'Heat Exchanger Shell Side', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('HEXTS', 'Heat Exchanger Tube Side', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('PIPE-1', 'Pipe NPS ≤ 1', 2.80E-05, 0, 0, 2.60E-06, 3.06E-05),
('PIPE-2', 'Pipe NPS 2', 2.80E-05, 0, 0, 2.60E-06, 3.06E-05),
('PIPE-4', 'Pipe NPS 4', 8.00E-06, 2.00E-05, 0, 2.60E-06, 3.06E-05),
('PIPE-6', 'Pipe NPS 6', 8.00E-06, 2.00E-05, 0, 2.60E-06, 3.06E-05),
('PIPE-8', 'Pipe NPS 8-16+', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('KODRUM', 'KO Drum', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('DRUM', 'Drum / Vessel', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('COLBTM', 'Column Bottom', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('COLMID', 'Column Middle', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('COLTOP', 'Column Top', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('REACTOR', 'Reactor', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('FINFAN', 'Fin Fan / Air Cooler', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('FILTER', 'Filter', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('TANKBTM', 'Tank Bottom', 7.20E-04, 0, 0, 2.00E-06, 7.20E-04),
('COURSE1', 'Tank Shell Course 1', 7.00E-05, 2.50E-05, 5.00E-06, 1.00E-07, 1.00E-04),
('PUMP2S', 'Pump 2-Seal', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05),
('PUMPR', 'Pump Reciprocating', 8.00E-06, 2.00E-05, 2.00E-06, 6.00E-07, 3.06E-05);

-- Insert reference fluids (API 581 Part 3 Table 4.1)
INSERT INTO ref_fluids (fluid_key, name, molecular_weight, boiling_point_c, auto_ignition_temp_c, normal_phase, is_flammable, is_toxic) VALUES
('C1', 'Methane (C1-C2)', 16, -161, 580, 'gas', true, false),
('C3', 'Propane (C3-C4)', 44, -42, 450, 'gas', true, false),
('C6', 'Light Naphtha (C5-C8)', 86, 69, 225, 'liquid', true, false),
('C9', 'Heavy Naphtha (C9-C12)', 120, 150, 230, 'liquid', true, false),
('C13', 'Diesel (C13-C16)', 170, 230, 260, 'liquid', true, false),
('C17', 'Gas Oil (C17-C25)', 280, 300, 300, 'liquid', true, false),
('C25', 'Residuum (C25+)', 422, 400, 350, 'liquid', true, false),
('H2', 'Hydrogen', 2, -253, 500, 'gas', true, false),
('H2S', 'Hydrogen Sulfide', 34, -60, 260, 'gas', true, true),
('HF', 'Hydrofluoric Acid', 20, 19.5, 0, 'liquid', false, true),
('Water', 'Water / Steam', 18, 100, 0, 'liquid', false, false),
('Acid', 'Acid (H2SO4/HCl)', 98, 337, 0, 'liquid', false, true),
('NH3', 'Ammonia', 17, -33, 0, 'gas', false, true);

-- Insert inspection effectiveness reference
INSERT INTO ref_inspection_effectiveness VALUES
('A', 'Highly Effective', 0.01, 'Correctly identifies true damage state nearly every time'),
('B', 'Usually Effective', 0.10, 'Correctly identifies true damage state most of the time'),
('C', 'Fairly Effective', 0.20, 'May miss damage or understate damage'),
('D', 'Poorly Effective', 0.50, 'Likely to miss damage or provide inaccurate assessment'),
('E', 'Ineffective', 1.00, 'Provides no meaningful information about damage');

-- ============================================================
-- 16. FUNCTIONS
-- ============================================================

-- Calculate Management System Factor
CREATE OR REPLACE FUNCTION calc_fms(p_total_score INTEGER)
RETURNS DECIMAL AS $$
DECLARE
    v_pscore DECIMAL;
    v_fms DECIMAL;
BEGIN
    v_pscore := p_total_score::DECIMAL / 10.0;  -- percentage
    v_fms := POWER(10, -0.02 * v_pscore + 1);
    RETURN GREATEST(0.1, LEAST(v_fms, 10.0));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Get risk level from POF category and COF category
CREATE OR REPLACE FUNCTION get_risk_level(p_pof_cat INTEGER, p_cof_cat INTEGER)
RETURNS VARCHAR AS $$
DECLARE
    v_score INTEGER;
BEGIN
    v_score := p_pof_cat + p_cof_cat;
    IF v_score <= 3 THEN RETURN 'Low';
    ELSIF v_score <= 5 THEN RETURN 'Medium';
    ELSIF v_score <= 7 THEN RETURN 'Medium-High';
    ELSE RETURN 'High';
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Get POF category from POF value
CREATE OR REPLACE FUNCTION get_pof_category(p_pof DECIMAL)
RETURNS INTEGER AS $$
BEGIN
    IF p_pof <= 3.06E-05 THEN RETURN 1;
    ELSIF p_pof <= 3.06E-04 THEN RETURN 2;
    ELSIF p_pof <= 3.06E-03 THEN RETURN 3;
    ELSIF p_pof <= 3.06E-02 THEN RETURN 4;
    ELSE RETURN 5;
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Get COF category from COF area value
CREATE OR REPLACE FUNCTION get_cof_category(p_cof_area DECIMAL)
RETURNS CHAR AS $$
BEGIN
    IF p_cof_area <= 100 THEN RETURN 'A';
    ELSIF p_cof_area <= 1000 THEN RETURN 'B';
    ELSIF p_cof_area <= 10000 THEN RETURN 'C';
    ELSIF p_cof_area <= 100000 THEN RETURN 'D';
    ELSE RETURN 'E';
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================
-- SCHEMA VERSION TRACKING
-- ============================================================
CREATE TABLE schema_version (
    version VARCHAR(20) PRIMARY KEY,
    description TEXT,
    applied_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO schema_version VALUES ('1.0.0', 'Initial RBI database schema - API 580/581 compliant', NOW());
