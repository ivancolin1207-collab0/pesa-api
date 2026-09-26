-- ═══════════════════════════════════════════════════════════════════════════
-- MIGRACIÓN v3 — Servicios PESA
-- Expansión del módulo Revisión de Báscula (RE)
-- Secciones: Inspección visual, Ohms por celda, Periféricos, Estatus
-- Ejecutar: psql -U postgres -d servicios_pesa -f database/migration_v3.sql
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Ampliar revisiones_bascula con nuevos campos ────────────────────────
ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS horario              VARCHAR(60),            -- Hora inicio / fin
    ADD COLUMN IF NOT EXISTS contacto_nombre     VARCHAR(150),           -- Quien recibe
    ADD COLUMN IF NOT EXISTS contacto_telefono   VARCHAR(30),
    ADD COLUMN IF NOT EXISTS contacto_correo     VARCHAR(150),
    ADD COLUMN IF NOT EXISTS estatus_revision    VARCHAR(30)
        NOT NULL DEFAULT 'PENDIENTE'
        CHECK (estatus_revision IN ('COMPLETA','PENDIENTE','PARCIAL')),
    ADD COLUMN IF NOT EXISTS obs_cables_conectores TEXT,
    ADD COLUMN IF NOT EXISTS obs_generales       TEXT;

COMMENT ON COLUMN revisiones_bascula.horario              IS 'Horario de realización, ej: 09:00 - 14:00';
COMMENT ON COLUMN revisiones_bascula.contacto_nombre      IS 'Nombre del contacto/receptor en el cliente';
COMMENT ON COLUMN revisiones_bascula.estatus_revision     IS 'COMPLETA | PENDIENTE | PARCIAL';

-- ── 2. Ampliar det_celdas_carga con lecturas Ohms completas ────────────────
ALTER TABLE det_celdas_carga
    ADD COLUMN IF NOT EXISTS exc_plus_minus        NUMERIC(10,4),   -- Exc+ / Exc-
    ADD COLUMN IF NOT EXISTS sig_plus_minus        NUMERIC(10,4),   -- Sig+ / Sig-
    ADD COLUMN IF NOT EXISTS sig_plus_exc_plus     NUMERIC(10,4),   -- Sig+ / Exc+
    ADD COLUMN IF NOT EXISTS sig_minus_exc_minus   NUMERIC(10,4),   -- Sig- / Exc-
    ADD COLUMN IF NOT EXISTS resistencia_entrada   NUMERIC(10,4),   -- Res. Entrada (Ω)
    ADD COLUMN IF NOT EXISTS resistencia_salida    NUMERIC(10,4),   -- Res. Salida  (Ω)
    ADD COLUMN IF NOT EXISTS funciona              BOOLEAN  DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS obs_funcionalidad     TEXT;

COMMENT ON COLUMN det_celdas_carga.exc_plus_minus      IS 'Lectura Ohms Excitación Exc+ / Exc-';
COMMENT ON COLUMN det_celdas_carga.sig_plus_minus      IS 'Lectura Ohms Señal Sig+ / Sig-';
COMMENT ON COLUMN det_celdas_carga.sig_plus_exc_plus   IS 'Lectura Ohms Sig+ / Exc+';
COMMENT ON COLUMN det_celdas_carga.sig_minus_exc_minus IS 'Lectura Ohms Sig- / Exc-';
COMMENT ON COLUMN det_celdas_carga.resistencia_entrada IS 'Resistencia de Entrada (Ω)';
COMMENT ON COLUMN det_celdas_carga.resistencia_salida  IS 'Resistencia de Salida (Ω)';
COMMENT ON COLUMN det_celdas_carga.funciona            IS 'La celda funciona correctamente';

-- ── 3. Inspección Visual y Funcional (9 puntos) ────────────────────────────
CREATE TABLE IF NOT EXISTS det_inspeccion_visual (
    id              SERIAL      PRIMARY KEY,
    id_revision     INTEGER     NOT NULL REFERENCES revisiones_bascula(id) ON DELETE CASCADE,
    punto_num       SMALLINT    NOT NULL CHECK (punto_num BETWEEN 1 AND 9),
    descripcion     VARCHAR(200) NOT NULL,
    cumple          BOOLEAN,            -- NULL = sin respuesta, TRUE = cumple, FALSE = no cumple
    observacion     TEXT,
    UNIQUE (id_revision, punto_num)
);
COMMENT ON TABLE det_inspeccion_visual IS 'Matriz de inspección visual con 9 puntos de revisión';

CREATE INDEX IF NOT EXISTS idx_inspeccion_id_revision ON det_inspeccion_visual(id_revision);

-- ── 4. Periféricos e Indicadores (5 ítems lado derecho) ────────────────────
CREATE TABLE IF NOT EXISTS det_perifericos (
    id              SERIAL      PRIMARY KEY,
    id_revision     INTEGER     NOT NULL REFERENCES revisiones_bascula(id) ON DELETE CASCADE,
    tipo            VARCHAR(60) NOT NULL,       -- indicador_peso | teclado_botones | display | impresora | comunicacion
    descripcion     VARCHAR(150),
    cumple          BOOLEAN,
    observacion     TEXT,
    UNIQUE (id_revision, tipo)
);
COMMENT ON TABLE det_perifericos IS 'Revisión de indicadores y periféricos: display, teclado, impresora, etc.';

CREATE INDEX IF NOT EXISTS idx_perifericos_id_revision ON det_perifericos(id_revision);

-- ── 5. Permisos ────────────────────────────────────────────────────────────
GRANT ALL PRIVILEGES ON TABLE
    det_inspeccion_visual, det_perifericos
TO pesa_app;

GRANT USAGE, SELECT ON SEQUENCE
    det_inspeccion_visual_id_seq, det_perifericos_id_seq
TO pesa_app;

-- ── 6. Vista ampliada de Revisiones ────────────────────────────────────────
CREATE OR REPLACE VIEW v_revisiones_bascula AS
    SELECT
        rv.id,
        rv.folio_re,
        rv.fecha,
        rv.horario,
        rv.tipo_bascula,
        rv.num_celdas,
        rv.estado,
        rv.estatus_revision,
        rv.contacto_nombre,
        rv.contacto_telefono,
        rv.contacto_correo,
        rv.obs_cables_conectores,
        rv.obs_generales,
        rv.observaciones,
        cc.razon_social         AS cliente,
        cc.direccion            AS direccion,
        cc.telefono             AS cliente_telefono,
        cc.email                AS cliente_correo,
        cc.id                   AS id_cliente,
        t.nombre_completo       AS tecnico,
        t.id                    AS id_tecnico,
        rv.created_at,
        rv.updated_at
    FROM revisiones_bascula rv
    LEFT JOIN cat_clientes cc ON cc.id = rv.id_cliente
    LEFT JOIN cat_tecnicos t  ON t.id  = rv.id_tecnico;

COMMIT;
