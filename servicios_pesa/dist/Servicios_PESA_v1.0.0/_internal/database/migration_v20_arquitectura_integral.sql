-- ============================================================================
-- migration_v20_arquitectura_integral.sql
-- PESA ERP v3.1 -- Firma de perfil tecnico + Errores tecnicos de campo
-- ============================================================================

ALTER TABLE cat_tecnicos ADD COLUMN IF NOT EXISTS firma_digital TEXT;

COMMENT ON COLUMN cat_tecnicos.firma_digital IS
    'Firma de perfil del tecnico en Base64 PNG. Se reutiliza en PDFs. Distinta de ordenes_servicio.firma_tecnico_b64.';

CREATE TABLE IF NOT EXISTS registro_errores_tecnicos (
    id               SERIAL       PRIMARY KEY,
    folio            VARCHAR(50),
    tecnico          VARCHAR(100),
    error_mensaje    TEXT,
    stack_trace      TEXT,
    dispositivo      VARCHAR(100) DEFAULT 'Tablet Android',
    fecha            TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    resuelto         BOOLEAN      DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_errores_tecnicos_tecnico_resuelto
    ON registro_errores_tecnicos (tecnico, resuelto, fecha DESC);

COMMENT ON COLUMN ordenes_servicio.modalidad IS
    'Modalidad: Fisico | Digital | Hibrido. Hibrido genera PDF fisico Y habilita captura digital.';

DO $$
DECLARE v_col BOOLEAN; v_tbl BOOLEAN;
BEGIN
    SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='cat_tecnicos' AND column_name='firma_digital') INTO v_col;
    SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='registro_errores_tecnicos') INTO v_tbl;
    IF v_col THEN RAISE NOTICE '[v20] OK cat_tecnicos.firma_digital'; ELSE RAISE WARNING '[v20] FAIL firma_digital'; END IF;
    IF v_tbl THEN RAISE NOTICE '[v20] OK registro_errores_tecnicos'; ELSE RAISE WARNING '[v20] FAIL errores'; END IF;
END $$;
