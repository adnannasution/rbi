/**
 * RBI Application - Backend API Server
 * API RP 580 / API 581 Compliant
 * 
 * Stack: Express.js + PostgreSQL (pg) + JWT Auth
 * Run: npm install express pg bcryptjs jsonwebtoken cors helmet dotenv
 */

const express = require('express');
const { Pool } = require('pg');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const cors = require('cors');
const helmet = require('helmet');
require('dotenv').config();
const fs = require('fs');
const path = require('path');

const app = express();
app.use(express.json());
app.use(cors());
app.use(helmet());

// Serve frontend
app.use(express.static(path.join(__dirname, 'public')));

// ============================================================
// DATABASE CONNECTION
// ============================================================
const pool = new Pool(
  process.env.DATABASE_URL
    ? {
        connectionString: process.env.DATABASE_URL,
        ssl: { rejectUnauthorized: false },
        max: 20,
        idleTimeoutMillis: 30000,
      }
    : {
        host: process.env.DB_HOST || 'localhost',
        port: process.env.DB_PORT || 5432,
        database: process.env.DB_NAME || 'rbi_app',
        user: process.env.DB_USER || 'rbi_admin',
        password: process.env.DB_PASS || 'secure_password',
        max: 20,
        idleTimeoutMillis: 30000,
      }
);

const JWT_SECRET = process.env.JWT_SECRET || 'rbi-app-secret-key-change-in-production';

// ============================================================
// MIDDLEWARE: AUTH
// ============================================================
const authenticate = async (req, res, next) => {
  try {
    const token = req.headers.authorization?.replace('Bearer ', '');
    if (!token) return res.status(401).json({ error: 'Authentication required' });
    const decoded = jwt.verify(token, JWT_SECRET);
    const { rows } = await pool.query('SELECT id, email, full_name, role FROM users WHERE id = $1 AND is_active = true', [decoded.userId]);
    if (!rows[0]) return res.status(401).json({ error: 'User not found or inactive' });
    req.user = rows[0];
    next();
  } catch (err) {
    res.status(401).json({ error: 'Invalid token' });
  }
};

const authorize = (...roles) => (req, res, next) => {
  if (!roles.includes(req.user.role)) return res.status(403).json({ error: 'Insufficient permissions' });
  next();
};

// Audit logging helper
const auditLog = async (userId, action, entityType, entityId, oldValues, newValues) => {
  await pool.query(
    'INSERT INTO audit_log (user_id, action, entity_type, entity_id, old_values, new_values) VALUES ($1,$2,$3,$4,$5,$6)',
    [userId, action, entityType, entityId, oldValues ? JSON.stringify(oldValues) : null, newValues ? JSON.stringify(newValues) : null]
  );
};

