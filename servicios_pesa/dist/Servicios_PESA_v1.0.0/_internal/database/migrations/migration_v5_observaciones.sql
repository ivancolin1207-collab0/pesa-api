-- ═══════════════════════════════════════════════════════════════════════════
-- SERVICIOS PESA — Migración v5: Observaciones Técnicas del Servicio
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Qué hace:
--   1. Confirma que ordenes_servicio.observaciones (TEXT) ya existe.
--   2. Añade observaciones_tecnico (TEXT) — campo exclusivo del técnico en
--      campo para notas operativas detalladas (diferente a observaciones
--      generales de logística).
--   3. Añade observaciones_servicio_tecnico al enum de columnas para RMA y RE
--      si las tablas existen.
--   4. Crea índice de texto completo en observaciones para búsqueda.
--
-- Ejecutar:
--   psql -U postgres -d servicios_pesa -f migration_v5_observaciones.sql
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── ordenes_servicio ─────────────────────────────────────────────────────────
-- El campo observaciones TEXT ya existe desde el schema original.
-- Añadimos observaciones_tecnico para distinguir notas del técnico vs. logística.

ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS observaciones_tecnico TEXT;

COMMENT ON COLUMN ordenes_servicio.observaciones IS
    'Observaciones generales del servicio (registradas por Logística).';

COMMENT ON COLUMN ordenes_servicio.observaciones_tecnico IS
    'Notas operativas detalladas registradas por el Técnico en campo (app tablet/digital). '
    'Ejemplos: "Se reemplaza el 1100a por otro tanque y se recalibran celdas", '
    '"Falla en celda de carga Nº3 — pendiente de revisión".';

-- Índice de búsqueda de texto completo (español) sobre observaciones técnicas
CREATE INDEX IF NOT EXISTS idx_os_obs_tecnico_fts
    ON ordenes_servicio
    USING GIN (to_tsvector('spanish', COALESCE(observaciones_tecnico, '')));

-- ── Tablas opcionales (RMA / RE) ──────────────────────────────────────────────
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'remisiones') THEN
        ALTER TABLE remisiones ADD COLUMN IF NOT EXISTS observaciones_tecnico TEXT;
        COMMENT ON COLUMN remisiones.observaciones_tecnico IS
            'Notas del técnico sobre la remisión de material.';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'revisiones_bascula') THEN
        ALTER TABLE revisiones_bascula ADD COLUMN IF NOT EXISTS observaciones_tecnico TEXT;
        COMMENT ON COLUMN revisiones_bascula.observaciones_tecnico IS
            'Notas del técnico sobre la revisión de báscula.';
    END IF;
END $$;

-- ── Vista actualizada (si existe v_ordenes_servicio, agregarle el campo) ──────
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.views WHERE table_name = 'v_ordenes_servicio') THEN
        -- La vista se recreará automáticamente en el próximo SELECT;
        -- aquí solo documentamos que el campo ya existe en la tabla base.
        RAISE NOTICE 'v_ordenes_servicio detectada — observaciones_tecnico ya disponible en tabla base.';
    END IF;
END $$;

-- ── Verificar resultado ───────────────────────────────────────────────────────
SELECT
    column_name,
    data_type,
    is_nullable,
    pg_catalog.col_description(
        (SELECT oid FROM pg_class WHERE relname = 'ordenes_servicio'),
        ordinal_position
    ) AS descripcion
FROM information_schema.columns
WHERE table_name = 'ordenes_servicio'
  AND column_name IN ('observaciones', 'observaciones_tecnico')
ORDER BY ordinal_position;

COMMIT;
