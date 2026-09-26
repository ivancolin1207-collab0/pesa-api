-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  MIGRACIÓN v16 — Levantamiento Metrológico y Logística de Pesas (LV)       ║
-- ║  Fecha: 2026-08  |  Autor: Básculas PESA Dev                              ║
-- ║                                                                            ║
-- ║  Cambios:                                                                  ║
-- ║    1. Ampliar constraint de control_folios para incluir 'LV'               ║
-- ║    2. Ampliar función generate_folio de CHAR(3) a VARCHAR(4)               ║
-- ║    3. Crear tabla det_levantamiento_metrologico                            ║
-- ║    4. Índices de rendimiento                                               ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

BEGIN;

-- ── 1. Ampliar la restricción de tipo_folio para aceptar 'LV' ─────────────────
--    La restricción original solo acepta OS, RMA, RE.
--    La columna es CHAR(3) pero 'LV ' (con espacio) funciona; mejor ampliarla.

ALTER TABLE control_folios
    DROP CONSTRAINT IF EXISTS chk_tipo_folio;

-- El tipo_folio es CHAR(3), 'LV' se almacena como 'LV ' (con espacio de padding).
-- Ajustamos el CHECK para aceptar también 'LV':
ALTER TABLE control_folios
    ADD CONSTRAINT chk_tipo_folio
    CHECK (TRIM(tipo_folio) IN ('OS', 'RMA', 'RE', 'LP', 'LV'));

-- ── 2. La función generate_folio acepta CHAR(3) / VARCHAR y hace TRIM internamente ──
--    Primero eliminamos la versión CHAR(3) original para evitar ambigüedad.
--    Luego creamos la nueva con VARCHAR(4) que soporta 'LV' correctamente.

DROP FUNCTION IF EXISTS generate_folio(CHAR(3), SMALLINT);

CREATE OR REPLACE FUNCTION generate_folio(
    p_tipo  VARCHAR(4),
    p_anio  SMALLINT
)
RETURNS VARCHAR(25)
LANGUAGE plpgsql
AS $$
DECLARE
    v_consecutivo   INTEGER;
    v_anio_corto    TEXT;
    v_tipo_clean    TEXT;
BEGIN
    -- Limpiar espacios de padding del CHAR(3)
    v_tipo_clean := TRIM(p_tipo);
    -- Obtener los últimos 2 dígitos del año (2026 → '26')
    v_anio_corto := LPAD((p_anio % 100)::TEXT, 2, '0');

    -- INSERT o UPDATE en una sola operación atómica
    INSERT INTO control_folios (tipo_folio, anio, ultimo_consecutivo, updated_at)
    VALUES (v_tipo_clean, p_anio, 1, NOW())
    ON CONFLICT (tipo_folio, anio) DO UPDATE
        SET ultimo_consecutivo = control_folios.ultimo_consecutivo + 1,
            updated_at         = NOW()
    RETURNING ultimo_consecutivo INTO v_consecutivo;

    -- Formato: LV-26-1
    RETURN v_tipo_clean || '-' || v_anio_corto || '-' || v_consecutivo::TEXT;
END;
$$;

COMMENT ON FUNCTION generate_folio IS
    'Genera el siguiente folio consecutivo de forma atómica y segura. '
    'Soporta tipos: OS, RMA, RE, LP, LV. '
    'Invocar siempre dentro de una transacción activa. '
    'Ejemplo: SELECT generate_folio(''LV'', 2026) → ''LV-26-1''';

-- ── 3. Crear tabla de detalle para Levantamiento Metrológico ──────────────────

CREATE TABLE IF NOT EXISTS det_levantamiento_metrologico (
    id              SERIAL          PRIMARY KEY,
    id_os           INTEGER         NOT NULL UNIQUE
                        REFERENCES ordenes_servicio(id) ON DELETE CASCADE,

    -- Lista JSONB de básculas capturadas en el levantamiento.
    -- Estructura de cada elemento:
    --   { "id_indicador": "TAG-A01", "marca": "METTLER TOLEDO",
    --     "modelo": "IND560", "numero_serie": "B215004321",
    --     "capacidad_max": "60 t", "division_min": "20 kg",
    --     "tipo_instrumento": "Báscula Camionera",
    --     "ubicacion_interna": "Puerta Norte" }
    basculas                JSONB           NOT NULL DEFAULT '[]',

    -- Logística global de pesas patrón y maniobras
    pesas_descripcion       TEXT,   -- Ej. "2 ton paralelepípedas + 4 × 20 kg M1"
    acomodo_maniobra        TEXT,   -- Ej. "Requiere montacargas del cliente"
    observaciones_generales TEXT,

    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lv_id_os
    ON det_levantamiento_metrologico (id_os);

CREATE TRIGGER trg_lv_updated_at
    BEFORE UPDATE ON det_levantamiento_metrologico
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE  det_levantamiento_metrologico
    IS 'Detalle de Levantamiento Metrológico y Logística de Pesas (LV). '
       'La lista de básculas se almacena como JSONB para soportar N instrumentos. '
       'Los equipos se sincronizan automáticamente a cliente_equipos al guardar.';
COMMENT ON COLUMN det_levantamiento_metrologico.basculas
    IS 'Array JSON de básculas identificadas en el levantamiento. '
       'Cada elemento: {id_indicador, marca, modelo, numero_serie, capacidad_max, division_min, tipo_instrumento, ubicacion_interna}';

COMMIT;