// ============================================================
// AUTH ROUTES
// ============================================================
app.post('/api/auth/login', async (req, res) => {
  try {
    const { email, password } = req.body;
    const { rows } = await pool.query('SELECT * FROM users WHERE email = $1 AND is_active = true', [email]);
    if (!rows[0] || !await bcrypt.compare(password, rows[0].password_hash))
      return res.status(401).json({ error: 'Invalid credentials' });
    const token = jwt.sign({ userId: rows[0].id }, JWT_SECRET, { expiresIn: '12h' });
    await pool.query('UPDATE users SET last_login = NOW() WHERE id = $1', [rows[0].id]);
    res.json({ token, user: { id: rows[0].id, email: rows[0].email, name: rows[0].full_name, role: rows[0].role } });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// ============================================================
// ASSET HIERARCHY ROUTES
// ============================================================

// Facilities
app.get('/api/facilities', authenticate, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM facilities ORDER BY name');
  res.json(rows);
});

app.post('/api/facilities', authenticate, authorize('admin', 'team_leader'), async (req, res) => {
  const { name, code, location, climate_type } = req.body;
  const { rows } = await pool.query(
    'INSERT INTO facilities (name, code, location, climate_type) VALUES ($1,$2,$3,$4) RETURNING *',
    [name, code, location, climate_type]
  );
  await auditLog(req.user.id, 'CREATE', 'facility', rows[0].id, null, rows[0]);
  res.status(201).json(rows[0]);
});

// Process Units
app.get('/api/plants/:plantId/units', authenticate, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM process_units WHERE plant_id = $1 ORDER BY code', [req.params.plantId]);
  res.json(rows);
});

// Equipment
app.get('/api/units/:unitId/equipment', authenticate, async (req, res) => {
  const { rows } = await pool.query(`
    SELECT e.*, cl.name as loop_name
    FROM equipment e
    LEFT JOIN corrosion_loops cl ON e.corrosion_loop_id = cl.id
    WHERE e.process_unit_id = $1
    ORDER BY e.tag_number
  `, [req.params.unitId]);
  res.json(rows);
});

app.get('/api/equipment/:id', authenticate, async (req, res) => {
  const { rows } = await pool.query(`
    SELECT e.*, pu.name as unit_name, cl.name as loop_name
    FROM equipment e
    JOIN process_units pu ON e.process_unit_id = pu.id
    LEFT JOIN corrosion_loops cl ON e.corrosion_loop_id = cl.id
    WHERE e.id = $1
  `, [req.params.id]);
  if (!rows[0]) return res.status(404).json({ error: 'Equipment not found' });
  res.json(rows[0]);
});

app.post('/api/equipment', authenticate, authorize('admin', 'team_leader', 'inspector'), async (req, res) => {
  const { process_unit_id, corrosion_loop_id, tag_number, name, equipment_type, design_pressure, design_temperature, mawp } = req.body;
  const { rows } = await pool.query(
    `INSERT INTO equipment (process_unit_id, corrosion_loop_id, tag_number, name, equipment_type, design_pressure, design_temperature, mawp)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`,
    [process_unit_id, corrosion_loop_id, tag_number, name, equipment_type, design_pressure, design_temperature, mawp]
  );
  await auditLog(req.user.id, 'CREATE', 'equipment', rows[0].id, null, rows[0]);
  res.status(201).json(rows[0]);
});

// Components
app.get('/api/equipment/:eqId/components', authenticate, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM components WHERE equipment_id = $1 ORDER BY name', [req.params.eqId]);
  res.json(rows);
});

app.post('/api/components', authenticate, authorize('admin', 'team_leader', 'inspector'), async (req, res) => {
  const { rows } = await pool.query(
    `INSERT INTO components (equipment_id, name, component_type, material_spec, material_group,
     nominal_thickness_mm, minimum_required_thickness_mm, corrosion_allowance_mm,
     corrosion_rate_mm_yr, corrosion_rate_source, corrosion_rate_confidence,
     has_insulation, coating_condition)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING *`,
    [req.body.equipment_id, req.body.name, req.body.component_type, req.body.material_spec,
     req.body.material_group, req.body.nominal_thickness_mm, req.body.minimum_required_thickness_mm,
     req.body.corrosion_allowance_mm, req.body.corrosion_rate_mm_yr, req.body.corrosion_rate_source,
     req.body.corrosion_rate_confidence, req.body.has_insulation, req.body.coating_condition]
  );
  await auditLog(req.user.id, 'CREATE', 'component', rows[0].id, null, rows[0]);
  res.status(201).json(rows[0]);
});

// ============================================================
// DAMAGE MECHANISMS
// ============================================================
app.get('/api/components/:compId/damage-mechanisms', authenticate, async (req, res) => {
  const { rows } = await pool.query(
    'SELECT * FROM damage_mechanisms WHERE component_id = $1 ORDER BY mechanism_type',
    [req.params.compId]
  );
  res.json(rows);
});

app.post('/api/damage-mechanisms', authenticate, authorize('admin', 'corrosion_specialist', 'team_leader'), async (req, res) => {
  const { component_id, mechanism_type, susceptibility, damage_rate, basis } = req.body;
  const { rows } = await pool.query(
    `INSERT INTO damage_mechanisms (component_id, mechanism_type, susceptibility, damage_rate, basis, assessed_by, assessed_date)
     VALUES ($1,$2,$3,$4,$5,$6,CURRENT_DATE) RETURNING *`,
    [component_id, mechanism_type, susceptibility, damage_rate, basis, req.user.id]
  );
  await auditLog(req.user.id, 'CREATE', 'damage_mechanism', rows[0].id, null, rows[0]);
  res.status(201).json(rows[0]);
});

