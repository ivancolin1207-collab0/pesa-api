-- ═══════════════════════════════════════════════════════════════════════════
-- SERVICIOS PESA — Migración v6: columna consecutivo + estado ASIGNADA
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Qué hace:
--   1. Agrega la columna consecutivo (INT DEFAULT 1) a ordenes_servicio
--      si aún no existe.
--   2. Hace backfill del consecutivo extrayéndolo del folio_os existente
--      (patrón TIPO-AA-NNN).
--   3. Agrega la columna modalidad si no existe (DEFAULT 'FISICO').
--   4. Agrega la columna tipo_documento si no existe (DEFAULT 'OS').
--   5. Hace nullable la columna id_tipo_servicio para permitir registros
--      digitales que aún no tienen tipo de servicio asignado.
--   6. Actualiza el CHECK constraint chk_os_estado para incluir
--      'ASIGNADA' (estado inicial de folios digitales).
--
-- Ejecutar:
--   psql -U postgres -d servicios_pesa -f migration_v6_consecutivo.sql
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Columna consecutivo ────────────────────────────────────────────────────
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS consecutivo INT DEFAULT 1;

COMMENT ON COLUMN ordenes_servicio.consecutivo IS
    'Número consecutivo del folio dentro del año. Extraído de folio_os (p.ej. OS-26-0043 → 43).';

-- ── 2. Backfill consecutivo desde folio_os existentes ────────────────────────
-- El formato es TIPO-AA-NNN (ej. OS-26-43) — extrae la parte numérica final.
UPDATE ordenes_servicio
SET    consecutivo = CAST(
           SPLIT_PART(folio_os, '-', 3) AS INT
       )
WHERE  folio_os LIKE '%-%-%'
  AND  consecutivo IS NULL OR consecutivo = 0 OR consecutivo = 1;

-- ── 3. Columna modalidad (por si no se aplicó migration_v4) ──────────────────
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS modalidad VARCHAR(20) DEFAULT 'FISICO';

-- ── 4. Columna tipo_documento ─────────────────────────────────────────────────
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS tipo_documento VARCHAR(10) DEFAULT 'OS';

-- ── 5. Hacer nullable id_tipo_servicio ────────────────────────────────────────
-- Los folios digitales reservados aún no tienen tipo de servicio.
-- Se asigna cuando el técnico completa el formulario en tablet.
ALTER TABLE ordenes_servicio
    ALTER COLUMN id_tipo_servicio DROP NOT NULL;

-- ── 6. Ampliar CHECK constraint de estado ─────────────────────────────────────
-- PENDIENTE_DIGITAL no es un estado válido en la BD; el estado correcto
-- para folios asignados a tablet es 'ASIGNADA'.
-- Preservamos todos los estados existentes y añadimos 'ASIGNADA' si faltara.
ALTER TABLE ordenes_servicio
    DROP CONSTRAINT IF EXISTS chk_os_estado;

ALTER TABLE ordenes_servicio
    ADD CONSTRAINT chk_os_estado CHECK (
        estado IN (
            'PROCESO',          -- FISICO: en proceso activo
            'CANCELADA',        -- Ambos: anulada
            'ESCANEADA',        -- FISICO: terminada con escaneo adjunto
            'ASIGNADA',         -- DIGITAL: asignada al técnico, pendiente sync inicial
            'EN_CAMPO',         -- DIGITAL: técnico tiene la OS en su tablet
            'SYNC_PENDIENTE',   -- DIGITAL: hay cambios sin subir al servidor
            'FIRMADA',          -- DIGITAL: firmas capturadas, pendiente validación
            'COMPLETADA'        -- DIGITAL: validada y cerrada
        )
    );

COMMENT ON COLUMN ordenes_servicio.estado IS
    'FISICO: PROCESO|ESCANEADA|CANCELADA. '
    'DIGITAL: ASIGNADA|EN_CAMPO|SYNC_PENDIENTE|FIRMADA|COMPLETADA|CANCELADA';

-- ── 7. Verificar resultado ─────────────────────────────────────────────────────
SELECT
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_name   = 'ordenes_servicio'
  AND column_name IN ('consecutivo', 'modalidad', 'tipo_documento', 'id_tipo_servicio', 'estado')
ORDER BY ordinal_position;

COMMIT;
