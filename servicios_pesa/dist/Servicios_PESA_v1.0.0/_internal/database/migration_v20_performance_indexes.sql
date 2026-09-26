-- ============================================================================
-- migration_v20_performance_indexes.sql
-- Índices de rendimiento para el Dashboard de Servicios PESA
-- Ejecutar UNA VEZ en la BD de Render (pesa_db)
-- ============================================================================
-- Estos índices eliminan seq-scans en las columnas más filtradas del dashboard.
-- Tiempo estimado: < 30 segundos en una tabla de 10,000 filas.
-- ============================================================================

-- Habilitar creación concurrente (no bloquea escrituras durante el build)
-- NOTA: Los CONCURRENT no pueden ir dentro de una transacción explícita.

-- 1. Filtro principal de fecha (BETWEEN en _get_date_range)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_os_fecha
    ON ordenes_servicio (fecha DESC);

-- 2. Agrupación por lote (ORDER BY id_lote NULLS LAST)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_os_id_lote
    ON ordenes_servicio (id_lote)
    WHERE id_lote IS NOT NULL;

-- 3. Filtro de técnico asignado (RBAC + combo filtro)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_os_id_tecnico
    ON ordenes_servicio (id_tecnico)
    WHERE id_tecnico IS NOT NULL;

-- 4. Filtro de estado (PROCESO / COMPLETADA / ESCANEADA)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_os_estado
    ON ordenes_servicio (estado);

-- 5. Filtro de modalidad (FISICO / DIGITAL)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_os_modalidad
    ON ordenes_servicio (modalidad);

-- 6. Índice compuesto: fecha + estado (cubre los KPIs en una sola pasada)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_os_fecha_estado
    ON ordenes_servicio (fecha DESC, estado);

-- 7. Índice compuesto: fecha + modalidad + estado (cubre card "Físicos Pendientes")
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_os_modalidad_estado_fecha
    ON ordenes_servicio (modalidad, estado, fecha DESC);

-- 8. Adjuntos (sustituye el EXISTS subquery — ahora se usa LEFT JOIN LATERAL)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_adjuntos_id_os
    ON adjuntos_os (id_os);

-- 9. Índice de creación para el ORDER BY secundario
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_os_created_at
    ON ordenes_servicio (created_at DESC);

-- ── Verificar índices creados ──────────────────────────────────────────────
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE tablename IN ('ordenes_servicio', 'adjuntos_os')
ORDER BY tablename, indexname;