// ============================================================
// INSPECTIONS
// ============================================================
app.get('/api/equipment/:eqId/inspections', authenticate, async (req, res) => {
  const { rows } = await pool.query(`
    SELECT i.*, c.name as component_name
    FROM inspections i
    JOIN components c ON i.component_id = c.id
    WHERE i.equipment_id = $1
    ORDER BY i.inspection_date DESC
  `, [req.params.eqId]);
  res.json(rows);
});

app.post('/api/inspections', authenticate, authorize('admin', 'inspector', 'team_leader'), async (req, res) => {
  const { rows } = await pool.query(
    `INSERT INTO inspections (component_id, equipment_id, inspection_date, inspection_type,
     target_damage_mechanism, nde_methods, coverage_percent, effectiveness,
     findings_summary, thickness_measured, inspector_name, reviewed_by)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING *`,
    [req.body.component_id, req.body.equipment_id, req.body.inspection_date, req.body.inspection_type,
     req.body.target_damage_mechanism, req.body.nde_methods, req.body.coverage_percent,
     req.body.effectiveness, req.body.findings_summary, req.body.thickness_measured,
     req.body.inspector_name, req.user.id]
  );
  await auditLog(req.user.id, 'CREATE', 'inspection', rows[0].id, null, rows[0]);
  res.status(201).json(rows[0]);
});

// ============================================================
// RBI ASSESSMENT & CALCULATION ENGINE
// ============================================================

// API 581 Calculation Functions
const calcFMS = (evaluation) => {
  const total = evaluation.total_score;
  const pscore = total / 10.0;
  return Math.max(0.1, Math.min(Math.pow(10, -0.02 * pscore + 1), 10));
};

const calcThinningDF = (tNom, tMin, corrRate, age, inspections, confidence) => {
  const wallLoss = corrRate * age;
  const Art = Math.min(wallLoss / tNom, 1.5);
  let base;
  if (Art <= 0.1) base = 1 + Art * 10;
  else if (Art <= 0.2) base = 2 + (Art - 0.1) * 30;
  else if (Art <= 0.3) base = 5 + (Art - 0.2) * 80;
  else if (Art <= 0.5) base = 13 + (Art - 0.3) * 200;
  else if (Art <= 0.8) base = 53 + (Art - 0.5) * 500;
  else base = 203 + (Art - 0.8) * 5000;

  const effFactors = { A: 0.01, B: 0.1, C: 0.2, D: 0.5, E: 1.0 };
  let inspCredit = inspections.reduce((c, i) => c * (effFactors[i.effectiveness] || 1), 1);
  inspCredit = Math.max(inspCredit, 0.01);

  const tActual = Math.max(tNom - wallLoss, 0);
  const remainingLife = corrRate > 0 && tActual > tMin ? (tActual - tMin) / corrRate : 0;

  return { Art, base, inspCredit, df: Math.max(base * inspCredit, 1), wallLoss, tActual, remainingLife };
};

const getPOFCategory = (pof) => pof <= 3.06e-5 ? 1 : pof <= 3.06e-4 ? 2 : pof <= 3.06e-3 ? 3 : pof <= 3.06e-2 ? 4 : 5;
const getCOFCategory = (cof) => cof <= 100 ? 'A' : cof <= 1000 ? 'B' : cof <= 10000 ? 'C' : cof <= 100000 ? 'D' : 'E';
const getRiskLevel = (pofCat, cofCatNum) => {
  const s = pofCat + cofCatNum;
  return s <= 3 ? 'Low' : s <= 5 ? 'Medium' : s <= 7 ? 'Medium-High' : 'High';
};

