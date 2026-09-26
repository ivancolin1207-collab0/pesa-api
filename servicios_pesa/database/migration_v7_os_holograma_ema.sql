-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  MIGRACIÓN v7 — Hologramas y Acreditación EMA/CCA                          ║
-- ║  Fecha: 2026-07  |  Autor: Básculas PESA Dev                               ║
-- ║                                                                              ║
-- ║  Cambios:                                                                    ║
-- ║    1. ordenes_servicio → ADD holograma_actualizado                           ║
-- ║    2. cat_tecnicos     → ADD tiene_acreditacion_ema, numero_cca_ema          ║
-- ║    3. v_ordenes_servicio → ADD holograma_actualizado                         ║
-- ║    4. Índices y comentarios                                                  ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

BEGIN;

-- ──────────────────────────────────────────────────────────────────────────────
-- 1. ordenes_servicio: agregar columna holograma_actualizado
-- ──────────────────────────────────────────────────────────────────────────────
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS holograma_actualizado VARCHAR(120);

COMMENT ON COLUMN ordenes_servicio.holograma_actualizado
    IS 'Número del holograma nuevo colocado tras la inspección (solo tipos con componente Inspección).';

-- ──────────────────────────────────────────────────────────────────────────────
-- 2. cat_tecnicos: campos de acreditación EMA / CCA
-- ──────────────────────────────────────────────────────────────────────────────
ALTER TABLE cat_tecnicos
    ADD COLUMN IF NOT EXISTS tiene_acreditacion_ema BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS numero_cca_ema         VARCHAR(120);

COMMENT ON COLUMN cat_tecnicos.tiene_acreditacion_ema
    IS 'TRUE si el técnico está acreditado por EMA para emitir CCA. Solo técnicos autorizados pueden ser signatarios del CCA.';

COMMENT ON COLUMN cat_tecnicos.numero_cca_ema
    IS 'Número de CCA/acreditación EMA asignado al técnico (ej. CCA-026-XXX). Vinculado al campo numero_cca de la OS.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 3. Actualizar vista v_ordenes_servicio para incluir nuevos campos
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_ordenes_servicio AS
SELECT
    os.id,
    os.folio_os,
    os.fecha,
    os.estado,
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

COMMENT ON VIEW v_ordenes_servicio IS 'Vista desnormalizada de OS v7 — incluye holograma_actualizado y datos EMA del técnico.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 4. Índice para filtrado por calibración/inspección
--    (útil para las consultas RBAC de Calibrador e Inspector)
-- ──────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_os_tipo_servicio
    ON ordenes_servicio (id_tipo_servicio);

COMMIT;
