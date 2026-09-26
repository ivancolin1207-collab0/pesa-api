-- ═══════════════════════════════════════════════════════════════════════════
-- MIGRACIÓN v2 — Servicios PESA
-- Tablas: Remisiones (RMA) + Revisiones de Báscula (RE)
-- Ejecutar: psql -U postgres -d servicios_pesa -f database/migration_v2.sql
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Remisiones (RMA) ───────────────────────────────────────────────────────
-- Asegurar que la función helper existe (por si acaso)
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

CREATE TABLE IF NOT EXISTS remisiones (
    id              SERIAL          PRIMARY KEY,
    folio_rma       VARCHAR(25)     NOT NULL UNIQUE,
    fecha           DATE            NOT NULL DEFAULT CURRENT_DATE,
    id_cliente      INTEGER         REFERENCES cat_clientes(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    id_tecnico      INTEGER         REFERENCES cat_tecnicos(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    observaciones   TEXT,
    estado          VARCHAR(20)     NOT NULL DEFAULT 'ACTIVA'
                        CHECK (estado IN ('ACTIVA','CANCELADA','ENTREGADA')),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE remisiones IS 'Registro de remisiones de materiales/equipos a clientes';

CREATE OR REPLACE TRIGGER trg_remisiones_updated_at
    BEFORE UPDATE ON remisiones
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Ítems de cada remisión
CREATE TABLE IF NOT EXISTS det_remision_items (
    id              SERIAL          PRIMARY KEY,
    id_remision     INTEGER         NOT NULL REFERENCES remisiones(id) ON DELETE CASCADE,
    num_item        SMALLINT        NOT NULL CHECK (num_item > 0),
    descripcion     TEXT            NOT NULL,
    cantidad        NUMERIC(12,4)   NOT NULL DEFAULT 1 CHECK (cantidad > 0),
    unidad          VARCHAR(30)     NOT NULL DEFAULT 'PZA',
    num_serie       VARCHAR(100),
    observacion     TEXT,
    UNIQUE (id_remision, num_item)
);
COMMENT ON TABLE det_remision_items IS 'Ítems/materiales de cada remisión';

CREATE INDEX IF NOT EXISTS idx_remision_items_id_remision ON det_remision_items(id_remision);
CREATE INDEX IF NOT EXISTS idx_remisiones_id_cliente      ON remisiones(id_cliente);
CREATE INDEX IF NOT EXISTS idx_remisiones_fecha           ON remisiones(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_remisiones_folio           ON remisiones(folio_rma);

-- ── 2. Revisiones de Báscula (RE) ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS revisiones_bascula (
    id              SERIAL          PRIMARY KEY,
    folio_re        VARCHAR(25)     NOT NULL UNIQUE,
    fecha           DATE            NOT NULL DEFAULT CURRENT_DATE,
    id_cliente      INTEGER         REFERENCES cat_clientes(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    id_tecnico      INTEGER         REFERENCES cat_tecnicos(id) ON UPDATE CASCADE ON DELETE RESTRICT,
    tipo_bascula    VARCHAR(150),
    num_celdas      SMALLINT        NOT NULL DEFAULT 4 CHECK (num_celdas BETWEEN 1 AND 12),
    observaciones   TEXT,
    estado          VARCHAR(20)     NOT NULL DEFAULT 'ACTIVA'
                        CHECK (estado IN ('ACTIVA','CANCELADA')),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE revisiones_bascula IS 'Revisión de excitaciones de celdas de carga';

CREATE TRIGGER trg_revisiones_updated_at
    BEFORE UPDATE ON revisiones_bascula
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Detalle de celdas de carga
CREATE TABLE IF NOT EXISTS det_celdas_carga (
    id              SERIAL          PRIMARY KEY,
    id_revision     INTEGER         NOT NULL REFERENCES revisiones_bascula(id) ON DELETE CASCADE,
    celda_num       SMALLINT        NOT NULL CHECK (celda_num BETWEEN 1 AND 12),
    signal_mv       NUMERIC(12,6),      -- Señal en mV
    excitacion_v    NUMERIC(12,6),      -- Excitación en V
    ratio_mv_v      NUMERIC(12,6)       -- Calculado: signal_mv / excitacion_v
        GENERATED ALWAYS AS (
            CASE WHEN excitacion_v <> 0 AND excitacion_v IS NOT NULL
                 THEN ROUND(signal_mv / excitacion_v, 6)
                 ELSE NULL
            END
        ) STORED,
    estado_fisico   VARCHAR(60),        -- Bueno, Deteriorado, Dañado, Reemplazado, etc.
    cable_ok        BOOLEAN             DEFAULT TRUE,
    observacion     TEXT,
    UNIQUE (id_revision, celda_num)
);
COMMENT ON TABLE det_celdas_carga IS 'Mediciones de excitación y señal por celda de carga';

CREATE INDEX IF NOT EXISTS idx_celdas_id_revision      ON det_celdas_carga(id_revision);
CREATE INDEX IF NOT EXISTS idx_revisiones_id_cliente   ON revisiones_bascula(id_cliente);
CREATE INDEX IF NOT EXISTS idx_revisiones_fecha        ON revisiones_bascula(fecha DESC);

-- ── 3. Permisos para pesa_app ─────────────────────────────────────────────────
GRANT ALL PRIVILEGES ON TABLE remisiones,
                               det_remision_items,
                               revisiones_bascula,
                               det_celdas_carga
    TO pesa_app;

GRANT USAGE, SELECT ON SEQUENCE remisiones_id_seq,
                                 det_remision_items_id_seq,
                                 revisiones_bascula_id_seq,
                                 det_celdas_carga_id_seq
    TO pesa_app;

-- ── 4. Vista para Remisiones ──────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_remisiones AS
    SELECT
        r.id,
        r.folio_rma,
        r.fecha,
        r.estado,
        cc.razon_social         AS cliente,
        cc.id                   AS id_cliente,
        t.nombre_completo       AS tecnico,
        t.id                    AS id_tecnico,
        r.observaciones,
        r.created_at,
        r.updated_at,
        (SELECT COUNT(*)::INT
         FROM det_remision_items di
         WHERE di.id_remision = r.id)   AS num_items
    FROM remisiones r
    LEFT JOIN cat_clientes  cc ON cc.id = r.id_cliente
    LEFT JOIN cat_tecnicos  t  ON t.id  = r.id_tecnico;

-- ── 5. Vista para Revisiones ──────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_revisiones_bascula AS
    SELECT
        rv.id,
        rv.folio_re,
        rv.fecha,
        rv.tipo_bascula,
        rv.num_celdas,
        rv.estado,
        cc.razon_social         AS cliente,
        cc.id                   AS id_cliente,
        t.nombre_completo       AS tecnico,
        t.id                    AS id_tecnico,
        rv.observaciones,
        rv.created_at,
        rv.updated_at
    FROM revisiones_bascula rv
    LEFT JOIN cat_clientes  cc ON cc.id = rv.id_cliente
    LEFT JOIN cat_tecnicos  t  ON t.id  = rv.id_tecnico;

COMMIT;