// Create/Run RBI Assessment
app.post('/api/assessments', authenticate, authorize('admin', 'team_leader', 'risk_analyst'), async (req, res) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    const { process_unit_id, assessment_type, plan_period_years, assumptions } = req.body;

    // Get management system evaluation
    const { rows: [mgmtEval] } = await client.query(`
      SELECT * FROM management_system_evaluations
      WHERE facility_id = (SELECT p.facility_id FROM plants p JOIN process_units pu ON pu.plant_id = p.id WHERE pu.id = $1)
      AND is_current = true ORDER BY evaluation_date DESC LIMIT 1
    `, [process_unit_id]);

    const fms = mgmtEval ? calcFMS(mgmtEval) : 1.0;

    // Create assessment record
    const { rows: [assessment] } = await client.query(
      `INSERT INTO rbi_assessments (process_unit_id, assessment_type, assessment_date, effective_date,
       plan_period_years, team_leader_id, mgmt_evaluation_id, fms_factor, assumptions, status)
       VALUES ($1,$2,CURRENT_DATE,CURRENT_DATE,$3,$4,$5,$6,$7,'draft') RETURNING *`,
      [process_unit_id, assessment_type, plan_period_years || 5, req.user.id,
       mgmtEval?.id, fms, assumptions]
    );

    // Get all components in the process unit
    const { rows: components } = await client.query(`
      SELECT c.*, e.tag_number, e.id as equipment_id
      FROM components c
      JOIN equipment e ON c.equipment_id = e.id
      WHERE e.process_unit_id = $1 AND e.status = 'in_service'
    `, [process_unit_id]);

    // Calculate risk for each component
    for (const comp of components) {
      // Get inspections for this component
      const { rows: inspections } = await client.query(
        'SELECT * FROM inspections WHERE component_id = $1 ORDER BY inspection_date DESC',
        [comp.id]
      );

      // Get GFF
      const { rows: [gffRow] } = await client.query(
        'SELECT * FROM ref_gff WHERE component_type = $1',
        [comp.component_type]
      );
      const gffTotal = gffRow?.gff_total || 3.06e-5;

      // Calculate thinning DF
      const age = comp.measurement_date
        ? (Date.now() - new Date(comp.measurement_date).getTime()) / (365.25 * 24 * 3600 * 1000)
        : comp.commissioning_date
          ? (Date.now() - new Date(comp.commissioning_date).getTime()) / (365.25 * 24 * 3600 * 1000)
          : 10;

      const thinInsp = inspections.filter(i => ['thinning_general', 'thinning_localized'].includes(i.target_damage_mechanism));
      const thinResult = calcThinningDF(
        comp.nominal_thickness_mm, comp.minimum_required_thickness_mm,
        comp.corrosion_rate_mm_yr || 0.1, age, thinInsp, comp.corrosion_rate_confidence || 'low'
      );

      // Total DF (simplified - add more DFs as needed)
      const dfTotal = Math.max(thinResult.df, 1);

      // POF
      const pof = Math.min(gffTotal * fms * dfTotal, 1);
      const pofCat = getPOFCategory(pof);

      // Get process conditions for COF
      const { rows: [procCond] } = await client.query(
        `SELECT * FROM process_conditions WHERE equipment_id = $1 AND is_current = true
         AND condition_type = 'normal' ORDER BY effective_date DESC LIMIT 1`,
        [comp.equipment_id]
      );

      // Simplified COF calculation
      const cofArea = procCond ? (procCond.inventory_kg || 1000) * 0.5 : 500;
      const cofCat = getCOFCategory(cofArea);
      const cofCatNum = { A: 1, B: 2, C: 3, D: 4, E: 5 }[cofCat];
      const riskLevel = getRiskLevel(pofCat, cofCatNum);
      const riskArea = pof * cofArea;
      const riskFinancial = pof * (procCond?.inventory_kg || 1000) * 50;

      // Insert result
      await client.query(
        `INSERT INTO rbi_component_results
         (assessment_id, component_id, equipment_id, df_thinning, df_total,
          gff_total, fms, pof, pof_category, cof_area_total, cof_category,
          risk_area, risk_financial, risk_level, risk_acceptable,
          remaining_life_years, art_parameter, calculation_details)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)`,
        [assessment.id, comp.id, comp.equipment_id, thinResult.df, dfTotal,
         gffTotal, fms, pof, pofCat, cofArea, cofCat,
         riskArea, riskFinancial, riskLevel, riskLevel === 'Low' || riskLevel === 'Medium',
         thinResult.remainingLife, thinResult.Art,
         JSON.stringify({ thinning: thinResult, gff: gffTotal, fms, age })]
      );
    }

    await client.query('COMMIT');
    await auditLog(req.user.id, 'CREATE', 'assessment', assessment.id, null, { components_assessed: components.length });

    res.status(201).json({
      assessment,
      components_assessed: components.length,
      fms,
    });
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(500).json({ error: err.message });
  } finally {
    client.release();
  }
});

