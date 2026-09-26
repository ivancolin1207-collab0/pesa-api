-- ══════════════════════════════════════════════════════════
-- MIGRACIÓN RÁPIDA v8 — Columna id_lote en ordenes_servicio
-- Ejecutar DIRECTAMENTE en pgAdmin → Query Tool
-- ══════════════════════════════════════════════════════════

BEGIN;

-- 1. Agregar columna si no existe (idempotente, se puede correr varias veces)
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS id_lote VARCHAR(50);

-- 2. Índice para consultas de agrupamiento
CREATE INDEX IF NOT EXISTS idx_os_lote ON ordenes_servicio (id_lote);

COMMIT;

-- Verificación: debería mostrar la columna id_lote
-- SELECT column_name, data_type FROM information_schema.columns
-- WHERE table_name = 'ordenes_servicio' AND column_name = 'id_lote';
