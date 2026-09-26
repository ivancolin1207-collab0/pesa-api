-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  MIGRACIÓN v15 — sucursal_id en RE y RMA                                  ║
-- ║  Fecha: 2026-08  |  Autor: Básculas PESA Dev                              ║
-- ║                                                                            ║
-- ║  Cambios:                                                                  ║
-- ║    1. Agregar sucursal_id (FK nullable) a revisiones_bascula               ║
-- ║    2. Agregar sucursal_id (FK nullable) a remisiones                       ║
-- ║    3. Agregar equipo_catalogo_id (FK nullable) a revisiones_bascula        ║
-- ║    4. Índices de rendimiento                                               ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

BEGIN;

-- ── 1. revisiones_bascula: sucursal y equipo ──────────────────────────────────
ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS sucursal_id        INT
        REFERENCES cliente_sucursales(id) ON DELETE SET NULL;

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS equipo_catalogo_id INT
        REFERENCES cliente_equipos(id) ON DELETE SET NULL;

-- Campos de equipo en texto libre (para cuando se escribe manualmente en RE)
ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS marca        VARCHAR(100);

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS modelo       VARCHAR(100);

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS numero_serie VARCHAR(100);

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS id_indicador_equipo VARCHAR(100);

ALTER TABLE revisiones_bascula
    ADD COLUMN IF NOT EXISTS ubicacion_interna   VARCHAR(150);

COMMENT ON COLUMN revisiones_bascula.sucursal_id
    IS 'Planta/sucursal del cliente donde se hizo la revisión (NULL = sin planta asignada)';
COMMENT ON COLUMN revisiones_bascula.equipo_catalogo_id
    IS 'Equipo del catálogo que se revisó (NULL = equipo no registrado en catálogo)';

CREATE INDEX IF NOT EXISTS idx_re_sucursal_id
    ON revisiones_bascula (sucursal_id) WHERE sucursal_id IS NOT NULL;

-- ── 2. remisiones: sucursal ───────────────────────────────────────────────────
ALTER TABLE remisiones
    ADD COLUMN IF NOT EXISTS sucursal_id INT
        REFERENCES cliente_sucursales(id) ON DELETE SET NULL;

COMMENT ON COLUMN remisiones.sucursal_id
    IS 'Sucursal/planta de destino de la remisión (NULL = sin planta asignada)';

CREATE INDEX IF NOT EXISTS idx_rma_sucursal_id
    ON remisiones (sucursal_id) WHERE sucursal_id IS NOT NULL;

COMMIT;