// Get assessment results with risk ranking
app.get('/api/assessments/:id/results', authenticate, async (req, res) => {
  const { rows } = await pool.query(`
    SELECT r.*, e.tag_number, e.name as equipment_name, c.name as component_name,
           c.component_type, c.corrosion_rate_mm_yr
    FROM rbi_component_results r
    JOIN equipment e ON r.equipment_id = e.id
    JOIN components c ON r.component_id = c.id
    WHERE r.assessment_id = $1
    ORDER BY r.risk_financial DESC
  `, [req.params.id]);
  res.json(rows);
});

// ============================================================
// INSPECTION PLANNING
// ============================================================
app.post('/api/assessments/:id/generate-plans', authenticate, authorize('admin', 'team_leader', 'inspector'), async (req, res) => {
  const { risk_target = 5.0 } = req.body;
  const assessmentId = req.params.id;

  const { rows: results } = await pool.query(
    'SELECT * FROM rbi_component_results WHERE assessment_id = $1 ORDER BY risk_financial DESC',
    [assessmentId]
  );

  const plans = [];
  for (const r of results) {
    // Calculate optimal interval based on risk projection
    const maxInterval = r.risk_area > risk_target ? 1 :
      r.risk_area > risk_target * 0.5 ? 2 :
      r.risk_area > risk_target * 0.2 ? 3 :
      r.risk_area > risk_target * 0.1 ? 5 : 10;

    const requiredEff = r.risk_level === 'High' ? 'A' :
      r.risk_level === 'Medium-High' ? 'B' :
      r.risk_level === 'Medium' ? 'C' : 'D';

    const priority = r.risk_level === 'High' ? 'critical' :
      r.risk_level === 'Medium-High' ? 'high' :
      r.risk_level === 'Medium' ? 'medium' : 'low';

    const nextDate = new Date();
    nextDate.setMonth(nextDate.getMonth() + maxInterval * 12);

    const { rows: [plan] } = await pool.query(
      `INSERT INTO inspection_plans
       (assessment_id, component_id, equipment_id, target_damage_mechanism,
        inspection_method, required_effectiveness, inspection_interval_months,
        next_inspection_date, due_date, risk_before, pof_before, priority, status)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,'planned') RETURNING *`,
      [assessmentId, r.component_id, r.equipment_id, 'thinning_general',
       requiredEff === 'A' ? 'Full UT Scanning + WFMT' : 'UT Thickness Survey',
       requiredEff, maxInterval * 12, nextDate, nextDate,
       r.risk_area, r.pof, priority]
    );
    plans.push(plan);
  }

  res.status(201).json({ plans_generated: plans.length, plans });
});

app.get('/api/inspection-plans/upcoming', authenticate, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM v_upcoming_inspections LIMIT 100');
  res.json(rows);
});

// ============================================================
// RISK RANKING VIEWS
// ============================================================
app.get('/api/risk-ranking', authenticate, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM v_risk_ranking LIMIT 500');
  res.json(rows);
});

app.get('/api/equipment-summary', authenticate, async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM v_equipment_risk_summary ORDER BY max_risk_financial DESC NULLS LAST');
  res.json(rows);
});

// ============================================================
// IOW MONITORING
// ============================================================
app.post('/api/iow-exceedances', authenticate, async (req, res) => {
  const { iow_id, exceedance_type, actual_value, started_at, action_taken } = req.body;
  const { rows } = await pool.query(
    `INSERT INTO iow_exceedances (iow_id, exceedance_type, actual_value, started_at, action_taken, reported_by)
     VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`,
    [iow_id, exceedance_type, actual_value, started_at, action_taken, req.user.id]
  );

  // Check if critical exceedance triggers reassessment
  if (exceedance_type.startsWith('critical')) {
    await pool.query('UPDATE iow_exceedances SET rbi_reassessment_triggered = true WHERE id = $1', [rows[0].id]);
  }

  res.status(201).json(rows[0]);
});

