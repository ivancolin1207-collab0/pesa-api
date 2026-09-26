-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  MIGRACIÓN v19 — Columna rango_lote en ordenes_servicio                     ║
-- ║  Fecha: 2026-09  |  Autor: Básculas PESA Dev                               ║
-- ║                                                                              ║
-- ║  Cambios:                                                                    ║
-- ║    1. ordenes_servicio → ADD rango_lote VARCHAR(100)                        ║
-- ║       Ej: "OS-26-570 al OS-26-595"                                          ║
-- ║    2. v_ordenes_servicio → incluye rango_lote                               ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────────
-- 1. Agregar columna rango_lote a ordenes_servicio
-- ──────────────────────────────────────────────────────────────────────────────
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS rango_lote VARCHAR(100);

COMMENT ON COLUMN ordenes_servicio.rango_lote
    IS 'Rango legible del lote, ej: "OS-26-570 al OS-26-595". NULL para OS individuales o históricas sin lote.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 2. Actualizar vista v_ordenes_servicio para incluir rango_lote
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_ordenes_servicio AS
SELECT
    os.id,
    os.folio_os,
    os.fecha,
    os.estado,
    os.id_lote,        -- UUID identificador de lote
    os.rango_lote,     -- Texto legible "OS-26-570 al OS-26-595"
    -- IDs para lookups internos
    os.id_tipo_servicio,
    os.id_cliente,
    os.id_tecnico,
    os.id_tipo_instrumento,
    os.id_clase_exactitud,
    -- Cliente
    cl.razon_social                         AS cliente,
    cl.direccion                            AS direccion_cliente,
    -- Tipo de servicio
    ts.nombre                               AS tipo_servicio,
    -- Técnico
    tc.nombre_completo                      AS tecnico,
    tc.tiene_acreditacion_ema               AS tecnico_tiene_ema,
    tc.numero_cca_ema                       AS tecnico_numero_cca_ema,
    -- Equipo
    os.marca,
    os.modelo,
    os.ns,
    os.ubicacion,
    os.alcance_max,
    os.div_minima,
    os.div_verificacion,
    os.id_equipo,
    ti.nombre                               AS tipo_instrumento,
    os.numero_cca,
    os.holograma_anterior,
    os.holograma_actualizado,
    -- Pruebas
    os.valor_repetibilidad,
    os.valor_excentricidad,
    ce.codigo                               AS clase_exactitud_codigo,
    ce.nombre                               AS clase_exactitud_nombre,
    ce.simbolo                              AS clase_exactitud_simbolo,
    -- Finalización
    os.modalidad,
    os.observaciones,
    os.firma_cliente_nombre,
    -- Archivo adjunto
    adj.nombre_archivo                      AS archivo_escaneado,
    adj.ruta_completa                       AS ruta_escaneado,
    adj.fecha_adjunto,
    -- Timestamps
    os.created_at,
    os.updated_at
FROM ordenes_servicio os
LEFT JOIN cat_clientes          cl  ON os.id_cliente          = cl.id
LEFT JOIN cat_tipo_servicio     ts  ON os.id_tipo_servicio     = ts.id
LEFT JOIN cat_tecnicos          tc  ON os.id_tecnico           = tc.id
LEFT JOIN cat_tipo_instrumento  ti  ON os.id_tipo_instrumento  = ti.id
LEFT JOIN cat_clase_exactitud   ce  ON os.id_clase_exactitud   = ce.id
LEFT JOIN adjuntos_os           adj ON os.id                   = adj.id_os;

COMMENT ON VIEW v_ordenes_servicio IS 'Vista desnormalizada de OS v19 — incluye id_lote y rango_lote para agrupación visual en Dashboard.';

COMMIT;
