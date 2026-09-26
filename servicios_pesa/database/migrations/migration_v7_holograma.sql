-- ============================================================================
-- MIGRACIÓN v7 — Servicios PESA
-- Agrega columna holograma_actualizado a ordenes_servicio
-- Ejecutar como superusuario (postgres) en pgAdmin o psql
-- ============================================================================
-- Fecha: 2026-07-31
-- Descripción:
--   La lógica de negocio para tipos de servicio con componente de Inspección
--   requiere registrar tanto el holograma anterior (que se retira) como el
--   holograma actualizado (el que se coloca). Se agrega la columna faltante.
-- ============================================================================

BEGIN;

-- ── 1. Agregar columna holograma_actualizado ──────────────────────────────────
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS holograma_actualizado VARCHAR(120);

COMMENT ON COLUMN ordenes_servicio.holograma_actualizado
    IS 'Número del holograma colocado tras el servicio de inspección. '
       'Solo aplica para tipos de servicio con componente de Inspección.';

-- ── 2. Verificar resultado ────────────────────────────────────────────────────
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'ordenes_servicio'
          AND column_name = 'holograma_actualizado'
    ) THEN
        RAISE NOTICE '✅ Columna holograma_actualizado agregada exitosamente.';
    ELSE
        RAISE EXCEPTION '❌ Error: la columna holograma_actualizado no fue creada.';
    END IF;
END $$;

COMMIT;
