BEGIN;

CREATE TABLE IF NOT EXISTS det_levantamiento_proyecto (
    id_os               INTEGER PRIMARY KEY REFERENCES ordenes_servicio(id) ON DELETE CASCADE,
    tipo_alcance        VARCHAR(100),
    material            VARCHAR(100),
    clasificacion_area  VARCHAR(100),
    senal_comunicacion  VARCHAR(100),
    puntos_corte        VARCHAR(50),
    capacidad_estimada  VARCHAR(200),
    
    instrumentacion     JSONB DEFAULT '[]'::jsonb,
    equipos_maniobra    JSONB DEFAULT '[]'::jsonb,
    epp_seguridad       JSONB DEFAULT '[]'::jsonb,
    masa_requerida      JSONB DEFAULT '[]'::jsonb,
    
    equipos_dinamicos   JSONB DEFAULT '[]'::jsonb
);

COMMIT;