// ============================================================
// MOC INTEGRATION
// ============================================================
app.post('/api/moc', authenticate, async (req, res) => {
  const { moc_number, title, description, change_type, affected_equipment_ids, affected_process_unit_id } = req.body;
  const { rows } = await pool.query(
    `INSERT INTO moc_records (moc_number, title, description, change_type, affected_equipment_ids,
     affected_process_unit_id, initiated_by, rbi_reassessment_required)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`,
    [moc_number, title, description, change_type, affected_equipment_ids,
     affected_process_unit_id, req.user.id,
     ['process', 'equipment', 'material', 'operating_conditions'].includes(change_type)]
  );
  await auditLog(req.user.id, 'CREATE', 'moc', rows[0].id, null, rows[0]);
  res.status(201).json(rows[0]);
});

// ============================================================
// MANAGEMENT SYSTEMS
// ============================================================
app.post('/api/management-evaluations', authenticate, authorize('admin', 'team_leader'), async (req, res) => {
  // Set previous evaluations as non-current
  await pool.query('UPDATE management_system_evaluations SET is_current = false WHERE facility_id = $1', [req.body.facility_id]);

  const { rows } = await pool.query(
    `INSERT INTO management_system_evaluations
     (facility_id, evaluation_date, evaluated_by,
      leadership_score, psi_score, pha_score, moc_score, procedures_score,
      safe_work_score, training_score, mi_score, pssr_score,
      emergency_score, incident_score, contractors_score, audits_score, is_current)
     VALUES ($1, CURRENT_DATE, $2, $3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15, true) RETURNING *`,
    [req.body.facility_id, req.user.id,
     req.body.leadership_score, req.body.psi_score, req.body.pha_score,
     req.body.moc_score, req.body.procedures_score, req.body.safe_work_score,
     req.body.training_score, req.body.mi_score, req.body.pssr_score,
     req.body.emergency_score, req.body.incident_score, req.body.contractors_score,
     req.body.audits_score]
  );

  const fms = calcFMS(rows[0]);
  res.status(201).json({ ...rows[0], fms_factor: fms });
});

// ============================================================
// DASHBOARD STATS
// ============================================================
app.get('/api/dashboard/stats', authenticate, async (req, res) => {
  const [
    { rows: [eqCount] },
    { rows: riskDist },
    { rows: [upcomingCount] },
    { rows: topRisk },
  ] = await Promise.all([
    pool.query('SELECT COUNT(*) as total FROM equipment WHERE status = \'in_service\''),
    pool.query(`
      SELECT risk_level, COUNT(*) as count
      FROM rbi_component_results r
      JOIN rbi_assessments a ON r.assessment_id = a.id
      WHERE a.status = 'approved'
      GROUP BY risk_level
    `),
    pool.query(`SELECT COUNT(*) as total FROM v_upcoming_inspections WHERE urgency IN ('OVERDUE','DUE_SOON')`),
    pool.query('SELECT * FROM v_risk_ranking LIMIT 10'),
  ]);

  res.json({
    total_equipment: parseInt(eqCount.total),
    risk_distribution: riskDist,
    urgent_inspections: parseInt(upcomingCount.total),
    top_risk_items: topRisk,
  });
});

// ============================================================
// START SERVER
// ============================================================
// Auto-migrate schema on startup
async function runMigrations() {
  try {
    const schemaPath = path.join(__dirname, 'schema.sql');
    if (fs.existsSync(schemaPath)) {
      const schema = fs.readFileSync(schemaPath, 'utf8');
      await pool.query(schema);
      console.log('✅ Schema applied');
    }
  } catch (err) {
    console.log('ℹ️ Migration note:', err.message.split('\n')[0]);
  }
}

const PORT = process.env.PORT || 3001;

async function startServer() {
  await runMigrations();
  app.listen(PORT, () => {
    console.log(`RBI API Server running on port ${PORT}`);
  console.log('Endpoints:');
  console.log('  POST   /api/auth/login');
  console.log('  GET    /api/facilities');
  console.log('  GET    /api/units/:unitId/equipment');
  console.log('  GET    /api/equipment/:id');
  console.log('  POST   /api/assessments');
  console.log('  GET    /api/assessments/:id/results');
  console.log('  POST   /api/assessments/:id/generate-plans');
  console.log('  GET    /api/risk-ranking');
  console.log('  GET    /api/inspection-plans/upcoming');
  console.log('  GET    /api/dashboard/stats');
  });
}

startServer();

// Catch-all route
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

module.exports = app;
